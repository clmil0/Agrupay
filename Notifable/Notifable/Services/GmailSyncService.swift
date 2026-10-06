import Foundation
import SwiftData

/// De qué correos se lee. Una lectura puede limitarse a uno: al vincular
/// Outlook se lee su pasado sin volver a bajar el de Gmail.
struct MailProviders: OptionSet {
    let rawValue: Int
    static let gmail = MailProviders(rawValue: 1 << 0)
    static let outlook = MailProviders(rawValue: 1 << 1)
    static let all: MailProviders = [.gmail, .outlook]

    /// A quién pertenece un ID de correo: los de Outlook llevan `ms:`.
    static func of(_ emailID: String) -> MailProviders {
        OutlookMail.isOutlookID(emailID) ? .outlook : .gmail
    }

    /// ¿Hay algún correo vinculado? Lo miran la lectura periódica, el
    /// arranque y la de segundo plano.
    static var anyConnected: Bool {
        GmailAuthService.shared.isAuthenticated || OutlookAuthService.shared.isAuthenticated
    }

    /// Lo mismo sin tocar la red ni crear los servicios.
    static var anyStoredSession: Bool {
        GmailAuthService.hasStoredSession || OutlookAuthService.hasStoredSession
    }
}

/// La lectura del correo de los bancos: Gmail y Outlook. Conserva el nombre
/// de cuando sólo había Gmail; lo propio de cada proveedor está en
/// `fetchMessageList` (Gmail) y `OutlookMail`.
class GmailSyncService: ObservableObject {
    
    static let shared = GmailSyncService()
    
    @Published var isSyncing: Bool = false
    @Published var lastSyncError: String?
    
    // Progress tracking
    @Published var totalEmailsToProcess: Int = 0
    @Published var emailsProcessed: Int = 0
    @Published var expensesFoundByBank: [String: Int] = [:]
    
    // Throttling
    @Published var lastSyncDate: Date? {
        didSet {
            if let date = lastSyncDate {
                UserDefaults.standard.set(date, forKey: "lastSyncDate")
            }
        }
    }
    @Published var diagnosticResult: String = ""
    /// Qué encontró la última lectura pedida a mano: «Gmail no devolvió
    /// correos de bancos en ese rango» no es lo mismo que «todo ya estaba
    /// importado», y sin esto las dos se veían como una lectura que se
    /// cancelaba al segundo.
    @Published var lastRunSummary: String?
    @Published var showDiagnostic: Bool = false
    /// Correos de banco que se encontraron pero no se pudieron descargar
    /// (red, error de Gmail). Se reintentan solos en cada lectura; mientras
    /// queden, el Resumen y Gmail y bancos lo dicen con un «Reintentar».
    @Published private(set) var failedEmailCount = FailedEmails.load().count
    
    let baseURL = "https://gmail.googleapis.com/gmail/v1/users/me"
    
    // Lista de parsers modulares de cada banco
    let parsers: [BankEmailParser] = [
        BBVAParser(),
        BCPParser(),
        YapeParser(),
        InterbankParser(),
        ScotiabankParser(),
        AppleParser()
    ]
    
    // Configura el ModelContext desde el lugar donde se llame
    var modelContext: ModelContext?
    
    init() {
        self.lastSyncDate = UserDefaults.standard.object(forKey: "lastSyncDate") as? Date
    }
    
    // MARK: - Comprobación con la app abierta

    /// Cada cuánto se mira el correo mientras la app está en primer plano.
    /// Con 60 s un yapeo hecho con la app abierta podía tardar casi dos
    /// minutos en aparecer (lo que tarda Gmail en indexarlo más la espera).
    /// Sin correo nuevo cada vuelta es una sola `messages.list`: 10 s siguen
    /// muy lejos de la cuota de Gmail por usuario.
    static let foregroundPollInterval: TimeInterval = 10

    /// La app viene de segundo plano (o de cerrada): la próxima vez que se
    /// active hay que leer sí o sí. Empieza en `true` por el arranque en frío.
    private var cameFromBackground = true

    func appDidEnterBackground() {
        cameFromBackground = true
        stopForegroundPolling()
    }

    /// Al entrar a la app: leer ya, sin esperar al temporizador.
    ///
    /// Al volver de segundo plano la lectura salta el límite de frecuencia —si
    /// no, entrar a los pocos segundos de la última no miraba nada y tocaba
    /// esperar a la siguiente vuelta—. Es `quiet`: sin correos nuevos no se
    /// nota; con correos nuevos enseña el progreso como siempre. Todo corre
    /// fuera del hilo principal salvo el guardado de cada gasto, así que la
    /// app se puede usar mientras tanto. Bajar el Centro de Notificaciones
    /// (`.inactive` → `.active`) sólo hace una lectura normal, con su límite.
    func appDidBecomeActive() {
        let force = cameFromBackground
        cameFromBackground = false
        if MailProviders.anyConnected { syncEmails(force: force, quiet: true) }
        startForegroundPolling()
    }

    private var pollTimer: Timer?

    /// Arranca la comprobación de cada minuto. Antes sólo se leía al volver a
    /// primer plano, así que con la app abierta un rato "Última lectura"
    /// envejecía y parecía que había dejado de registrar.
    ///
    /// Cuesta muy poco: cuando no hay correo nuevo es **una** petición
    /// `messages.list` (unos pocos KB, 5 unidades de cuota de Gmail, muy lejos
    /// del límite por usuario). Sólo si aparece un correo sin procesar se
    /// descarga ese mensaje. Se detiene al salir de la app: en segundo plano no
    /// corre nada.
    func startForegroundPolling() {
        stopForegroundPolling()
        let timer = Timer(timeInterval: Self.foregroundPollInterval, repeats: true) { [weak self] _ in
            guard let self, MailProviders.anyConnected, !self.isSyncing else { return }
            self.syncEmails(quiet: true)
        }
        timer.tolerance = 5
        // `.default` y no `.common`: mientras el dedo desliza una lista el
        // bucle principal está en modo de seguimiento y el timer espera a que
        // se suelte, en vez de lanzar la lectura en pleno gesto.
        RunLoop.main.add(timer, forMode: .default)
        pollTimer = timer
    }

    func stopForegroundPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// - Parameter quiet: comprobación periódica. No enciende `isSyncing` (que
    ///   en Gmail y bancos cambia la fila de "Última lectura" por la barra de
    ///   progreso) salvo que de verdad haya correos nuevos que procesar.
    /// Hay una lectura en curso. Sólo se toca en el hilo principal.
    private(set) var isRunning = false
    /// Cuándo empezó la lectura en curso. Una que lleva demasiado «en curso»
    /// se da por colgada: si no, `isRunning` bloquearía todas las demás y
    /// cada intento terminaría al instante sin decir nada.
    private(set) var runStartedAt: Date?
    static let stuckRunThreshold: TimeInterval = 180
    /// Quien espera a que la lectura termine: la tarea de segundo plano, que
    /// no puede darse por terminada antes de tiempo.
    private var runCompletions: [() -> Void] = []
    /// Rango pedido mientras otra lectura corría: se lanza al terminar ésa.
    private var queuedRange: (start: Date?, end: Date?, providers: MailProviders)?

    /// Cierra la lectura en curso y, si alguien pidió un rango mientras
    /// tanto, lo lanza ahora.
    /// Espera a que termine la lectura: una vuelta de la tarea en segundo
    /// plano, que no tiene primer plano al que volver.
    @MainActor
    func syncNow() async {
        await withCheckedContinuation { continuation in
            var resumed = false
            syncEmails(force: true, quiet: true) {
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
        }
    }

    private func finishRun() {
        DispatchQueue.main.async {
            self.isRunning = false
            self.runStartedAt = nil
            let waiting = self.runCompletions
            self.runCompletions = []
            for completion in waiting { completion() }
            if let queued = self.queuedRange {
                self.queuedRange = nil
                self.syncEmails(force: true, startDate: queued.start, endDate: queued.end, providers: queued.providers)
            }
        }
    }

    func syncEmails(force: Bool = false, quiet: Bool = false, startDate: Date? = nil, endDate: Date? = nil,
                    providers: MailProviders = .all, completion: (() -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.syncEmails(force: force, quiet: quiet, startDate: startDate, endDate: endDate,
                                providers: providers, completion: completion)
            }
            return
        }
        // Throttling: un poco menos del intervalo del temporizador, para que su
        // propio desfase no le haga saltarse una vuelta.
        if !force, let lastSync = lastSyncDate, Date().timeIntervalSince(lastSync) < Self.foregroundPollInterval * 0.7 {
            print("Sync throttled. Last sync was \(Int(Date().timeIntervalSince(lastSync)/60)) minutes ago.")
            if !quiet { Diagnostics.shared.log("Sync Gmail: omitida, la última fue hace \(Int(Date().timeIntervalSince(lastSync))) s") }
            completion?()
            return
        }

        // Nadie pidió un rango y nunca se ha leído nada: no hay nada que
        // sincronizar. Antes esta rama se inventaba el último mes y descargaba
        // correo por su cuenta apenas se vinculaba Gmail — sin que el usuario
        // hubiera elegido leer su pasado, y a veces antes de que le llegara la
        // pregunta. El pasado sólo se descarga cuando lo pide: en la pantalla
        // de "¿Cuánto correo miramos?" o en Gmail y bancos.
        if startDate == nil, endDate == nil, lastSyncDate == nil, FailedEmails.load().isEmpty {
            print("Sync skipped: sin lectura previa y sin rango elegido por el usuario.")
            Diagnostics.shared.log("Sync Gmail: omitida, nunca se eligió desde cuándo leer (lastSyncDate vacío y sin rango)")
            completion?()
            return
        }
        
        // Una lectura a la vez. Dos solapadas —tras reinstalar, la del
        // onboarding y la de volver a primer plano o una de rango— importaban
        // cada una su copia de los mismos correos. Un rango pedido a medias no
        // se pierde: se lanza al acabar la actual. Una comprobación normal se
        // descarta, porque la lectura en curso ya la cubre.
        if isRunning, let started = runStartedAt,
           Date().timeIntervalSince(started) > Self.stuckRunThreshold {
            Diagnostics.shared.log("Sync Gmail: ⚠️ la lectura anterior lleva \(Int(Date().timeIntervalSince(started))) s en curso; se da por colgada y se libera")
            isRunning = false
            runStartedAt = nil
            isSyncing = false
        }
        if isRunning {
            if startDate != nil || endDate != nil { queuedRange = (startDate, endDate, providers) }
            Diagnostics.shared.log("Sync Gmail: ya hay una lectura en curso, \(queuedRange != nil ? "se encola el rango" : "se omite")")
            if let completion { runCompletions.append(completion) }
            return
        }
        isRunning = true
        runStartedAt = Date()
        if let completion { runCompletions.append(completion) }

        Diagnostics.shared.log("Sync Gmail: inicio (force: \(force), quiet: \(quiet), desde: \(Self.logDate(startDate)), hasta: \(Self.logDate(endDate)), última: \(Self.logDate(lastSyncDate)))")
        if !quiet {
            DispatchQueue.main.async {
                self.isSyncing = true
                self.lastSyncError = nil
                self.lastRunSummary = nil
                self.totalEmailsToProcess = 0
                self.emailsProcessed = 0
                self.expensesFoundByBank = [:]
            }
        }
        
        let gmailOn = providers.contains(.gmail) && (Self.qaToken != nil || GmailAuthService.shared.isAuthenticated)
        let outlookOn = providers.contains(.outlook) && Self.qaToken == nil && OutlookAuthService.shared.isAuthenticated
        guard gmailOn || outlookOn else {
            Diagnostics.shared.log("Sync Gmail: ✗ ningún correo vinculado (pedido: \(providers.rawValue))")
            DispatchQueue.main.async {
                self.isSyncing = false
                self.lastSyncError = "No hay ningún correo conectado. Vincula Gmail u Outlook."
            }
            finishRun()
            return
        }

        // Los dos a la vez; se procesan juntos. Si uno falla, lo del otro se
        // lee igual y el error se enseña al final.
        let isRange = startDate != nil || endDate != nil
        let listings = DispatchGroup()
        var gmail = Listing()
        var outlook = Listing()
        if gmailOn {
            listings.enter()
            listGmail(startDate: startDate, endDate: endDate) { gmail = $0; listings.leave() }
        }
        if outlookOn {
            listings.enter()
            listOutlook(startDate: startDate, endDate: endDate) { outlook = $0; listings.leave() }
        }
        listings.notify(queue: .main) { [weak self] in
            guard let self else { return }
            var reachable: MailProviders = []
            if gmailOn, gmail.error == nil { reachable.insert(.gmail) }
            if outlookOn, outlook.error == nil { reachable.insert(.outlook) }
            let errors = [gmail.error, outlook.error].compactMap { $0 }
            if gmail.error != nil {
                Analytics.error("sync_list", code: gmail.transient ? "transient" : "failed", ["provider": "gmail"])
            }
            if outlook.error != nil {
                Analytics.error("sync_list", code: outlook.transient ? "transient" : "failed", ["provider": "outlook"])
            }
            guard !reachable.isEmpty else {
                self.isSyncing = false
                self.lastSyncError = errors.joined(separator: " ")
                self.finishRun()
                return
            }
            // `lastSyncDate` es una sola para los dos correos: no avanza si
            // uno falló por algo pasajero (sus correos de este rato se
            // perderían) ni en una lectura de un solo proveedor, salvo que
            // nunca se hubiera leído nada.
            let transientFailure = gmail.transient || outlook.transient
            let advancesClock = !transientFailure && (providers == .all || self.lastSyncDate == nil)
            self.processMessages(gmail.messages + outlook.messages, token: gmail.token ?? "",
                                 isRangeSync: isRange,
                                 coversNow: Self.reachesNow(endDate) && advancesClock,
                                 quiet: quiet,
                                 reachable: reachable,
                                 partialError: errors.first)
        }
    }

    /// Lo que devolvió la búsqueda de un proveedor.
    private struct Listing {
        var messages: [[String: Any]] = []
        var token: String?
        var error: String?
        /// Falló por algo que se arregla solo (red, un 5xx): no se puede dar
        /// el rato por leído.
        var transient = false
    }

    private func listGmail(startDate: Date?, endDate: Date?, completion: @escaping (Listing) -> Void) {
        guard let token = Self.qaToken ?? GmailAuthService.shared.getAccessToken() else {
            Diagnostics.shared.log("Sync Gmail: ✗ no hay token de acceso guardado (refresh token: \(GmailAuthService.shared.hasRefreshToken ? "sí" : "no"))")
            return completion(Listing(error: "No hay permiso de Gmail guardado. Desvincula y vuelve a conectar la cuenta."))
        }

        // Sin `gmail.readonly` cada lectura es un 403 seguro, y renovar no lo
        // arregla: se cortaba igual tras dos llamadas y una renovación, en
        // cada apertura y cada cuarto de hora en segundo plano.
        if Self.qaToken == nil, GmailAuthService.lacksGmailScope {
            Diagnostics.shared.log("Sync Gmail: omitida, Google no dio permiso para leer el correo (hay que volver a vincular)")
            return completion(Listing(error: GmailAuthService.missingScopeMessage))
        }

        fetchMessageList(token: token, startDate: startDate, endDate: endDate) { [weak self] result in
            switch result {
            case .success(let messages):
                completion(Listing(messages: messages, token: token))
            case .failure(let error) where Self.isMissingScope(error):
                Diagnostics.shared.log("Sync Gmail: ✗ Google no dio permiso para leer el correo; no se reintenta, hay que volver a vincular")
                GmailAuthService.shared.markMissingGmailScope()
                completion(Listing(error: error.localizedDescription))
            case .failure(let error):
                // Token might be expired, try to refresh
                Diagnostics.shared.log("Sync Gmail: la lista falló (\(Self.describe(error))); se renueva el token y se reintenta")
                GmailAuthService.shared.refreshAccessToken { newToken in
                    guard let self, let newToken else {
                        Diagnostics.shared.log("Sync Gmail: ✗ no se pudo renovar el token; la lectura se corta")
                        // `markAccessRevoked` lo escribe al instante en
                        // `UserDefaults`; la propiedad publicada llega después.
                        let revoked = UserDefaults.standard.bool(forKey: GmailAuthService.Keys.accessRevoked)
                        return completion(Listing(error: revoked
                            ? "Google retiró el permiso. Vuelve a conectar Gmail."
                            : "No se pudo renovar el permiso de Gmail. Revisa la conexión e inténtalo de nuevo.",
                            transient: !revoked))
                    }
                    self.fetchMessageList(token: newToken, startDate: startDate, endDate: endDate) { result in
                        switch result {
                        case .success(let msgs):
                            completion(Listing(messages: msgs, token: newToken))
                        case .failure(let err):
                            Diagnostics.shared.log("Sync Gmail: ✗ la lista volvió a fallar tras renovar el token (\(Self.describe(err)))")
                            completion(Listing(error: err.localizedDescription, transient: true))
                        }
                    }
                }
            }
        }
    }

    /// La misma ventana que Gmail: el rango pedido o, si no, desde la última
    /// lectura menos una hora.
    private func listOutlook(startDate: Date?, endDate: Date?, completion: @escaping (Listing) -> Void) {
        let after: Date
        if let startDate {
            after = startDate
        } else if let lastSyncDate {
            after = lastSyncDate.addingTimeInterval(-3600)
        } else {
            return completion(Listing())
        }
        let before = endDate.map { Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: $0) ?? $0 }
        let senders = parsers.flatMap(\.senderEmails)
        let auth = OutlookAuthService.shared

        func failed(_ error: Error) -> Listing {
            Listing(error: "No se pudo leer Outlook (\(Self.describe(error))).", transient: true)
        }
        func noToken() -> Listing {
            let revoked = UserDefaults.standard.bool(forKey: OutlookAuthService.Keys.accessRevoked)
            Diagnostics.shared.log("Sync Outlook: ✗ sin token válido (revocado: \(revoked ? "sí" : "no"))")
            return Listing(error: revoked
                ? "Microsoft retiró el permiso. Vuelve a conectar Outlook."
                : "No se pudo renovar el permiso de Outlook. Revisa la conexión e inténtalo de nuevo.",
                transient: !revoked)
        }

        auth.validAccessToken { token in
            guard let token else { return completion(noToken()) }
            OutlookMail.list(senders: senders, after: after, before: before, token: token) { result in
                switch result {
                case .success(let messages):
                    completion(Listing(messages: messages, token: token))
                case .failure(OutlookMail.Failure.http(401, _)):
                    // Vigente según su fecha pero rechazado: se renueva una vez.
                    auth.refresh { newToken in
                        guard let newToken else { return completion(noToken()) }
                        OutlookMail.list(senders: senders, after: after, before: before, token: newToken) { retry in
                            switch retry {
                            case .success(let messages): completion(Listing(messages: messages, token: newToken))
                            case .failure(let error): completion(failed(error))
                            }
                        }
                    }
                case .failure(let error):
                    completion(failed(error))
                }
            }
        }
    }

    private func fetchMessageList(token: String, startDate: Date? = nil, endDate: Date? = nil, completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        #if DEBUG
        if QAMode.isOn {
            let list = QAMode.messageList(startDate: startDate, endDate: endDate, lastSync: lastSyncDate)
            DispatchQueue.global().async { completion(.success(list)) }
            return
        }
        #endif
        // Buscar correos dinámicamente según los bancos soportados
        let allEmails = parsers.flatMap { $0.senderEmails }
        var query = allEmails.isEmpty ? "" : allEmails.map { "from:\($0)" }.joined(separator: " OR ")
        
        if let start = startDate {
            let startEpoch = Int(start.timeIntervalSince1970)
            query = "(\(query)) AND after:\(startEpoch)"
        } else if let lastSync = lastSyncDate {
            let safeEpoch = Int(lastSync.timeIntervalSince1970) - 3600 // 1 hr margen
            query = "(\(query)) AND after:\(safeEpoch)"
        } else {
            // Sin rango y sin lectura previa no se inventa una ventana: sólo
            // se reintentan los correos que fallaron (`processMessages`).
            completion(.success([]))
            return
        }
        
        if let end = endDate {
            // Set end to the end of the day to include the selected date fully
            let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end
            let endEpoch = Int(endOfDay.timeIntervalSince1970)
            query = "\(query) AND before:\(endEpoch)"
        }
        
        // Siempre con `completion`: un `return` a secas dejaría la lectura
        // "en curso" para siempre y `isRunning` bloquearía todas las demás.
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            Diagnostics.shared.log("Sync Gmail: ✗ no se pudo codificar la búsqueda: \(query)")
            completion(.success([]))
            return
        }
        Diagnostics.shared.log("Sync Gmail: búsqueda «\(query)»")

        // Gmail pagina: sin seguir `nextPageToken`, un rango largo se cortaba en
        // 500 correos y el resto se perdía en silencio. Cinco meses de dos
        // bancos pasan de 500 sin dificultad.
        fetchMessagePage(token: token, encodedQuery: encodedQuery, pageToken: nil,
                         accumulated: [], completion: completion)
    }

    private func fetchMessagePage(token: String,
                                  encodedQuery: String,
                                  pageToken: String?,
                                  accumulated: [[String: Any]],
                                  completion: @escaping (Result<[[String: Any]], Error>) -> Void) {

        var urlString = "\(baseURL)/messages?q=\(encodedQuery)&maxResults=500"
        if let pageToken { urlString += "&pageToken=\(pageToken)" }
        guard let url = URL(string: urlString) else {
            completion(.success(accumulated))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                Diagnostics.shared.log("Sync Gmail: ✗ lista, error de red: \(Self.describe(error))")
                completion(.failure(error))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 401 {
                Diagnostics.shared.log("Sync Gmail: lista 401 (token vencido o inválido): \(Self.bodyExcerpt(data))")
                completion(.failure(NSError(domain: "Auth", code: 401, userInfo: nil)))
                return
            }
            // Antes cualquier otro error (403 sin permiso de Gmail, 429 cuota,
            // 5xx) se leía como «ningún correo»: la lectura acababa al instante
            // sin decir nada.
            guard (200...299).contains(status) else {
                Diagnostics.shared.log("Sync Gmail: ✗ lista HTTP \(status): \(Self.bodyExcerpt(data))")
                completion(.failure(Self.apiError(status: status, data: data)))
                return
            }
            guard let data = data else {
                Diagnostics.shared.log("Sync Gmail: lista sin cuerpo (HTTP \(status))")
                completion(.success(accumulated))
                return
            }

            do {
                let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                let messages = json?["messages"] as? [[String: Any]] ?? []
                let total = accumulated + messages
                Diagnostics.shared.log("Sync Gmail: página con \(messages.count) correos (acumulado \(total.count), estimado \(json?["resultSizeEstimate"] ?? "?"))")

                // Tope de cordura: 20 páginas son 10 000 correos.
                if let next = json?["nextPageToken"] as? String, total.count < 10_000 {
                    self?.fetchMessagePage(token: token, encodedQuery: encodedQuery,
                                           pageToken: next, accumulated: total,
                                           completion: completion)
                } else {
                    completion(.success(total))
                }
            } catch {
                Diagnostics.shared.log("Sync Gmail: ✗ lista con JSON ilegible: \(Self.bodyExcerpt(data))")
                completion(.failure(error))
            }
        }.resume()
    }
    
    /// `true` si la sincronización llega hasta ahora. Una sincronización
    /// histórica acotada no puede decir "ya está todo al día".
    static func reachesNow(_ endDate: Date?) -> Bool {
        guard let endDate else { return true }
        return Calendar.current.startOfDay(for: endDate) >= Calendar.current.startOfDay(for: Date())
    }

    /// Punto de partida para leer "los últimos N meses", siempre el día 1 de
    /// un mes — nunca una fecha suelta a mitad de mes, que dejaría el primer
    /// tramo del rango incompleto y "1 mes" significaría cosas distintas
    /// según qué día del mes se pidiera.
    ///
    /// El mes de hoy sólo cuenta como uno completo si ya se pasó la quincena
    /// (día > 15); si no, el rango arranca un mes antes. Así, pedir "1 mes"
    /// el 3 o el 15 de agosto trae desde el 1 de julio (agosto apenas
    /// empieza, no es un mes de historial todavía), pero pedirlo el 20 de
    /// agosto ya trae desde el 1 de agosto (agosto ya lleva más de la mitad).
    static func smartRangeStart(months: Int, from reference: Date = Date(), calendar: Calendar = .current) -> Date {
        let day = calendar.component(.day, from: reference)
        let currentMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: reference)) ?? reference
        let anchor = day <= 15
            ? (calendar.date(byAdding: .month, value: -1, to: currentMonthStart) ?? currentMonthStart)
            : currentMonthStart
        let start = calendar.date(byAdding: .month, value: -(months - 1), to: anchor) ?? anchor
        return calendar.startOfDay(for: start)
    }

    /// Correos que la app ya convirtió en un gasto que sigue en la base.
    ///
    /// La deduplicación no puede depender sólo de `processedEmailIDs`: esa lista
    /// vive en `UserDefaults` y se borra al restablecer la sincronización o al
    /// reinstalar, y entonces el mismo rango se importaba dos veces.
    ///
    /// Incluye `relatedEmailID`: el segundo correo de un par de Apple (recibo +
    /// cargo del banco) no crea gasto, se une al primero. Sin contarlo, cada
    /// lectura por rango lo veía como nuevo y, como el gasto ya estaba unido,
    /// no encontraba con qué unirlo y creaba un duplicado.
    private func existingEmailIDs() -> Set<String> {
        guard let context = modelContext else { return [] }
        let expenses = (try? context.fetch(FetchDescriptor<Expense>())) ?? []
        let incomes = (try? context.fetch(FetchDescriptor<Income>())) ?? []
        return Set(expenses.compactMap { $0.emailID })
            .union(expenses.compactMap { $0.relatedEmailID })
            .union(incomes.compactMap { $0.emailID })
    }

    /// Varios movimientos con el **mismo** `emailID`: copias que dejaron dos
    /// lecturas solapadas antes de que `syncEmails` las serializara (se vio
    /// al reinstalar: el mismo yapeo repetido varias veces). Un correo es un
    /// movimiento, así que se queda uno por correo.
    ///
    /// Se conserva el que tenga más decisiones del usuario encima (abonos,
    /// deuda, categoría) y, de las demás copias, sólo se borran las que no
    /// tienen abonos: borrar una con abonos soltaría esos cobros.
    @discardableResult
    static func removeSameEmailDuplicates(in context: ModelContext) -> Int {
        let expenses = (try? context.fetch(FetchDescriptor<Expense>(predicate: #Predicate { $0.emailID != nil }))) ?? []
        let groups = Dictionary(grouping: expenses, by: { $0.emailID ?? "" }).filter { $0.value.count > 1 }

        func weight(_ e: Expense) -> Int {
            ((e.payments ?? []).isEmpty ? 0 : 4)
                + (e.isDebt ? 2 : 0)
                + (e.category == Accounting.unclassified ? 0 : 1)
        }

        var removed = 0
        for (_, copies) in groups {
            let keep = copies.max { weight($0) < weight($1) }
            for copy in copies where copy.id != keep?.id && (copy.payments ?? []).isEmpty {
                context.delete(copy)
                removed += 1
            }
        }

        let incomes = (try? context.fetch(FetchDescriptor<Income>(predicate: #Predicate { $0.emailID != nil }))) ?? []
        for (_, copies) in Dictionary(grouping: incomes, by: { $0.emailID ?? "" }) where copies.count > 1 {
            // Uno atado a una deuda gana: es una decisión del usuario.
            let keep = copies.first { $0.debtReference != nil } ?? copies[0]
            for copy in copies where copy.id != keep.id && copy.debtReference == nil {
                context.delete(copy)
                removed += 1
            }
        }

        if removed > 0 {
            try? context.save()
            Diagnostics.shared.log("Copias del mismo correo borradas: \(removed)")
        }
        return removed
    }

    /// Borra los duplicados que dejó el error de arriba: un gasto cuyo correo
    /// ya está unido a otro gasto. Sólo si nadie decidió nada sobre él — ni
    /// deuda, ni cobros, ni ediciones —; si no, se deja y se anota.
    @discardableResult
    static func removeLinkedDuplicates(in context: ModelContext) -> Int {
        removeSameEmailDuplicates(in: context)
        let expenses = (try? context.fetch(FetchDescriptor<Expense>())) ?? []
        let linkedIDs = Set(expenses.compactMap(\.relatedEmailID))
        guard !linkedIDs.isEmpty else { return 0 }
        let edits = ExpenseEditStore.all()

        var removed = 0
        for expense in expenses {
            guard let emailID = expense.emailID, linkedIDs.contains(emailID), expense.relatedEmailID == nil,
                  expenses.contains(where: { $0.id != expense.id && $0.relatedEmailID == emailID }) else { continue }
            guard !expense.isDebt, (expense.payments ?? []).isEmpty,
                  edits[TransactionKey.key(for: expense)] == nil else {
                Diagnostics.shared.log("Duplicado de correo unido conservado (tiene decisiones): \(expense.merchant)")
                continue
            }
            context.delete(expense)
            removed += 1
        }
        if removed > 0 {
            try? context.save()
            Diagnostics.shared.log("Duplicados de correos unidos borrados: \(removed)")
        }
        return removed
    }

    /// Los `emailID` ya guardados, leídos en el hilo que llama.
    ///
    /// Fuera del hilo principal usa un `ModelContext` propio sobre el mismo
    /// contenedor: recorrer todo el historial en el principal —antes, con un
    /// `main.sync`— congelaba la app justo al abrirla, que es cuando se lee el
    /// correo. Lo insertado se guarda al momento (`handleExpenseInsertion`),
    /// así que este contexto ve lo mismo que el principal.
    ///
    /// Ojo: nunca `DispatchQueue.main.sync` aquí. `recoverExpenses` llega
    /// desde un botón, ya en el hilo principal, y eso era un interbloqueo.
    private func knownEmailIDs() -> Set<String> {
        if Thread.isMainThread { return existingEmailIDs() }
        guard let container = modelContext?.container else { return [] }
        let context = ModelContext(container)
        let expenses = (try? context.fetch(FetchDescriptor<Expense>())) ?? []
        let incomes = (try? context.fetch(FetchDescriptor<Income>())) ?? []
        return Set(expenses.compactMap { $0.emailID })
            .union(expenses.compactMap { $0.relatedEmailID })
            .union(incomes.compactMap { $0.emailID })
    }

    /// - Parameters:
    ///   - reachable: los proveedores cuya búsqueda respondió; sólo de ésos
    ///     se reintentan los correos que fallaron antes.
    ///   - partialError: el otro proveedor falló; se enseña al terminar.
    private func processMessages(_ listed: [[String: Any]],
                                 token: String,
                                 isRangeSync: Bool = false,
                                 coversNow: Bool = true,
                                 quiet: Bool = false,
                                 reachable: MailProviders = .all,
                                 partialError: String? = nil) {
        // Lista en el orden de llegada (para podar lo más viejo) y conjunto
        // para preguntar: con años de uso, `contains` sobre el array costaba
        // una vuelta entera por cada correo.
        let processedList = UserDefaults.standard.stringArray(forKey: "processedEmailIDs") ?? []
        let processedIDs = Set(processedList)
        // Borrados a propósito: no se resucitan solos. Para recuperarlos está
        // "Recuperación de Gastos" en Ajustes.
        let deletedIDs = Set(UserDefaults.standard.stringArray(forKey: "pendingRecoveryIDs") ?? [])

        // Los que no se pudieron descargar en lecturas anteriores. La búsqueda
        // normal mira sólo la última hora, así que ya no los trae: se piden
        // por su ID. Antes un corte de red los perdía para siempre.
        let listedIDs = Set(listed.compactMap { $0["id"] as? String })
        let retries = FailedEmails.load().keys.filter {
            !listedIDs.contains($0) && !deletedIDs.contains($0) && reachable.contains(MailProviders.of($0))
        }
        let messages = listed + retries.sorted().map { ["id": $0] as [String: Any] }
        if !retries.isEmpty {
            Diagnostics.shared.log("Sync Gmail: se reintentan \(retries.count) correos que fallaron antes")
        }

        let newMessages = messages.filter { msg in
            guard let id = msg["id"] as? String else { return false }
            if deletedIDs.contains(id) { return false }
            // En una sincronización con rango explícito no se salta lo ya
            // procesado: se vuelve a mirar para rellenar lo que falte —un correo
            // que falló, un parser arreglado después—, y la comprobación contra
            // la base impide duplicar.
            return isRangeSync || !processedIDs.contains(id)
        }
        
        // Sin nada nuevo la comprobación no se ve ni toca los contadores (el
        // onboarding los lee para dar por terminada su lectura); con correos
        // que procesar se enseña el progreso, como una lectura normal.
        if !(quiet && newMessages.isEmpty) { DispatchQueue.main.async {
            if quiet {
                self.isSyncing = true
                self.lastSyncError = nil
            }
            self.totalEmailsToProcess = newMessages.count
            self.emailsProcessed = 0
            self.expensesFoundByBank = [:]
            for parser in self.parsers {
                self.expensesFoundByBank[parser.bankName] = 0
            }
        } }
        
        let skippedDeleted = messages.filter { ($0["id"] as? String).map(deletedIDs.contains) ?? false }.count
        Diagnostics.shared.log("Sync Gmail: \(newMessages.count) correos por procesar de \(messages.count) (rango: \(isRangeSync), ya procesados antes: \(processedIDs.count), borrados a propósito omitidos: \(skippedDeleted))")
        if !quiet, listed.isEmpty, retries.isEmpty {
            let summary = "No llegó ningún correo de los bancos compatibles en ese periodo."
            DispatchQueue.main.async { self.lastRunSummary = summary }
        }
        // La lista respondió: un error de una comprobación anterior ya no vale.
        if quiet, lastSyncError != nil, partialError == nil { DispatchQueue.main.async { self.lastSyncError = nil } }
        let runStart = Date()
        var unrecognized = 0
        var failedFetches = 0
        var alreadyImportedCount = 0
        var newIDs = processedList
        var newIDSet = processedIDs
        var failedIDs: [String] = []
        let queue = DispatchQueue(label: "com.notifable.syncQueue") // Para evitar race conditions
        
        let group = DispatchGroup()
        var newExpensesFound = 0
        let semaphore = DispatchSemaphore(value: 5) // Maximum 5 concurrent requests

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Se siembra con lo que ya está en la base y se va ampliando: dos
            // correos de la misma tanda no pueden crear el mismo gasto dos
            // veces. Sin nada nuevo no hace falta mirar la base.
            var knownIDs: Set<String> = newMessages.isEmpty ? [] : (self?.knownEmailIDs() ?? [])
            for message in newMessages {
                guard let id = message["id"] as? String else { continue }
                
                semaphore.wait()
                group.enter()
                self?.fetchMessageDetails(id: id, token: token) { body, receivedAt in
                    defer {
                        semaphore.signal()
                        group.leave()
                    }
                    
                    var foundBankName: String? = nil
                    
                    if body == nil { queue.sync { failedFetches += 1; failedIDs.append(id) } }
                    if let body = body {
                        let alreadyImported = queue.sync { knownIDs.contains(id) }
                        let parsed = alreadyImported ? nil : self?.parseEmailBody(body, receivedAt: receivedAt)
                        if alreadyImported {
                            queue.sync { alreadyImportedCount += 1 }
                            Diagnostics.shared.log("Sync Gmail: correo \(id) ya estaba importado")
                        } else if parsed == nil {
                            queue.sync { unrecognized += 1 }
                            Diagnostics.shared.log("Sync Gmail: correo \(id) no reconocido por ningún lector (\(body.count) caracteres): «\(Self.excerpt(body, 160))»")
                        }

                        if !alreadyImported, let parsed {
                            foundBankName = parsed.bankName
                            // Guardarlo redibuja el dashboard: nunca a mitad
                            // de un deslizamiento (ver `ScrollActivity`).
                            ScrollActivity.waitUntilIdle()
                            DispatchQueue.main.sync {
                                if let context = self?.modelContext {
                                    var inserted = false
                                    if let expense = parsed.expense {
                                        // Los datos, antes de insertarlo: al
                                        // insertar puede fundirse con otro
                                        // gasto ya existente (Apple).
                                        let title = expense.merchant
                                        let amount = expense.amount
                                        let currency = expense.currency
                                        let auto = expense.category == Accounting.unclassified ? "none"
                                            : (ClassificationLedger.peek(expense.id)?.rawValue ?? "other")
                                        inserted = self?.handleExpenseInsertion(expenseData: (expense, parsed.bankName), emailID: id, context: context) == true
                                        Self.trackParse(bank: parsed.bankName, kind: "expense", inserted: inserted,
                                                        emailID: id, receivedAt: receivedAt, isRange: isRangeSync,
                                                        extra: ["auto": auto, "reversal": expense.isReversal])
                                        Diagnostics.shared.log("Sync Gmail: correo \(id) → \(parsed.bankName) gasto\(expense.isReversal ? " (anulación)" : "") \(currency) \(amount) «\(title)» \(inserted ? "insertado" : "no insertado (duplicado o unido)")")
                                        // Sólo lo que acaba de llegar: leer seis
                                        // meses de pasado no son cien avisos.
                                        if inserted, !isRangeSync {
                                            NotificationManager.shared.notifyImported(
                                                title: title, amount: amount, currency: currency, isIncome: false)
                                        }
                                    } else if let income = parsed.income {
                                        let title = income.title ?? income.source
                                        let amount = income.amount
                                        let currency = income.currency
                                        inserted = self?.handleIncomeInsertion(income: income, emailID: id, context: context) == true
                                        Self.trackParse(bank: parsed.bankName, kind: "income", inserted: inserted,
                                                        emailID: id, receivedAt: receivedAt, isRange: isRangeSync)
                                        Diagnostics.shared.log("Sync Gmail: correo \(id) → \(parsed.bankName) ingreso \(currency) \(amount) \(inserted ? "insertado" : "no insertado (duplicado)")")
                                        if inserted, !isRangeSync {
                                            NotificationManager.shared.notifyImported(
                                                title: title, amount: amount, currency: currency, isIncome: true)
                                        }
                                    }
                                    if inserted {
                                        newExpensesFound += 1
                                    }
                                }
                            }
                            queue.sync { _ = knownIDs.insert(id) }
                        }
                        // Only add to processed if we successfully fetched it (prevents skipping on network failure)
                        queue.async {
                            if newIDSet.insert(id).inserted {
                                newIDs.append(id)
                            }
                        }
                    }
                    
                    DispatchQueue.main.async {
                        self?.emailsProcessed += 1
                        if let bankName = foundBankName {
                            self?.expensesFoundByBank[bankName, default: 0] += 1
                        }
                    }
                }
            }
            
            group.wait()
            // Aquí seguimos en un hilo de fondo, y así se queda: la limpieza
            // de después de leer recorre todo el historial varias veces, y en
            // el hilo principal congelaba la app 4 s al final de cada lectura
            // con algo nuevo (bitácora del 23/09, 3.0.2).
            let (failedNow, attempted) = queue.sync {
                // Tope: lo más viejo sobra. La lectura normal mira sólo la
                // última hora, y una por rango se apoya en la base para no
                // duplicar (`knownIDs`).
                UserDefaults.standard.set(Array(newIDs.suffix(Self.processedIDsCap)), forKey: "processedEmailIDs")
                return (failedIDs, newMessages.compactMap { $0["id"] as? String })
            }
            let pendingFailed = FailedEmails.record(failed: failedNow, attempted: attempted,
                                                    gone: self?.takeGoneEmailIDs() ?? [])
            DispatchQueue.main.async { self?.failedEmailCount = pendingFailed }
            self?.tidyUpAfterReading()
            DispatchQueue.main.async {
                // Una sincronización histórica acotada no marca "al día": si lo
                // hiciera, la automática miraría sólo desde hace una hora y el
                // tramo entre esa fecha final y hoy no se descargaría nunca.
                if coversNow {
                    self?.lastSyncDate = Date()
                }
                self?.isSyncing = false
                // Lo importado antes de guardar el banco se completa aparte,
                // una vez por correo.
                self?.backfillAccountData(token: token)
                print("Sync complete. Found \(newExpensesFound) new expenses of \(newMessages.count) checked.")
                let seconds = Int(Date().timeIntervalSince(runStart))
                // El sondeo de cada 10 s casi nunca trae nada: sólo cuentan
                // las lecturas que procesaron algo.
                if !newMessages.isEmpty || failedFetches > 0 {
                    Analytics.track(.emailSyncRun, ["range": isRangeSync,
                                                    "checked": newMessages.count,
                                                    "new": newExpensesFound,
                                                    "already": alreadyImportedCount,
                                                    "unrecognized": unrecognized,
                                                    "failed_fetch": failedFetches,
                                                    "retries": retries.count,
                                                    "seconds": seconds,
                                                    "quiet": quiet])
                }
                if failedFetches > 0 {
                    Analytics.error("sync_fetch", code: "message_download", ["count": failedFetches])
                }
                Diagnostics.shared.log("Sync Gmail: fin en \(seconds) s · revisados \(newMessages.count) · nuevos \(newExpensesFound) · ya importados \(alreadyImportedCount) · no reconocidos \(unrecognized) · descargas fallidas \(failedFetches)")
                if !quiet, !messages.isEmpty {
                    func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) " + (n == 1 ? one : many) }
                    var parts = [count(newMessages.count, "correo revisado", "correos revisados"),
                                 count(newExpensesFound, "nuevo", "nuevos")]
                    if alreadyImportedCount > 0 { parts.append(count(alreadyImportedCount, "ya estaba", "ya estaban")) }
                    if unrecognized > 0 { parts.append(count(unrecognized, "sin reconocer", "sin reconocer")) }
                    if failedFetches > 0 { parts.append(count(failedFetches, "no se pudo descargar", "no se pudieron descargar")) }
                    if newMessages.isEmpty {
                        parts = [messages.count == 1 ? "El correo de ese periodo ya se había leído"
                                                     : "Los \(messages.count) correos de ese periodo ya se habían leído"]
                    }
                    // Lo borrado a propósito no se vuelve a importar: que se
                    // note, o parecería que la lectura se los saltó por error.
                    if skippedDeleted > 0 { parts.append(count(skippedDeleted, "borrado por ti", "borrados por ti")) }
                    self?.lastRunSummary = parts.joined(separator: " · ")
                }
                if let partialError { self?.lastSyncError = partialError }
                self?.finishRun()
            }
        }
    }
    
    /// Lo de después de cada lectura: los gastos acaban de rearmarse desde el
    /// correo, así que ahora sí existen los que esperaban su marca de deuda o
    /// su categoría restaurada (ver `ConfigBackupManager`), y lo recién llegado
    /// puede ir a una cuenta tuya.
    ///
    /// **Desde un hilo de fondo**, con un `ModelContext` propio creado y usado
    /// en este mismo hilo. Cada paso guarda sólo si cambió algo —casi nunca—,
    /// y lo guardado llega solo al contexto principal y a las `@Query`.
    private func tidyUpAfterReading() {
        assert(!Thread.isMainThread, "tidyUpAfterReading bloquearía el hilo principal")
        let (container, preferences) = DispatchQueue.main.sync {
            (modelContext?.container, AccountBook.shared.preferences)
        }
        guard let container else { return }
        let started = Date()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        Self.removeLinkedDuplicates(in: context)
        ConfigBackupManager.reapplyPendingDecisions(modelContext: context)
        TransferDetector.apply(in: context, preferences: preferences)
        Diagnostics.shared.log("Sync Gmail: limpieza de después de leer en \(Int(Date().timeIntervalSince(started) * 1000)) ms (fuera del hilo principal)")
    }

    func recoverExpenses(ids: [String]) {
        // Sólo Outlook: sus correos no usan el token de Gmail.
        guard let token = Self.qaToken ?? GmailAuthService.shared.getAccessToken()
                ?? (OutlookAuthService.shared.isAuthenticated ? "" : nil) else { return }
        
        DispatchQueue.main.async {
            self.isSyncing = true
            self.lastSyncError = nil
            self.totalEmailsToProcess = ids.count
            self.emailsProcessed = 0
            self.expensesFoundByBank = [:]
        }
        
        var processedIDs = UserDefaults.standard.stringArray(forKey: "processedEmailIDs") ?? []
        let queue = DispatchQueue(label: "com.notifable.syncQueue")
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: 5)
        var newExpensesFound = 0

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Recuperar dos veces tampoco puede duplicar.
            var knownIDs: Set<String> = self?.knownEmailIDs() ?? []
            for id in ids {
                semaphore.wait()
                group.enter()
                self?.fetchMessageDetails(id: id, token: token) { body, receivedAt in
                    defer {
                        semaphore.signal()
                        group.leave()
                    }
                    
                    var foundBankName: String? = nil
                    if let body = body {
                        let alreadyImported = queue.sync { knownIDs.contains(id) }

                        if !alreadyImported, let parsed = self?.parseEmailBody(body, receivedAt: receivedAt) {
                            foundBankName = parsed.bankName
                            DispatchQueue.main.sync {
                                if let context = self?.modelContext {
                                    var inserted = false
                                    if let expense = parsed.expense {
                                        inserted = self?.handleExpenseInsertion(expenseData: (expense, parsed.bankName), emailID: id, context: context) == true
                                    } else if let income = parsed.income {
                                        inserted = self?.handleIncomeInsertion(income: income, emailID: id, context: context) == true
                                    }
                                    if inserted {
                                        newExpensesFound += 1
                                    }
                                }
                            }
                            queue.sync { _ = knownIDs.insert(id) }
                        }

                        queue.async {
                            if !processedIDs.contains(id) {
                                processedIDs.append(id)
                            }
                        }
                    }
                    
                    DispatchQueue.main.async {
                        self?.emailsProcessed += 1
                        if let bankName = foundBankName {
                            self?.expensesFoundByBank[bankName, default: 0] += 1
                        }
                    }
                }
            }
            
            group.wait()
            queue.sync {
                UserDefaults.standard.set(processedIDs, forKey: "processedEmailIDs")
                // Limpiamos la papelera
                DeletedEmails.clear()
            }
            self?.tidyUpAfterReading()
            DispatchQueue.main.async {
                self?.isSyncing = false
                print("Recovery complete. Restored \(newExpensesFound) expenses.")
            }
        }
    }
    
    /// El token de mentira del modo QA (`QAMode`); `nil` fuera de DEBUG.
    static var qaToken: String? {
        #if DEBUG
        return QAMode.isOn ? QAMode.fakeToken : nil
        #else
        return nil
        #endif
    }

    /// «Reintentar» del aviso de correos que no se pudieron leer.
    func retryFailedEmails() {
        syncEmails(force: true)
    }

    /// Al restablecer la lectura: todos los pendientes.
    func clearFailedEmails() {
        FailedEmails.clear()
        DispatchQueue.main.async { self.failedEmailCount = 0 }
    }

    /// Al desvincular un correo: sólo sus pendientes; los del otro siguen.
    func clearFailedEmails(provider: MailProviders) {
        let left = FailedEmails.remove { provider.contains(MailProviders.of($0)) }
        DispatchQueue.main.async { self.failedEmailCount = left }
    }

    /// Cuántos IDs procesados se guardan como mucho.
    static let processedIDsCap = 5000

    /// Correos que Gmail ya no tiene (404/410: el usuario los borró): no
    /// tiene sentido reintentarlos.
    private var goneEmailIDs: Set<String> = []
    private let goneLock = NSLock()

    private func markGone(_ id: String) {
        goneLock.lock(); goneEmailIDs.insert(id); goneLock.unlock()
    }

    private func takeGoneEmailIDs() -> Set<String> {
        goneLock.lock(); defer { goneLock.unlock() }
        let ids = goneEmailIDs
        goneEmailIDs = []
        return ids
    }

    func resetSyncState() {
        clearFailedEmails()
        UserDefaults.standard.removeObject(forKey: "processedEmailIDs")
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")
        DispatchQueue.main.async {
            self.lastSyncDate = nil
        }
    }
    
    func diagnosticBBVA() {
        guard let token = GmailAuthService.shared.getAccessToken() else {
            DispatchQueue.main.async { self.diagnosticResult = "No token"; self.showDiagnostic = true }
            return
        }
        DispatchQueue.main.async { self.diagnosticResult = "Buscando..."; self.showDiagnostic = true }
        
        let query = "from:procesos@bbva.com.pe pago"
        guard let url = URL(string: "\(baseURL)/messages?q=\(query)&maxResults=1") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data else { return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let messages = json["messages"] as? [[String: Any]],
                   let firstMessage = messages.first,
                   let id = firstMessage["id"] as? String {
                    self.fetchDiagnosticDetails(id: id, token: token)
                } else {
                    let raw = String(data: data, encoding: .utf8) ?? ""
                    DispatchQueue.main.async { self.diagnosticResult = "No se encontraron correos de BBVA Pago. \n\n\(raw)" }
                }
            } catch {}
        }.resume()
    }
    
    func diagnosticBBVATransfer() {
        guard let token = GmailAuthService.shared.getAccessToken() else {
            DispatchQueue.main.async { self.diagnosticResult = "No token"; self.showDiagnostic = true }
            return
        }
        DispatchQueue.main.async { self.diagnosticResult = "Buscando..."; self.showDiagnostic = true }
        
        let query = "from:procesos@bbva.com.pe terceros"
        guard let url = URL(string: "\(baseURL)/messages?q=\(query)&maxResults=1") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data else { return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let messages = json["messages"] as? [[String: Any]],
                   let firstMessage = messages.first,
                   let id = firstMessage["id"] as? String {
                    self.fetchDiagnosticDetails(id: id, token: token)
                } else {
                    let raw = String(data: data, encoding: .utf8) ?? ""
                    DispatchQueue.main.async { self.diagnosticResult = "No se encontraron transferencias BBVA. \n\n\(raw)" }
                }
            } catch {}
        }.resume()
    }
    
    private func fetchDiagnosticDetails(id: String, token: String) {
        guard let url = URL(string: "\(baseURL)/messages/\(id)?format=full") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data else { return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    let bodyText = self.extractFullText(from: json)
                    let parser = YapeParser() // Por defecto
                    let appleParser = AppleParser()
                    let bbvaParser = BBVAParser()
                    
                    var result: Expense? = nil
                    var parserUsed = ""
                    
                    if let appleRes = appleParser.parse(cleanText: bodyText) {
                        result = appleRes
                        parserUsed = "AppleParser"
                    } else if let bbvaRes = bbvaParser.parse(cleanText: bodyText) {
                        result = bbvaRes
                        parserUsed = "BBVAParser"
                    } else if let yapeRes = parser.parse(cleanText: bodyText) {
                        result = yapeRes
                        parserUsed = "YapeParser"
                    }
                    
                    // Fecha en dos formatos: ISO con offset (para no dejar dudas
                    // de zona horaria) y como la vería el usuario en la app — así el
                    // diagnóstico permite comparar directo contra "Fecha y hora de la
                    // operación" del correo sin adivinar.
                    var fechaDebug = "NIL"
                    if let parsedDate = result?.date {
                        let iso = ISO8601DateFormatter()
                        iso.timeZone = TimeZone.current
                        iso.formatOptions = [.withInternetDateTime]
                        let display = DateFormatter()
                        display.locale = Locale(identifier: "es_ES")
                        display.dateFormat = "EEEE d 'de' MMMM, yyyy HH:mm"
                        fechaDebug = "\(display.string(from: parsedDate))  (\(iso.string(from: parsedDate)))"
                        if abs(parsedDate.timeIntervalSinceNow) < 5 {
                            fechaDebug += "  ⚠️ igual a \"ahora\": el patrón de fecha del parser no matcheó y quedó el valor por defecto"
                        }
                    }

                    let finalStr = """
                    --- RAW JSON ---
                    Snippet: \(json["snippet"] as? String ?? "")
                    
                    --- TEXTO EXTRAÍDO ---
                    \(bodyText)
                    
                    --- RESULTADO \(parserUsed) ---
                    Monto: \(result != nil ? String(result!.amount) : "NIL")
                    Merchant: \(result != nil ? result!.merchant : "NIL")
                    Fecha: \(fechaDebug)
                    """
                    DispatchQueue.main.async { self.diagnosticResult = finalStr }
                }
            } catch {}
        }.resume()
    }
    
    func diagnosticApple() {
        guard let token = GmailAuthService.shared.getAccessToken() else {
            DispatchQueue.main.async { self.diagnosticResult = "No token"; self.showDiagnostic = true }
            return
        }
        DispatchQueue.main.async { self.diagnosticResult = "Buscando..."; self.showDiagnostic = true }
        
        let query = "from:no_reply@email.apple.com Factura"
        guard let url = URL(string: "\(baseURL)/messages?q=\(query)&maxResults=1") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data else { return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let messages = json["messages"] as? [[String: Any]],
                   let firstMessage = messages.first,
                   let id = firstMessage["id"] as? String {
                    self.fetchDiagnosticDetails(id: id, token: token)
                } else {
                    let raw = String(data: data, encoding: .utf8) ?? ""
                    DispatchQueue.main.async { self.diagnosticResult = "No se encontraron recibos de Apple. \n\n\(raw)" }
                }
            } catch {}
        }.resume()
    }
    
    /// Devuelve el texto del correo y cuándo lo recibió Gmail (`internalDate`,
    /// en milisegundos). Esa fecha es el respaldo cuando el parser no logra
    /// leer la del movimiento: ver `parseEmailBody`.
    private func fetchMessageDetails(id: String, token: String, completion: @escaping (String?, Date?) -> Void) {
        #if DEBUG
        if QAMode.isOn {
            let mail = QAMode.email(id: id)
            completion(mail?.body, mail?.receivedAt)
            return
        }
        #endif
        if OutlookMail.isOutlookID(id) {
            OutlookAuthService.shared.validAccessToken { token in
                guard let token else { return completion(nil, nil) }
                OutlookMail.fetch(id: id, token: token) { body, receivedAt, gone in
                    if gone { self.markGone(id) }
                    completion(body, receivedAt)
                }
            }
            return
        }
        guard let url = URL(string: "\(baseURL)/messages/\(id)?format=full") else {
            completion(nil, nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                Diagnostics.shared.log("Sync Gmail: ✗ correo \(id), error de red: \(error.map(Self.describe) ?? "sin datos")")
                completion(nil, nil)
                return
            }
            // Una respuesta de error también es JSON: antes se leía como un
            // correo vacío, no lo reconocía ningún lector y quedaba marcado
            // como procesado para siempre.
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(status) else {
                Diagnostics.shared.log("Sync Gmail: ✗ correo \(id) HTTP \(status): \(Self.bodyExcerpt(data))")
                if status == 404 || status == 410 { self.markGone(id) }
                completion(nil, nil)
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    let bodyText = self.extractFullText(from: json)
                    Diagnostics.shared.log("Sync Gmail: correo \(id) · \(Self.header("From", in: json) ?? "?") · «\(Self.header("Subject", in: json) ?? "?")» · \(Self.mimeSummary(json)) · \(bodyText.count) caracteres")
                    
                    let receivedAt = (json["internalDate"] as? String)
                        .flatMap(Double.init)
                        .map { Date(timeIntervalSince1970: $0 / 1000) }
                    completion(bodyText, receivedAt)
                } else {
                    completion(nil, nil)
                }
            } catch {
                completion(nil, nil)
            }
        }.resume()
    }
    
    func extractFullText(from json: [String: Any]) -> String {
        guard let payload = json["payload"] as? [String: Any] else {
            return json["snippet"] as? String ?? ""
        }
        
        var plainText = ""
        var htmlText = ""
        
        func traverseParts(_ parts: [[String: Any]]) {
            for part in parts {
                if let mimeType = part["mimeType"] as? String {
                    if mimeType == "text/plain", let body = part["body"] as? [String: Any], let data = body["data"] as? String, let decoded = self.decodeBase64Url(data) {
                        plainText += self.decodeQuotedPrintable(decoded) + " "
                    } else if mimeType == "text/html", let body = part["body"] as? [String: Any], let data = body["data"] as? String, let decoded = self.decodeBase64Url(data) {
                        htmlText += self.decodeQuotedPrintable(decoded) + " "
                    }
                }
                if let subParts = part["parts"] as? [[String: Any]] {
                    traverseParts(subParts)
                }
            }
        }
        
        if let parts = payload["parts"] as? [[String: Any]] {
            traverseParts(parts)
        } else if let mimeType = payload["mimeType"] as? String, let body = payload["body"] as? [String: Any], let data = body["data"] as? String, let decoded = self.decodeBase64Url(data) {
            if mimeType == "text/plain" { plainText = self.decodeQuotedPrintable(decoded) }
            if mimeType == "text/html" { htmlText = self.decodeQuotedPrintable(decoded) }
        }
        
        if !plainText.isEmpty {
            return plainText
        } else if !htmlText.isEmpty {
            // Strip HTML tags roughly by replacing them with spaces
            let stripped = htmlText.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression, range: nil)
            return Self.decodeHTMLEntities(stripped)
        }
        
        return json["snippet"] as? String ?? ""
    }
    
    /// Tolerancia para decidir que la fecha que dio el parser es imposible.
    /// Holgada a propósito: el parser interpreta la hora del correo en la zona
    /// del teléfono, que puede estar varias horas por delante de la de Perú.
    static let impossibleDateSlack: TimeInterval = 12 * 3600

    /// Un movimiento no puede ser posterior al correo que lo avisa. Si lo es,
    /// el parser no encontró la fecha y cayó en su respaldo `Date()`: al
    /// reinstalar y releer meses de correo, todos esos gastos acababan con la
    /// hora de la reinstalación, amontonados en el mes actual. La fecha en que
    /// Gmail recibió el correo es una aproximación mucho mejor.
    static func correctedDate(_ parsed: Date, receivedAt: Date?) -> Date {
        guard let receivedAt, parsed.timeIntervalSince(receivedAt) > impossibleDateSlack else { return parsed }
        return receivedAt
    }

    func parseEmailBody(_ text: String, receivedAt: Date?) -> (expense: Expense?, income: Income?, bankName: String)? {
        let cleanText = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")

        for parser in parsers {
            if let expense = parser.parse(cleanText: cleanText) {
                // Un monto en cero es un monto que no se pudo leer (un formato
                // nuevo del banco, un separador inesperado): guardarlo pasaría
                // por bueno un gasto falso. Mejor «no reconocido» en Diagnóstico.
                guard Money.cents(expense.amount) > 0 else {
                    Diagnostics.shared.log("Sync Gmail: \(parser.bankName) reconoció el correo pero no su monto; se descarta")
                    Analytics.track(.emailParse, ["bank": parser.bankName, "kind": "expense", "result": "amount_missing"])
                    continue
                }
                let fixed = Self.correctedDate(expense.date, receivedAt: receivedAt)
                if fixed != expense.date {
                    Diagnostics.shared.log("Sync Gmail: \(parser.bankName) sin fecha legible, se usa la del correo")
                    expense.date = fixed
                }
                // De qué cuenta salió y, en un Plin/Yape, a qué billetera fue:
                // lo que el carrusel de Movimientos y los traslados necesitan.
                Self.applyAccountDetails(to: expense, bankName: parser.bankName, cleanText: cleanText)
                return (applyAutoCategorization(to: expense), nil, parser.bankName)
            }
        }

        // Un correo no puede ser gasto e ingreso a la vez: sólo se prueba
        // parseIncome cuando ningún parser lo reconoció como gasto.
        for parser in parsers {
            if let income = parser.parseIncome(cleanText: cleanText) {
                guard Money.cents(income.amount) > 0 else {
                    Diagnostics.shared.log("Sync Gmail: \(parser.bankName) reconoció el ingreso pero no su monto; se descarta")
                    Analytics.track(.emailParse, ["bank": parser.bankName, "kind": "income", "result": "amount_missing"])
                    continue
                }
                income.date = Self.correctedDate(income.date, receivedAt: receivedAt)
                return (nil, income, parser.bankName)
            }
        }

        return nil
    }

    /// De qué cuenta salió, a qué billetera fue, el celular de quien lo
    /// recibió y si la tarjeta es de débito o crédito. Lo que el carrusel de
    /// Movimientos y los traslados necesitan (`EmailAccountDetails`).
    static func applyAccountDetails(to expense: Expense, bankName: String, cleanText: String) {
        expense.sourceBank = bankName
        expense.destinationWallet = EmailAccountDetails.destinationWallet(in: cleanText)
        expense.payeePhone = EmailAccountDetails.payeePhone(in: cleanText)
        expense.cardKind = EmailAccountDetails.cardKind(in: cleanText, digits: expense.cardLastDigits)
    }
    
    // MARK: - Autocategorización Global
    
    private func applyAutoCategorization(to expense: Expense) -> Expense {
        // Una regla que el usuario ya definió en la Bandeja manda sobre todo lo
        // demás: para eso la definió. Antes sólo se reetiquetaban los gastos que
        // ya estaban en la base y el siguiente correo del mismo comercio volvía
        // a caer sin clasificar.
        if let rule = MerchantRules.category(for: expense.merchant) {
            expense.category = rule
            expense.isSubscription = BuiltInCategories.marksSubscription(rule)
            if rule != Accounting.unclassified { ClassificationLedger.record(expense.id, engine: .rule) }
            return expense
        }

        var autoCategory = Accounting.unclassified
        let lowerMerchant = expense.merchant.lowercased()
        if lowerMerchant.contains("starbucks") || lowerMerchant.contains("eats") || lowerMerchant.contains("tambo") || lowerMerchant.contains("sharethemeal") {
            autoCategory = "Comida"
        } else if lowerMerchant.contains("uber") || lowerMerchant.contains("lyft") || lowerMerchant.contains("didi") || lowerMerchant.contains("cabify") || lowerMerchant.contains("yango") {
            autoCategory = "Transporte"
        } else if lowerMerchant.contains("netflix") || lowerMerchant.contains("spotify") || lowerMerchant.contains("apple") || lowerMerchant.contains("disney") || lowerMerchant.contains("prime") {
            autoCategory = "Suscripciones"
        }

        // Nombres de fábrica: la básica que el usuario quitó no vuelve.
        let resolved = CategoryCatalog.shared.builtIns.resolve(autoCategory) ?? Accounting.unclassified
        expense.category = resolved
        expense.isSubscription = autoCategory == "Suscripciones"
        if resolved != Accounting.unclassified { ClassificationLedger.record(expense.id, engine: .keyword) }
        return expense
    }

    /// `email_parse` de un correo reconocido. La latencia es lo que tardó en
    /// aparecer desde que llegó: sólo dice algo en las lecturas normales.
    static func trackParse(bank: String, kind: String, inserted: Bool, emailID: String,
                           receivedAt: Date?, isRange: Bool, extra: [String: Any] = [:]) {
        var props = extra
        props["bank"] = bank
        props["kind"] = kind
        props["result"] = inserted ? "inserted" : "duplicate"
        props["provider"] = OutlookMail.isOutlookID(emailID) ? "outlook" : "gmail"
        props["range"] = isRange
        if let receivedAt, !isRange {
            props["latency_min"] = max(0, Date().timeIntervalSince(receivedAt) / 60)
        }
        Analytics.track(.emailParse, props)
        guard inserted else { return }
        Analytics.milestone(.firstMovement)
        Analytics.milestone(.firstEmailMovement)
    }
    
    private func decodeBase64Url(_ base64Url: String) -> String? {
        var base64 = base64Url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        let length = Double(base64.lengthOfBytes(using: String.Encoding.utf8))
        let requiredLength = 4 * ceil(length / 4.0)
        let paddingLength = requiredLength - length
        if paddingLength > 0 {
            let padding = "".padding(toLength: Int(paddingLength), withPad: "=", startingAt: 0)
            base64 += padding
        }
        
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
    
    /// Las entidades que traen los correos de los bancos: con nombre (las
    /// letras acentuadas en minúscula y mayúscula, `&amp;`, `&nbsp;`…) y
    /// numéricas (`&#243;`, `&#xF3;`). Antes sólo se traducían ocho; una
    /// plantilla nueva con `&#243;` dejaba «Operaci&#243;n» y el lector ya no
    /// reconocía el correo.
    static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "aacute": "á", "eacute": "é", "iacute": "í", "oacute": "ó", "uacute": "ú",
            "Aacute": "Á", "Eacute": "É", "Iacute": "Í", "Oacute": "Ó", "Uacute": "Ú",
            "ntilde": "ñ", "Ntilde": "Ñ", "uuml": "ü", "Uuml": "Ü",
            "iexcl": "¡", "iquest": "¿", "ordm": "º", "ordf": "ª", "deg": "°",
            "middot": "·", "ndash": "–", "mdash": "—", "laquo": "«", "raquo": "»",
            "euro": "€", "copy": "©", "reg": "®",
            // Las viñetas se quitaban: los lectores ya cuentan con eso.
            "bull": ""
        ]
        guard let regex = try? NSRegularExpression(pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});") else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let body = ns.substring(with: match.range(at: 1))
            var replacement: String?
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let value = digits.first == "x" || digits.first == "X"
                    ? UInt32(digits.dropFirst(), radix: 16)
                    : UInt32(digits)
                // 160 es el espacio duro: como `&nbsp;`, un espacio normal.
                if value == 160 {
                    replacement = " "
                } else if let value, let scalar = Unicode.Scalar(value) {
                    replacement = String(Character(scalar))
                }
            } else {
                replacement = named[body]
            }
            result += replacement ?? ns.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// Gmail ya entrega el cuerpo sin el Quoted-Printable del correo: volver a
    /// decodificarlo siempre convertía un `?id=AB` de un enlace en un byte
    /// suelto, y un `=C3=B1` en «Ã±». Sólo se decodifica si el texto aún lo
    /// parece (un correo mal armado que lo trae dos veces), y los bytes se
    /// leen primero como UTF-8.
    static func looksQuotedPrintable(_ text: String) -> Bool {
        if text.contains("=\r\n") || text.contains("=\n") || text.contains("=3D") { return true }
        guard let regex = try? NSRegularExpression(pattern: "=[0-9A-F]{2}") else { return false }
        return regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) >= 3
    }

    private func decodeQuotedPrintable(_ input: String) -> String {
        guard Self.looksQuotedPrintable(input) else { return input }
        // 1. Remove soft line breaks: "=" followed by "\r\n" or "\n"
        var processed = input.replacingOccurrences(of: "=\\r\\n", with: "", options: .regularExpression)
        processed = processed.replacingOccurrences(of: "=\\n", with: "", options: .regularExpression)
        
        // 2. Convert to bytes and decode =XX
        guard let data = processed.data(using: .ascii) else { return processed }
        
        var outputData = Data()
        outputData.reserveCapacity(data.count)
        
        var i = 0
        let bytes = [UInt8](data)
        
        while i < bytes.count {
            if bytes[i] == 61 { // '=' character
                if i + 2 < bytes.count {
                    let hexStr = String(bytes: [bytes[i+1], bytes[i+2]], encoding: .ascii) ?? ""
                    if let hexByte = UInt8(hexStr, radix: 16) {
                        outputData.append(hexByte)
                        i += 3
                        continue
                    }
                }
            }
            outputData.append(bytes[i])
            i += 1
        }
        
        return String(data: outputData, encoding: .utf8) ?? String(data: outputData, encoding: .isoLatin1) ?? processed
    }
    
    /// ¿Ya existe un movimiento de este correo? Se pregunta a la base justo
    /// antes de insertar, en el hilo principal, que es donde se inserta.
    ///
    /// `knownIDs` sólo es una foto tomada al empezar cada lectura: dos lecturas
    /// que se solapan (la del onboarding y una de rango, por ejemplo) no ven lo
    /// que inserta la otra, y cada una creaba su copia del mismo correo. Antes
    /// esta comprobación sólo existía en el camino de Apple.
    static func isAlreadyImported(emailID: String, context: ModelContext) -> Bool {
        let expenses = FetchDescriptor<Expense>(predicate: #Predicate {
            $0.emailID == emailID || $0.relatedEmailID == emailID
        })
        let incomes = FetchDescriptor<Income>(predicate: #Predicate { $0.emailID == emailID })
        return ((try? context.fetchCount(expenses)) ?? 0) > 0
            || ((try? context.fetchCount(incomes)) ?? 0) > 0
    }

    private func handleExpenseInsertion(expenseData: (expense: Expense, bankName: String), emailID: String, context: ModelContext) -> Bool {
        let newExpense = expenseData.expense
        if Self.isAlreadyImported(emailID: emailID, context: context) { return false }
        
        let isAppleReceipt = expenseData.bankName == "Apple"
        let isAppleBankBill = !isAppleReceipt && newExpense.merchant.lowercased().contains("apple")
        
        if isAppleReceipt || isAppleBankBill {
            let amount = newExpense.amount
            let date = newExpense.date
            
            let allExpenses = (try? context.fetch(FetchDescriptor<Expense>())) ?? []

            // Este correo ya está en un gasto, propio o unido: no hay nada que
            // crear. Segunda red por si llega aquí sin pasar por `knownIDs`.
            if allExpenses.contains(where: { $0.emailID == emailID || $0.relatedEmailID == emailID }) {
                return false
            }

            if let match = allExpenses.first(where: {
                $0.id != newExpense.id &&
                $0.relatedEmailID == nil &&
                $0.amount == amount &&
                abs($0.date.timeIntervalSince(date)) <= 48 * 3600 &&
                ($0.merchant.lowercased().contains("apple") || $0.merchant == "Apple")
            }) {
                if isAppleReceipt {
                    // Overwrite match (Bank Expense) with Apple Receipt details
                    match.merchant = newExpense.merchant == "Apple" ? match.merchant : "Apple: \(newExpense.merchant)"
                    if let notes = newExpense.notes { match.notes = notes }
                    match.isSubscription = newExpense.isSubscription
                    match.category = newExpense.category
                    match.relatedEmailID = emailID
                } else {
                    // Llega el cargo del banco, pero el recibo de Apple ya
                    // había creado el gasto (llegó primero). La factura de
                    // Apple sólo trae el día — sin hora, queda en 00:00 — así
                    // que la hora real hay que tomarla del correo del banco,
                    // que sí la tiene.
                    match.date = date
                    if let card = newExpense.cardLastDigits { match.cardLastDigits = card }
                    // El recibo de Apple no dice de qué banco salió; el cargo sí.
                    match.sourceBank = expenseData.bankName
                    match.cardKind = newExpense.cardKind
                    match.relatedEmailID = emailID
                }
                try? context.save()
                return true
            }
        }
        
        if isAppleReceipt {
            // No se encontró el cargo del banco todavía para vincularlo (puede
            // llegar después, o nunca si el usuario no sincroniza ese correo).
            // Si no le ponemos ya el prefijo "Apple:", este gasto se guarda con
            // el nombre de la app/plan ("Claude by Anthropic...") sin la
            // palabra "apple" en ningún lado — y cuando el cargo del banco
            // llegue después, la búsqueda por merchant.contains("apple") no lo
            // va a encontrar y el gasto se duplica. Poniéndolo desde ya, la
            // vinculación funciona sin importar en qué orden lleguen los correos.
            newExpense.merchant = newExpense.merchant == "Apple" ? newExpense.merchant : "Apple: \(newExpense.merchant)"
        }
        
        newExpense.emailID = emailID
        context.insert(newExpense)
        try? context.save()
        return true
    }

    /// Constancias de dinero recibido (ej. un Yapeo entrante): a diferencia de
    /// los gastos, no hay vínculo con Apple ni deduplicación especial que
    /// resolver — el `emailID` ya evita procesarlo dos veces.
    private func handleIncomeInsertion(income: Income, emailID: String, context: ModelContext) -> Bool {
        if Self.isAlreadyImported(emailID: emailID, context: context) { return false }
        income.emailID = emailID
        context.insert(income)
        try? context.save()
        return true
    }
}

// MARK: - Relleno de datos de cuenta

extension GmailSyncService {

    /// Correos ya releídos para el relleno, aunque no dieran nada (el correo
    /// se borró, ningún parser lo reconoce): no se vuelven a pedir.
    private static let backfillTriedKey = "accountBackfillTriedIDs"

    /// Lo importado antes de que se guardara el banco (`sourceBank`) no dice
    /// de qué tarjeta salió. Un consumo BBVA —«Comercio: … tarjeta terminada
    /// en 8156»— no lleva prefijo en el comercio, así que caía en «Tarjeta
    /// ••••8156» aunque fuera BBVA, y dos tarjetas BBVA se veían como una BBVA
    /// y una «Tarjeta».
    ///
    /// Se relee cada correo **una vez** y se rellenan banco, destino, celular,
    /// tipo de tarjeta y —si faltaban— los dígitos. Nada más: categoría,
    /// etiquetas, notas o monto editado no se tocan.
    func backfillAccountData(token: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.backfillAccountData(token: token) }
            return
        }
        guard !Self.isBackfilling, Self.qaToken == nil, let context = modelContext else { return }

        let tried = Set(UserDefaults.standard.stringArray(forKey: Self.backfillTriedKey) ?? [])
        let descriptor = FetchDescriptor<Expense>(predicate: #Predicate { $0.emailID != nil && $0.sourceBank == nil })
        var byID: [UUID: Expense] = [:]
        var jobs: [(id: UUID, emailIDs: [String])] = []
        for expense in (try? context.fetch(descriptor)) ?? [] {
            // Un gasto unido a un recibo de Apple lleva los dos correos; el
            // del banco es el que dice la tarjeta, y no se sabe cuál llegó
            // primero.
            let emailIDs = [expense.emailID, expense.relatedEmailID].compactMap { $0 }.filter { !tried.contains($0) }
            guard !emailIDs.isEmpty else { continue }
            byID[expense.id] = expense
            jobs.append((expense.id, emailIDs))
        }
        guard !jobs.isEmpty else { return }

        Self.isBackfilling = true
        Diagnostics.shared.log("Cuentas: releyendo \(jobs.count) correos antiguos para saber su banco")

        struct Found { var bank: String; var destination: String?; var phone: String?; var kind: String?; var digits: String? }
        let queue = DispatchQueue(label: "com.notifable.accountBackfill")
        var found: [UUID: Found] = [:]
        var attempted: [String] = []
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: 5)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            for job in jobs {
                semaphore.wait()
                group.enter()
                self?.backfillFetch(emailIDs: job.emailIDs, token: token) { result, fetched in
                    queue.sync {
                        attempted.append(contentsOf: fetched)
                        if let result {
                            found[job.id] = Found(bank: result.sourceBank ?? "", destination: result.destinationWallet,
                                                  phone: result.payeePhone, kind: result.cardKind,
                                                  digits: result.cardLastDigits)
                        }
                    }
                    semaphore.signal()
                    group.leave()
                }
            }
            group.wait()

            DispatchQueue.main.async {
                let (found, attempted) = queue.sync { (found, attempted) }
                for (id, data) in found {
                    guard let expense = byID[id], !data.bank.isEmpty else { continue }
                    expense.sourceBank = data.bank
                    expense.destinationWallet = data.destination
                    expense.payeePhone = data.phone
                    expense.cardKind = data.kind
                    if expense.cardLastDigits == nil { expense.cardLastDigits = data.digits }
                }
                try? context.save()
                UserDefaults.standard.set(Array(tried.union(attempted)), forKey: Self.backfillTriedKey)
                TransferDetector.apply(in: context)
                Self.isBackfilling = false
                Diagnostics.shared.log("Cuentas: \(found.count) de \(jobs.count) gastos antiguos con banco")
            }
        }
    }

    private static var isBackfilling = false

    /// Relee los correos de un gasto en orden y se queda con el primero que
    /// diga un banco de verdad (no el recibo de Apple). Devuelve también los
    /// ids que sí se descargaron, para no volver a pedirlos.
    private func backfillFetch(emailIDs: [String], token: String,
                               completion: @escaping (Expense?, [String]) -> Void) {
        var remaining = emailIDs
        var fetched: [String] = []
        var fallback: Expense?

        func next() {
            guard !remaining.isEmpty else { return completion(fallback, fetched) }
            let id = remaining.removeFirst()
            fetchMessageDetails(id: id, token: token) { [weak self] body, receivedAt in
                guard let body else { return next() }   // red: se reintenta otro día
                fetched.append(id)
                if let parsed = self?.parseEmailBody(body, receivedAt: receivedAt), let expense = parsed.expense {
                    if parsed.bankName != "Apple" { return completion(expense, fetched) }
                    fallback = fallback ?? expense
                }
                next()
            }
        }
        next()
    }
}
