import Foundation
import SwiftData
import UIKit
import CryptoKit

/// Sincronización de todo lo que se pierde al formatear el celular y **no** se
/// puede rearmar releyendo el correo.
///
/// Qué sube
/// - Configuración: reglas de comercio, catálogo de categorías (con sus
///   renombrados), límites por categoría, presupuesto, bancos activos,
///   notificaciones, apariencia, atajos rápidos y gastos recurrentes.
/// - Decisiones sobre movimientos que el correo no contiene: marcas de deuda y
///   categorías puestas a mano a un gasto suelto. Viajan con una huella
///   (`TransactionKey`) que sobrevive a que el gasto se borre y se vuelva a
///   crear al releer Gmail.
/// - Movimientos creados a mano (sin correo detrás), incluidos los abonos a
///   deudas: si no se suben, no hay de dónde recuperarlos.
///
/// Qué NO sube: los gastos e ingresos que vienen del correo. Se reconstruyen
/// solos, y subirlos sería mandar el detalle financiero completo a un servidor
/// sin necesidad.
///
/// Identidad, en orden de preferencia
/// 1. `.account` — la cuenta de Google que el usuario ya usa para leer su
///    correo (`BackupAccount`). No tiene que guardar nada.
/// 2. `.code` — para quien no quiere iniciar sesión: un código que sí debe
///    guardar por su cuenta, porque es la única llave.
@MainActor
@Observable
final class ConfigBackupManager {

    static let shared = ConfigBackupManager()

    enum Mode: String {
        case off, account, code
    }

    private let projectURL = "https://zjzzqaeusmxmtszgdncl.supabase.co"
    private let apiKey = "sb_publishable_NVM2GcvxZFmf0VLNbaBr7A_y_8EMS97"

    private enum Keys {
        static let mode = "configBackupMode"
        static let backupCode = "configBackupCode"
        static let lastSyncedAt = "configBackupLastSyncedAt"
        static let fingerprint = "configBackupFingerprint"
        static let pausedMode = "configBackupPausedMode"
        static let pausedCode = "configBackupPausedCode"
        /// Huella de lo que había en el teléfono al pausar. Si la de ahora es
        /// distinta, hay algo que la sincronización automática querría subir.
        static let pausedFingerprint = "configBackupPausedFingerprint"
        static let offerDismissed = "configBackupOfferDismissed"
    }

    // MARK: - Estado observable

    private(set) var mode: Mode = .off
    private(set) var backupCode: String?
    private(set) var lastSyncedAt: Date?
    private(set) var isSyncing = false
    private(set) var hasPendingChanges = false
    /// Llegó un cambio mientras se subía: al terminar hay que volver a mirar.
    /// Antes `markDirty` lo descartaba y ese cambio esperaba al siguiente
    /// guardado o a volver a abrir la app.
    private var changedDuringSync = false

    /// Respaldo encontrado para la cuenta recién conectada, en un teléfono que
    /// todavía no sincroniza. Lo enseña `BackupFoundView`.
    var foundBackup: BackupHeader?

    /// Con la sincronización en pausa sobre una copia que existe, el usuario
    /// cambió algo que habría que subir. Subirlo borraría esa copia, así que
    /// en vez de hacerlo se pregunta con `OverwriteBackupSheet`.
    var overwritePrompt: BackupHeader?
    /// Una vez por sesión: preguntar en cada cambio sería acoso, y "Ahora no"
    /// tiene que poder significar "ahora no".
    private var askedOverwriteThisSession = false
    private var pausedCheck: Task<Void, Never>?

    /// `GmailLinkFlow` está en pantalla y va a hacer la misma pregunta con su
    /// propio paso de "Encontramos tu configuración". Sin esto, volver de
    /// Google reactiva la escena, dispara `checkForExistingBackup()` y el
    /// usuario recibe la oferta dos veces —una encima de la otra.
    var isPresentingLinkFlow = false {
        didSet { if isPresentingLinkFlow { foundBackup = nil } }
    }

    /// `true` si el usuario ya contestó a la oferta de restaurar —restaurando
    /// o diciendo "ahora no"—, así ninguna otra pantalla la vuelve a plantear.
    var wasBackupOfferAnswered: Bool { UserDefaults.standard.bool(forKey: Keys.offerDismissed) }

    /// Se pausó sola tras un "Empezar de cero": ver `pauseAfterLocalWipe()`.
    var isPausedAfterWipe: Bool { Self.code(for: Keys.pausedCode) != nil }
    var lastErrorMessage: String?

    var isEnabled: Bool { mode != .off }

    /// Activada pero sin Pro: no sube nada; lo guardado en la nube queda
    /// intacto y se retoma al volver a Pro («Configuración Pro», `4l`).
    var isPausedForPro: Bool { isEnabled && !ProStore.isPro }
    var accountEmail: String? { BackupAccount.shared.email ?? GmailAuthService.shared.accountEmail }

    /// `true` si activar la sincronización no le va a pedir nada al usuario.
    var canUseAccount: Bool { BackupAccount.shared.isSignedIn || BackupAccount.shared.canSignInSilently }

    // MARK: - Infraestructura

    private var container: ModelContainer?
    private var debounce: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let d = UserDefaults.standard
        mode = Mode(rawValue: d.string(forKey: Keys.mode) ?? "") ?? .off
        backupCode = Self.code(for: Keys.backupCode)
        lastSyncedAt = d.object(forKey: Keys.lastSyncedAt) as? Date
        // Un código guardado sin modo viene de la versión anterior del respaldo.
        if mode == .off, backupCode != nil { mode = .code; persistMode() }
    }

    /// Se llama una vez desde `NotifableApp`. A partir de aquí la clase se
    /// sincroniza sola: no hace falta que ninguna vista le avise de nada.
    func configure(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        startWatching()
        Task {
            // Reaplicar ediciones y vínculos toca modelos de SwiftData y guarda.
            // Hacerlo síncrono aquí era hacerlo **mientras SwiftUI monta la
            // vista** —`configure` se llama desde el `.task` del arranque— y eso
            // dispara "modificar estado durante una actualización de vista".
            // Un `yield` deja que el primer dibujado termine antes.
            await Task.yield()
            Self.reapplyPendingDecisions(modelContext: container.mainContext)
            _ = await syncIfNeeded()
            await checkForExistingBackup()
        }
    }

    /// Celular nuevo: el usuario acaba de conectar su correo y esa cuenta ya
    /// tiene un respaldo. Preguntar una vez es la diferencia entre recuperar la
    /// configuración y volver a armarla a mano; insistir sería acoso, así que
    /// "Ahora no" se recuerda.
    func checkForExistingBackup() async {
        // El onboarding es un `fullScreenCover` y sólo puede haber uno: si
        // ofreciéramos restaurar mientras está encima, la oferta no se vería y
        // se daría por descartada.
        guard UserDefaults.standard.bool(forKey: "hasSeenOnboarding") else { return }
        guard !isPresentingLinkFlow else { return }
        // Hay una vinculación por atender: la secuencia completa —restaurar y
        // luego elegir desde cuándo leer— la hace `GmailLinkFlow`. El aviso
        // suelto se adelantaba, restauraba por su cuenta y dejaba al usuario
        // sin la segunda mitad.
        guard !UserDefaults.standard.bool(forKey: GmailAuthService.pendingLinkFlowKey) else { return }
        guard !isEnabled, !isPausedAfterWipe else { return }
        guard !UserDefaults.standard.bool(forKey: Keys.offerDismissed) else { return }
        guard BackupAccount.shared.canSignInSilently || BackupAccount.shared.isSignedIn else { return }
        if !BackupAccount.shared.isSignedIn, await BackupAccount.shared.signInWithGoogle() != nil { return }

        let header = await peek(code: nil)
        // "Esta cuenta todavía no tiene respaldo" es la respuesta normal de un
        // usuario nuevo: no es un error que valga la pena enseñar.
        lastErrorMessage = nil
        guard let header, header.hasData else { return }
        foundBackup = header
    }

    /// "Ahora no": no se vuelve a preguntar sola. La pantalla de Sincronización
    /// sigue ahí para quien cambie de opinión.
    ///
    /// Si había una copia, la sincronización queda **en pausa** apuntando a
    /// ella (ver `keepRemotePaused`), no apagada del todo: así Ajustes ofrece
    /// traerla o reemplazarla con un toque.
    func dismissBackupOffer() {
        if let header = foundBackup { keepRemotePaused(header) }
        foundBackup = nil
        UserDefaults.standard.set(true, forKey: Keys.offerDismissed)
    }

    /// El usuario no quiso restaurar una copia que existe. Encender la
    /// sincronización en ese momento subiría este teléfono vacío y —como
    /// `write_config_backup` reemplaza todo— borraría la copia de la nube,
    /// justo lo que la pantalla promete que no pasa ("Tu copia se queda
    /// guardada en tu cuenta"). Se deja en la misma pausa que usa "Empezar de
    /// cero", que ya sabe reanudar trayendo la copia o reemplazándola.
    func keepRemotePaused(_ header: BackupHeader) {
        guard !isEnabled, header.hasData else { return }
        let d = UserDefaults.standard
        d.set(Mode.account.rawValue, forKey: Keys.pausedMode)
        Self.setCode(header.backupCode, for: Keys.pausedCode)
        d.removeObject(forKey: Keys.pausedFingerprint)
    }

    /// Huella para decidir si el usuario cambió algo durante la pausa. Deja
    /// fuera las ediciones que sólo guardan el tipo de cambio: las añade la
    /// lectura del correo por su cuenta, no el usuario.
    private func pausedComparisonFingerprint() -> String? {
        guard var snapshot = buildSnapshot() else { return nil }
        snapshot.expenseEdits = snapshot.expenseEdits.filter(\.isUserEdit)
        return Self.fingerprint(of: snapshot)
    }

    /// "Restaurar" desde la pantalla de celular nuevo.
    @discardableResult
    func acceptFoundBackup() async -> String? {
        foundBackup = nil
        UserDefaults.standard.set(true, forKey: Keys.offerDismissed)
        return await restore(code: nil)
    }

    // MARK: - Disparadores automáticos

    /// Tres señales, una sola política: marcar sucio y dejar que el rebote
    /// decida. Cualquier ajuste vive en `UserDefaults` y cualquier movimiento,
    /// atajo o recurrente en SwiftData, así que estas dos notificaciones cubren
    /// todo lo que se respalda sin tener que tocar cada pantalla que guarda.
    private func startWatching() {
        let center = NotificationCenter.default

        // `Task { @MainActor in … }` y NO `MainActor.assumeIsolated`: cuando
        // NotificationCenter entrega el bloque en `OperationQueue.main`, corre
        // en el hilo principal pero **fuera del ejecutor del MainActor**, así
        // que `assumeIsolated` no cumple su comprobación y aborta el proceso.
        // Estar en el hilo principal y estar en el actor principal no son lo
        // mismo. El salto asíncrono es la forma segura de entrar al actor.
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification,
                                            object: UserDefaults.standard, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.markDirty()
            }
        })

        observers.append(center.addObserver(forName: ModelContext.didSave,
                                            object: nil, queue: .main) { [weak self] note in
            // La caché de amigos no va en el respaldo (`SocialCacheSave`).
            guard !SocialCacheSave.isCacheOnly(note) else { return }
            Task { @MainActor in
                self?.markDirty()
            }
        })

        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.flushInBackground()
            }
        })

        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.syncOnForeground()
            }
        })
    }

    /// Un método aparte y no un `Task` dentro del cierre: `assumeIsolated` es
    /// genérico sobre lo que devuelve el bloque, y devolver un `Task` desde ahí
    /// deja su inicializador ambiguo. Los otros tres observadores llaman a un
    /// método igual que éste; conviene que este también lo haga.
    private func syncOnForeground() {
        if isPausedAfterWipe { schedulePausedCheck(); return }
        Task {
            _ = await self.syncIfNeeded()
        }
    }

    // MARK: - En pausa sobre una copia existente

    /// El mismo rebote que `markDirty`: una ráfaga de guardados es una sola
    /// comprobación.
    private func schedulePausedCheck() {
        guard !askedOverwriteThisSession, overwritePrompt == nil else { return }
        pausedCheck?.cancel()
        pausedCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.askToOverwriteIfNeeded()
        }
    }

    /// Lo que haría la sincronización automática si no estuviera en pausa. Si
    /// no cambió nada desde la pausa no hay nada que subir ni que preguntar.
    /// Si la copia de la nube está vacía no hay nada que perder y se reanuda
    /// sin preguntar. Si tiene datos, se pregunta.
    private func askToOverwriteIfNeeded() async {
        guard isPausedAfterWipe, !askedOverwriteThisSession, overwritePrompt == nil,
              foundBackup == nil, !isPresentingLinkFlow,
              UserDefaults.standard.bool(forKey: "hasSeenOnboarding"),
              let current = pausedComparisonFingerprint() else { return }

        // La referencia se toma en la primera comprobación ya en reposo, no
        // en el momento de pausar: entre medias pasan cosas que el usuario no
        // hizo —el borrado de "Empezar de cero", la lectura del correo y el
        // "desde cuándo" del onboarding— y compararlas con eso preguntaría
        // sin motivo nada más terminar.
        let d = UserDefaults.standard
        guard let paused = d.string(forKey: Keys.pausedFingerprint) else {
            d.set(current, forKey: Keys.pausedFingerprint)
            return
        }
        guard current != paused else { return }

        // Sin red no se sabe qué hay en la nube: se vuelve a intentar en la
        // siguiente señal, sin gastar la pregunta de la sesión.
        guard let header = await pausedBackupHeader() else { return }
        guard header.hasData else {
            await resumeAfterWipe(restoreFirst: false)
            return
        }
        askedOverwriteThisSession = true
        overwritePrompt = header
    }

    /// La cabecera de la copia a la que apunta la pausa, para enseñar qué se
    /// perdería. También la usa el botón de Ajustes.
    func pausedBackupHeader() async -> BackupHeader? {
        let d = UserDefaults.standard
        guard let code = Self.code(for: Keys.pausedCode) else { return nil }
        let pausedMode = Mode(rawValue: d.string(forKey: Keys.pausedMode) ?? "") ?? .code
        return await peek(code: pausedMode == .code ? code : nil)
    }

    /// "Ahora no" en la advertencia: sigue en pausa, sin subir nada.
    func postponeOverwrite() {
        overwritePrompt = nil
    }

    /// "Traer la copia" desde la advertencia.
    @discardableResult
    func restoreInsteadOfOverwrite() async -> String? {
        overwritePrompt = nil
        return await resumeAfterWipe(restoreFirst: true)
    }

    /// "Borrar la copia y reemplazarla", ya confirmado dos veces.
    @discardableResult
    func confirmOverwrite() async -> String? {
        overwritePrompt = nil
        return await resumeAfterWipe(restoreFirst: false)
    }

    /// Algo cambió. No sube nada todavía: espera 3 s por si vienen más cambios
    /// (editar un límite dispara varios guardados seguidos) y compara la huella
    /// antes de mandar nada, así que un cambio que no afecta al respaldo —o el
    /// propio `lastSyncedAt` que escribimos nosotros— no gasta una escritura.
    func markDirty() {
        guard isEnabled else {
            if isPausedAfterWipe { schedulePausedCheck() }
            return
        }
        if isSyncing { changedDuringSync = true; return }
        hasPendingChanges = true
        // Sin Pro se anota que hay cambios y nada más: `ProStore` vuelve a
        // llamar aquí al encenderse, y entonces sí se suben.
        guard ProStore.isPro else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // Armar el respaldo lee todo en el hilo principal: nunca a mitad
            // de un deslizamiento (entrar a Movimientos ya cambia un ajuste).
            await ScrollActivity.idle()
            guard !Task.isCancelled else { return }
            _ = await self?.syncIfNeeded()
        }
    }

    /// La app se va a segundo plano: sube ya, sin esperar el rebote, pidiendo
    /// al sistema los segundos que hagan falta para terminar.
    private func flushInBackground() {
        guard isEnabled, hasPendingChanges else { return }
        debounce?.cancel()
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "ConfigBackupSync", expirationHandler: nil)
        Task { [weak self] in
            _ = await self?.syncIfNeeded()
            if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
        }
    }

    // MARK: - Activar

    /// El camino bueno: la cuenta de Google que ya se usa para el correo.
    /// Devuelve `nil` si salió bien, o el motivo si no.
    @discardableResult
    func enableWithAccount() async -> String? {
        // No basta con `isSignedIn`: una sesión guardada cuyo refresh_token ya
        // no sirve pasaría ese filtro y la llamada saldría como anónima, que en
        // PostgREST se ve como un 404 desconcertante. Se exige un token vivo.
        if await BackupAccount.shared.validAccessToken() == nil {
            if let error = await BackupAccount.shared.signInWithGoogle() {
                lastErrorMessage = error
                return error
            }
            if await BackupAccount.shared.validAccessToken() == nil {
                let error = "No se pudo iniciar sesión con Google."
                lastErrorMessage = error
                return error
            }
        }

        // Si ya venía usando un código suelto, la cuenta lo adopta en vez de
        // empezar un respaldo vacío: no se pierde lo subido hasta ahora.
        var body: [String: Any] = [:]
        if let backupCode, mode == .code { body["p_adopt_code"] = backupCode }
        body["p_device_label"] = UIDevice.current.name
        body["p_app_version"] = Self.appVersion ?? NSNull()
        // El correo no se sube: el respaldo ya cuelga del id de la cuenta, y
        // el correo se muestra desde el que está guardado en el teléfono.

        guard let data = await call("ensure_my_backup", body: body, prefix: "No se pudo activar la sincronización") else {
            return lastErrorMessage
        }
        guard let code = Self.decodeScalarString(data) else {
            lastErrorMessage = "Respuesta inesperada al activar la sincronización."
            return lastErrorMessage
        }

        // La cuenta ya tenía una copia con datos (de otro celular, o de este
        // antes de reinstalar) y no se está adoptando un código propio:
        // encender aquí subiría este celular encima y la borraría sin
        // preguntar. Queda en pausa sobre ella, y Ajustes ofrece traerla o
        // reemplazarla con la advertencia de `OverwriteBackupSheet`.
        if body["p_adopt_code"] == nil,
           let header = await peek(code: nil), header.hasData, header.backupCode == code {
            keepRemotePaused(header)
            lastErrorMessage = nil
            return "Tu cuenta ya tiene una copia de seguridad. Elige si traerla a este celular o reemplazarla."
        }

        backupCode = code
        mode = .account
        persistMode()
        _ = await sync(force: true)
        return nil
    }

    /// Para quien no quiere iniciar sesión. Devuelve el código, que el usuario
    /// tiene que guardar: es la única llave de ese respaldo.
    @discardableResult
    func enableWithCode() async -> String? {
        if let backupCode, mode != .off { return backupCode }
        guard let data = await call("generate_backup_code", body: [:], prefix: "No se pudo activar la sincronización"),
              let code = Self.decodeScalarString(data) else { return nil }

        backupCode = code
        mode = .code
        persistMode()
        _ = await sync(force: true)
        return code
    }

    /// Apaga la sincronización. `deleteRemote` borra además lo ya subido.
    func disable(deleteRemote: Bool) async {
        if deleteRemote {
            _ = await call("delete_config_backup", body: codeBody(), prefix: "No se pudo borrar el respaldo")
        }
        debounce?.cancel()
        mode = .off
        backupCode = nil
        lastSyncedAt = nil
        hasPendingChanges = false
        UserDefaults.standard.removeObject(forKey: Keys.fingerprint)
        persistMode()
    }

    // MARK: - Empezar de cero

    /// "Borrar datos → Empezar de cero" deja el teléfono vacío. Si la
    /// sincronización siguiera encendida, el siguiente rebote subiría ese vacío
    /// y se llevaría por delante la copia en la nube — justo lo contrario de
    /// para lo que existe. Así que se pausa y se guarda a un lado a qué
    /// respaldo apuntaba, para poder reanudarla con un toque.
    func pauseAfterLocalWipe() {
        guard isEnabled else { return }
        debounce?.cancel()
        let d = UserDefaults.standard
        d.set(mode.rawValue, forKey: Keys.pausedMode)
        Self.setCode(backupCode, for: Keys.pausedCode)
        d.removeObject(forKey: Keys.pausedFingerprint)
        mode = .off
        backupCode = nil
        hasPendingChanges = false
        d.removeObject(forKey: Keys.fingerprint)
        persistMode()
    }

    /// Reanuda lo pausado. `restoreFirst` trae la copia de la nube a este
    /// teléfono; sin él, se sube lo que hay ahora y la copia anterior se
    /// reemplaza.
    @discardableResult
    func resumeAfterWipe(restoreFirst: Bool) async -> String? {
        let d = UserDefaults.standard
        guard let code = Self.code(for: Keys.pausedCode) else { return "No hay nada pausado." }
        let pausedMode = Mode(rawValue: d.string(forKey: Keys.pausedMode) ?? "") ?? .code

        if restoreFirst {
            if let error = await restore(code: pausedMode == .code ? code : nil) { return error }
        } else {
            backupCode = code
            mode = pausedMode
            persistMode()
            _ = await sync(force: true)
        }
        Self.setCode(nil, for: Keys.pausedCode)
        d.removeObject(forKey: Keys.pausedMode)
        d.removeObject(forKey: Keys.pausedFingerprint)
        return lastErrorMessage
    }

    // MARK: - Sincronizar

    /// Sube sólo si de verdad cambió algo respecto a lo último subido.
    @discardableResult
    func syncIfNeeded() async -> Bool {
        await sync(force: false)
    }

    /// El botón "Sincronizar ahora": sube aunque la huella no haya cambiado.
    @discardableResult
    func syncNow() async -> Bool {
        await sync(force: true)
    }

    @discardableResult
    private func sync(force: Bool) async -> Bool {
        guard isEnabled, backupCode != nil, !isSyncing, ProStore.isPro else { return false }
        guard let snapshot = buildSnapshot() else { return false }

        let fingerprint = Self.fingerprint(of: snapshot)
        if !force, fingerprint == UserDefaults.standard.string(forKey: Keys.fingerprint) {
            hasPendingChanges = false
            lastErrorMessage = nil
            return true
        }

        isSyncing = true
        changedDuringSync = false
        defer {
            isSyncing = false
            if changedDuringSync { changedDuringSync = false; markDirty() }
        }

        var body = snapshot.rpcBody
        body.merge(codeBody()) { current, _ in current }
        body["p_app_version"] = Self.appVersion ?? NSNull()
        body["p_device_label"] = UIDevice.current.name

        guard await call("write_config_backup", body: body, prefix: "No se pudo sincronizar") != nil else {
            return false
        }

        UserDefaults.standard.set(fingerprint, forKey: Keys.fingerprint)
        lastSyncedAt = Date()
        UserDefaults.standard.set(lastSyncedAt, forKey: Keys.lastSyncedAt)
        hasPendingChanges = false
        lastErrorMessage = nil
        return true
    }

    // MARK: - Restaurar

    /// Trae el respaldo y lo aplica entero. `code == nil` usa la cuenta.
    /// Devuelve `nil` si salió bien, o el motivo del fallo.
    @discardableResult
    func restore(code: String?) async -> String? {
        var body: [String: Any] = [:]
        if let code, !code.isEmpty {
            body["p_code"] = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        } else if await BackupAccount.shared.validAccessToken() == nil {
            if let error = await BackupAccount.shared.signInWithGoogle() {
                lastErrorMessage = error
                return error
            }
            if await BackupAccount.shared.validAccessToken() == nil {
                let error = "No se pudo iniciar sesión con Google."
                lastErrorMessage = error
                return error
            }
        }

        guard let data = await call("read_config_backup", body: body, prefix: "No se pudo leer el respaldo") else {
            return lastErrorMessage
        }

        let payload: ConfigBackupPayload
        do {
            payload = try Self.makeDecoder().decode(ConfigBackupPayload.self, from: data)
        } catch {
            lastErrorMessage = "El respaldo llegó en un formato que esta versión no entiende: \(error)"
            return lastErrorMessage
        }

        apply(payload)

        backupCode = payload.backupCode ?? body["p_code"] as? String ?? backupCode
        mode = (body["p_code"] == nil) ? .account : .code
        persistMode()
        lastSyncedAt = Date()
        UserDefaults.standard.set(lastSyncedAt, forKey: Keys.lastSyncedAt)
        // La huella se recalcula sola en la próxima señal; no se fija aquí para
        // que cualquier diferencia local se suba enseguida.
        UserDefaults.standard.removeObject(forKey: Keys.fingerprint)
        lastErrorMessage = nil
        return nil
    }

    /// Sólo la cabecera: para poder decir "hay un respaldo del 3 de marzo"
    /// antes de sobrescribir nada.
    func peek(code: String?) async -> BackupHeader? {
        var body: [String: Any] = [:]
        if let code, !code.isEmpty {
            body["p_code"] = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard let data = await call("peek_config_backup", body: body, prefix: "No se pudo leer el respaldo") else {
            return nil
        }
        return try? Self.makeDecoder().decode(BackupHeader.self, from: data)
    }

    // MARK: - Red

    private func codeBody() -> [String: Any] {
        // Con cuenta no se manda el código: el servidor resuelve por `auth.uid()`,
        // así el respaldo sigue siendo suyo aunque el código se filtre.
        guard mode == .code, let backupCode else { return [:] }
        return ["p_code": backupCode]
    }

    @discardableResult
    private func call(_ function: String, body: [String: Any], prefix: String) async -> Data? {
        guard let url = URL(string: "\(projectURL)/rest/v1/rpc/\(function)") else {
            lastErrorMessage = "\(prefix): URL inválida."
            return nil
        }
        // El error anterior se borra al empezar el intento, no al terminarlo:
        // si no, la pantalla sigue mostrando en rojo un fallo de hace tres
        // intentos y parece que nada de lo que haces sirve.
        lastErrorMessage = nil

        // Se pregunta antes de mandar: un 404 significa cosas muy distintas
        // según se llame con sesión o como anónimo.
        let signedIn = await BackupAccount.shared.validAccessToken() != nil
        var request = await BackupAccount.shared.authorizedRequest(url: url)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                lastErrorMessage = Self.describe(prefix, function: function,
                                                 status: status, data: data, signedIn: signedIn)
                return nil
            }
            return data
        } catch {
            lastErrorMessage = "\(prefix): \(error.localizedDescription)"
            return nil
        }
    }

    /// El motivo real, no un "no se pudo" genérico: sin esto es imposible
    /// distinguir "falta correr el SQL" de "el código no existe".
    private static func describe(_ prefix: String, function: String, status: Int,
                                data: Data, signedIn: Bool) -> String {
        var body = String(data: data, encoding: .utf8) ?? ""
        if body.count > 240 { body = String(body.prefix(240)) + "…" }
        if status == 404 {
            // PostgREST manda en `details` los parámetros con los que buscó y en
            // `hint` la firma que sí existe: sin eso, un 404 puede ser caché,
            // permisos o un nombre de parámetro que no coincide, y no hay forma
            // de distinguirlos desde el teléfono.
            let detail = Self.field("details", in: data) ?? ""
            let hint = Self.field("hint", in: data) ?? ""
            var text = "\(prefix): Supabase no encuentra «\(function)»"
            text += signedIn ? " (con sesión iniciada)." : " (la app llamó sin sesión)."
            if !detail.isEmpty { text += "\n\nBuscó: \(detail)" }
            if !hint.isEmpty { text += "\n\nPista: \(hint)" }
            if detail.isEmpty, hint.isEmpty { text += "\n\n\(body)" }
            return text
        }
        if status == 401 || status == 403 {
            return "\(prefix): la sesión no vale. Vuelve a conectar tu cuenta de Google."
        }
        return body.isEmpty ? "\(prefix) (HTTP \(status))." : "\(prefix) (HTTP \(status)): \(body)"
    }

    /// Un campo suelto del JSON de error de PostgREST.
    nonisolated private static func field(_ name: String, in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let value = json[name] as? String
        return (value?.isEmpty == false) ? value : nil
    }

    private func persistMode() {
        UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode)
        Self.setCode(backupCode, for: Keys.backupCode)
    }

    // MARK: - Código en el Llavero

    /// El código de respaldo es una llave: quien lo tenga lee y pisa la copia.
    private static var codeStore: SecureStore { .backupCode }

    /// Del Llavero; si una versión anterior lo dejó en `UserDefaults`, se muda.
    private static func code(for key: String) -> String? {
        let d = UserDefaults.standard
        if let legacy = d.string(forKey: key) {
            codeStore.write(legacy, for: key)
            d.removeObject(forKey: key)
        }
        return codeStore.read(key)
    }

    private static func setCode(_ value: String?, for key: String) {
        UserDefaults.standard.removeObject(forKey: key)
        codeStore.write(value, for: key)
    }

    private static var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private static func decodeScalarString(_ data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(String.self, from: data), !decoded.isEmpty { return decoded }
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"\n "))
        return (raw?.isEmpty == false) ? raw : nil
    }

    // MARK: - Qué se va a guardar

    /// Cuenta lo que la sincronización subiría ahora mismo, a partir de la
    /// misma fotografía que se sube: así el número que ve el usuario no puede
    /// desviarse de lo que de verdad viaja.
    func localSummary() -> BackupSummary {
        guard let snapshot = buildSnapshot() else { return BackupSummary() }
        return BackupSummary(
            rules: snapshot.merchantRules.count,
            categories: snapshot.categoryCatalog.count,
            limits: snapshot.categoryBudgets.count,
            shortcuts: snapshot.quickExpenses.count,
            recurring: snapshot.recurringExpenses.count,
            expenseEdits: snapshot.expenseEdits.filter(\.isUserEdit).count,
            manualExpenses: snapshot.manualTransactions.filter { $0.kind == "expense" }.count,
            manualIncomes: snapshot.manualTransactions.filter { $0.kind == "income" }.count)
    }

    // MARK: - Respaldo en archivo

    /// «Guardar un respaldo» (Datos y respaldo, `4l`): lo mismo que se sube a
    /// la nube, pero en un archivo que el usuario guarda donde quiera. No
    /// necesita cuenta ni Pro.
    func fileBackupData() -> Data? {
        guard let s = buildSnapshot() else { return nil }
        let payload = ConfigBackupPayload(
            backupCode: nil, updatedAt: Date(), accountEmail: nil,
            merchantRules: s.merchantRules, categoryCatalog: s.categoryCatalog,
            categoryBudgets: s.categoryBudgets, budgetSettings: s.budgetSettings,
            bankSources: s.bankSources, notificationSettings: s.notificationSettings,
            appearance: s.appearance, preferences: s.preferences,
            quickExpenses: s.quickExpenses, recurringExpenses: s.recurringExpenses,
            expenseEdits: s.expenseEdits, manualTransactions: s.manualTransactions)
        let encoder = Self.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(payload)
    }

    /// «Restaurar desde archivo». Devuelve `nil` si salió bien, o el motivo.
    func restoreFromFile(_ data: Data) -> String? {
        do {
            let payload = try Self.makeDecoder().decode(ConfigBackupPayload.self, from: data)
            apply(payload)
            return nil
        } catch {
            return "Ese archivo no es un respaldo de AgruPay, o es de una versión que ésta no entiende."
        }
    }

    // MARK: - Fotografía del dispositivo

    private func buildSnapshot() -> ConfigSnapshot? {
        guard let context = container?.mainContext else { return nil }

        let quick = (try? context.fetch(FetchDescriptor<QuickExpense>())) ?? []
        let recurring = (try? context.fetch(FetchDescriptor<RecurringExpense>())) ?? []
        // Sólo lo anotado a mano: es lo único que se sube de los movimientos.
        // Leer el historial entero para descartar casi todo eran ~200 ms del
        // hilo principal en cada respaldo (y cualquier ajuste lo dispara).
        let expenses = (try? context.fetch(FetchDescriptor<Expense>(predicate: #Predicate { $0.emailID == nil }))) ?? []
        let incomes = (try? context.fetch(FetchDescriptor<Income>(predicate: #Predicate { $0.emailID == nil }))) ?? []

        var manual: [ManualTransactionBackup] = []

        for e in expenses {
            if e.emailID == nil {
                // Sin correo detrás: si no se sube, se pierde entero.
                manual.append(ManualTransactionBackup(
                    id: e.id, kind: "expense", amount: e.amount, currency: e.currency,
                    title: e.merchant, subtitle: nil, category: e.category,
                    occurredAt: e.date, notes: e.notes,
                    isSubscription: e.isSubscription, isDebt: e.isDebt,
                    debtSettled: e.debtSettled ? true : nil,
                    tags: e.tags.isEmpty ? nil : e.tags,
                    cardLastDigits: e.cardLastDigits, source: e.sourceBank, fxRate: e.fxRateAtCapture,
                    debtMarkKey: nil, isFinalDebtPayment: false, createdAt: e.date,
                    splitOf: e.splitOf, splitIndex: e.splitOf == nil ? nil : e.splitIndex))
            }
            // Los gastos que vienen del correo no se suben: lo que viaja de
            // ellos son las ediciones que el usuario hizo, y eso lo lleva
            // `ExpenseEditStore` — registrado al editar, no deducido después.
        }

        for i in incomes {
            // Igual que los gastos: si viene de un correo (ej. un Yapeo
            // recibido), se reconstruye solo releyendo Gmail y no hace falta
            // subirlo — sólo los ingresos anotados a mano viajan aquí.
            if i.emailID != nil { continue }
            manual.append(ManualTransactionBackup(
                id: i.id, kind: "income", amount: i.amount, currency: i.currency,
                title: i.source, subtitle: i.title, category: "Otros",
                occurredAt: i.date, notes: i.notes,
                isSubscription: false, isDebt: false,
                cardLastDigits: nil, fxRate: i.fxRateAtCapture,
                // Si la relación está rota —el gasto se borró en una relectura—
                // el vínculo persistido sigue sabiendo a qué gasto abonaba.
                debtMarkKey: i.debtReference.map { TransactionKey.key(for: $0) }
                    ?? IncomeLinkStore.markKey(for: i.id),
                isFinalDebtPayment: i.isFinalDebtPayment ?? false,
                createdAt: i.date))
        }

        return ConfigSnapshot(
            merchantRules: MerchantRules.all(),
            categoryCatalog: Array(CategoryCatalog.shared.entries.values).sorted { $0.name < $1.name },
            categoryBudgets: Array(CategoryBudgetStore.shared.budgets.values).sorted { $0.category < $1.category },
            budgetSettings: Self.currentBudgetSettings(),
            bankSources: Self.currentBankSources(),
            notificationSettings: Self.currentNotificationSettings(),
            appearance: Self.currentAppearance(),
            preferences: AppPreferences.snapshot().merging(Self.decisionExtras()) { _, extra in extra },
            quickExpenses: quick.map(Self.backup(from:)).sorted { $0.sortIndex < $1.sortIndex },
            recurringExpenses: recurring.map(Self.backup(from:)).sorted { $0.id.uuidString < $1.id.uuidString },
            expenseEdits: ExpenseEditStore.list(),
            manualTransactions: manual.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    /// Huella de lo que se subiría. Todo va ordenado para que dos fotografías
    /// iguales den la misma cadena aunque los diccionarios cambien de orden.
    private static func fingerprint(of snapshot: ConfigSnapshot) -> String {
        let encoder = makeEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return UUID().uuidString }
        // SHA256 y no `hashValue`: el hash de Swift lleva una semilla distinta
        // en cada arranque, así que compararlo entre sesiones subiría siempre.
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Aplicar lo restaurado

    private func apply(_ payload: ConfigBackupPayload) {
        Self.applySettings(payload)
        guard let context = container?.mainContext else { return }

        let quick = (try? context.fetch(FetchDescriptor<QuickExpense>())) ?? []
        let recurring = (try? context.fetch(FetchDescriptor<RecurringExpense>())) ?? []
        Self.applyQuickExpenses(payload.quickExpenses, existing: quick, modelContext: context)
        Self.applyRecurringExpenses(payload.recurringExpenses, existing: recurring, modelContext: context)
        Self.applyManualTransactions(payload, modelContext: context)
        Self.applyExpenseEdits(payload, modelContext: context)

        try? context.save()
    }

    /// Todo lo que vive en `UserDefaults` / los stores singleton.
    static func applySettings(_ payload: ConfigBackupPayload) {
        let defaults = UserDefaults.standard

        defaults.set(payload.merchantRules, forKey: MerchantRules.key)

        for category in payload.categoryCatalog { CategoryCatalog.shared.save(category) }
        for budget in payload.categoryBudgets { CategoryBudgetStore.shared.save(budget) }

        defaults.set(payload.budgetSettings.monthlyBudget, forKey: BudgetStore.monthlyBudgetKey)
        defaults.set(payload.budgetSettings.enabled, forKey: BudgetStore.enabledKey)
        defaults.set(payload.budgetSettings.tracksIncome, forKey: BudgetStore.tracksIncomeKey)

        for bank in BankSource.all {
            if let enabled = payload.bankSources[bank.id] {
                defaults.set(enabled, forKey: bank.storageKey)
            }
        }

        defaults.set(payload.notificationSettings.budgetEnabled, forKey: NotificationSettings.budgetKey)
        defaults.set(payload.notificationSettings.remindRecurring, forKey: NotificationSettings.recurringKey)
        defaults.set(payload.notificationSettings.debtReminderEnabled, forKey: NotificationSettings.debtEnabledKey)
        defaults.set(payload.notificationSettings.debtReminderHour, forKey: NotificationSettings.debtHourKey)
        defaults.set(payload.notificationSettings.debtReminderMinute, forKey: NotificationSettings.debtMinuteKey)
        defaults.set(payload.notificationSettings.categoryLimitAlerts, forKey: NotificationManager.categoryLimitEnabledKey)

        defaults.set(payload.appearance.appearance, forKey: AppAppearance.storageKey)
        defaults.set(payload.appearance.accentColor, forKey: "appAccentColor")
        defaults.set(payload.appearance.textSize, forKey: AppTextSize.storageKey)

        // Al final y por encima de todo lo anterior: el blob cubre esas mismas
        // claves y algunas más, y es el que manda cuando ambos las traen.
        if let preferences = payload.preferences {
            AppPreferences.apply(preferences)
            applyDecisionExtras(preferences)
            // «Tus cuentas» acaba de escribirse en `UserDefaults`; el detector
            // de traslados corre al volver a abrir la app (`ContentView`).
            AccountBook.shared.reload()
        }

        // Amigos: el apodo, el color y lo que le comparto a cada uno acaban de
        // entrar en `UserDefaults`, pero el store ya tenía cargado en memoria
        // lo del teléfono anterior a la restauración.
        SocialProfileStore.shared.reloadFromDefaults()
    }

    /// Upsert por `id`: lo que ya existe se actualiza, lo nuevo se inserta, lo
    /// que ya no está en el respaldo se borra.
    static func applyQuickExpenses(_ backups: [QuickExpenseBackup],
                                   existing: [QuickExpense],
                                   modelContext: ModelContext) {
        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var keepIDs = Set<UUID>()
        for b in backups {
            keepIDs.insert(b.id)
            if let e = existingByID[b.id] {
                e.label = b.label
                e.merchant = b.merchant
                e.category = b.category
                e.amount = b.amount
                e.currency = b.currency
                e.iconName = b.iconName
                e.sortIndex = b.sortIndex
                e.useCount = b.useCount
                e.lastUsedAt = b.lastUsedAt
            } else {
                let e = QuickExpense(label: b.label, merchant: b.merchant, category: b.category,
                                     amount: b.amount, currency: b.currency, iconName: b.iconName,
                                     sortIndex: b.sortIndex)
                e.id = b.id
                e.useCount = b.useCount
                e.lastUsedAt = b.lastUsedAt
                modelContext.insert(e)
            }
        }
        for e in existing where !keepIDs.contains(e.id) { modelContext.delete(e) }
    }

    static func applyRecurringExpenses(_ backups: [RecurringExpenseBackup],
                                       existing: [RecurringExpense],
                                       modelContext: ModelContext) {
        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var keepIDs = Set<UUID>()
        for b in backups {
            keepIDs.insert(b.id)
            if let e = existingByID[b.id] {
                e.merchant = b.merchant
                e.category = b.category
                e.amount = b.amount
                e.currency = b.currency
                e.frequencyRaw = b.frequency
                e.dayOfMonth = b.dayOfMonth
                e.weekdays = b.weekdays
                e.autoConfirm = b.autoConfirm
                e.isPaused = b.isPaused
                e.startDate = b.startDate
                e.endDate = b.endDate
                e.lastResolvedOccurrence = b.lastResolvedOccurrence
            } else {
                let e = RecurringExpense(merchant: b.merchant, category: b.category, amount: b.amount,
                                         currency: b.currency,
                                         frequency: RecurrenceFrequency(rawValue: b.frequency) ?? .monthly,
                                         dayOfMonth: b.dayOfMonth, weekdays: b.weekdays,
                                         autoConfirm: b.autoConfirm, startDate: b.startDate, endDate: b.endDate)
                e.id = b.id
                e.isPaused = b.isPaused
                e.lastResolvedOccurrence = b.lastResolvedOccurrence
                e.createdAt = b.createdAt
                modelContext.insert(e)
            }
        }
        for e in existing where !keepIDs.contains(e.id) { modelContext.delete(e) }
    }

    /// Movimientos creados a mano. Aquí **no** se borra lo que no está en el
    /// respaldo: restaurar no puede llevarse por delante un gasto que el
    /// usuario acaba de anotar en este teléfono.
    static func applyManualTransactions(_ payload: ConfigBackupPayload, modelContext: ModelContext) {
        let expenses = (try? modelContext.fetch(FetchDescriptor<Expense>())) ?? []
        let incomes = (try? modelContext.fetch(FetchDescriptor<Income>())) ?? []
        let existingExpenseIDs = Set(expenses.map(\.id))
        let existingIncomeIDs = Set(incomes.map(\.id))

        var byKey = TransactionKey.expensesByLookupKey(expenses)

        for t in payload.manualTransactions where t.kind == "expense" {
            guard !existingExpenseIDs.contains(t.id) else { continue }
            let e = Expense(amount: t.amount, merchant: t.title, date: t.occurredAt,
                            category: t.category, notes: t.notes,
                            isSubscription: t.isSubscription, currency: t.currency,
                            emailID: nil, isDebt: t.isDebt,
                            cardLastDigits: t.cardLastDigits, fxRateAtCapture: t.fxRate)
            e.id = t.id
            e.sourceBank = t.source
            e.debtSettled = t.debtSettled ?? false
            // El catálogo se restaura antes (viaja en `preferences`), pero se
            // pasa por `use` igual: un respaldo de otro teléfono puede traer
            // una etiqueta que aquí todavía no existía.
            e.tags = (t.tags ?? []).compactMap { TagCatalog.shared.use($0) }
            e.splitOf = t.splitOf
            e.splitIndex = t.splitIndex ?? 0
            modelContext.insert(e)
            byKey[TransactionKey.key(for: e)] = e
        }

        var links: [IncomeLink] = []
        for t in payload.manualTransactions where t.kind == "income" {
            // El vínculo se guarda siempre, exista o no el gasto ahora mismo:
            // al restaurar en un teléfono nuevo los gastos del correo todavía
            // no se han leído, y sin esto el cobro quedaría suelto para siempre.
            if let markKey = t.debtMarkKey {
                links.append(IncomeLink(incomeID: t.id, markKey: markKey,
                                        isFinal: t.isFinalDebtPayment))
            }
            guard !existingIncomeIDs.contains(t.id) else { continue }
            let i = Income(amount: t.amount, currency: t.currency, source: t.title,
                           title: t.subtitle, date: t.occurredAt, notes: t.notes,
                           debtReference: t.debtMarkKey.flatMap { byKey[$0] },
                           isFinalDebtPayment: t.isFinalDebtPayment,
                           fxRateAtCapture: t.fxRate)
            i.id = t.id
            modelContext.insert(i)
        }
        IncomeLinkStore.merge(links)
    }

    /// Las ediciones que el usuario hizo sobre gastos del correo. Se funden
    /// con las locales —restaurar no puede borrar lo que se editó en este
    /// teléfono— y se aplican sobre los gastos que ya existan.
    ///
    /// Los que todavía no se han releído del correo no se pierden: el registro
    /// queda guardado y `ExpenseEditStore.apply` los alcanza al terminar la
    /// siguiente lectura de Gmail. Restaurar suele pasar en un teléfono vacío,
    /// donde ninguno de esos gastos existe aún.
    static func applyExpenseEdits(_ payload: ConfigBackupPayload, modelContext: ModelContext) {
        ExpenseEditStore.merge(payload.expenseEdits ?? [])
        ExpenseEditStore.apply(in: modelContext)
        IncomeLinkStore.apply(in: modelContext)
        ExpenseSplit.reconcile(in: modelContext)
    }

    /// La llama `GmailSyncService` al terminar cada lectura, que es cuando los
    /// gastos acaban de rearmarse. `nonisolated` porque se invoca desde el
    /// cierre de su cola, fuera del actor principal; no toca estado de la clase.
    nonisolated static func reapplyPendingDecisions(modelContext: ModelContext) {
        ExpenseEditStore.captureFxRates(in: modelContext)
        ExpenseEditStore.apply(in: modelContext)
        IncomeLinkStore.apply(in: modelContext)
        // Después de `apply`: una edición puede haber cambiado la llave de
        // un pago, y las partes lo buscan por ella.
        ExpenseSplit.reconcile(in: modelContext)
    }

    // MARK: - Decisiones que viajan en el blob de preferencias

    /// Dos decisiones del usuario que no son ajustes pero tampoco están en
    /// ningún correo, y que antes se perdían al reinstalar:
    /// - `incomeDebtLinks`: qué cobro del correo (un Yapeo recibido) saldó qué
    ///   deuda. Los anotados a mano ya llevan su `debtMarkKey`; éstos no.
    /// - `pendingRecoveryIDs`: los gastos del correo que el usuario borró. Sin
    ///   esto, releer Gmail en el teléfono nuevo los resucitaba todos.
    ///
    /// Viajan como texto JSON dentro de `preferences` para no tocar el esquema,
    /// y al restaurar se **funden** con lo local en vez de sustituirlo.
    private enum ExtraKeys {
        static let incomeLinks = "backup.incomeDebtLinks"
        static let deletedEmails = "backup.deletedEmailIDs"
    }

    private static func decisionExtras() -> [String: AnyCodableValue] {
        var result: [String: AnyCodableValue] = [:]
        let links = IncomeLinkStore.all().values.sorted { $0.incomeID.uuidString < $1.incomeID.uuidString }
        if !links.isEmpty, let data = try? JSONEncoder().encode(links), let text = String(data: data, encoding: .utf8) {
            result[ExtraKeys.incomeLinks] = .string(text)
        }
        let deleted = (UserDefaults.standard.stringArray(forKey: "pendingRecoveryIDs") ?? []).sorted()
        if !deleted.isEmpty, let data = try? JSONEncoder().encode(deleted), let text = String(data: data, encoding: .utf8) {
            result[ExtraKeys.deletedEmails] = .string(text)
        }
        return result
    }

    private static func applyDecisionExtras(_ preferences: [String: AnyCodableValue]) {
        if case .string(let text)? = preferences[ExtraKeys.incomeLinks],
           let links = try? JSONDecoder().decode([IncomeLink].self, from: Data(text.utf8)) {
            IncomeLinkStore.merge(links)
        }
        if case .string(let text)? = preferences[ExtraKeys.deletedEmails],
           let incoming = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) {
            let defaults = UserDefaults.standard
            let local = defaults.stringArray(forKey: "pendingRecoveryIDs") ?? []
            defaults.set(Array(Set(local).union(incoming)).sorted(), forKey: "pendingRecoveryIDs")
        }
    }

    // MARK: - Estado actual del dispositivo

    private static func currentBudgetSettings() -> BudgetSettingsBackup {
        let defaults = UserDefaults.standard
        return BudgetSettingsBackup(
            monthlyBudget: defaults.object(forKey: BudgetStore.monthlyBudgetKey) as? Double ?? 0,
            enabled: defaults.object(forKey: BudgetStore.enabledKey) as? Bool ?? true,
            tracksIncome: defaults.object(forKey: BudgetStore.tracksIncomeKey) as? Bool ?? true)
    }

    private static func currentBankSources() -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: BankSource.all.map { ($0.id, $0.isEnabled) })
    }

    private static func currentNotificationSettings() -> NotificationSettingsBackup {
        let defaults = UserDefaults.standard
        return NotificationSettingsBackup(
            budgetEnabled: defaults.object(forKey: NotificationSettings.budgetKey) as? Bool ?? true,
            remindRecurring: defaults.object(forKey: NotificationSettings.recurringKey) as? Bool ?? true,
            debtReminderEnabled: defaults.object(forKey: NotificationSettings.debtEnabledKey) as? Bool ?? true,
            debtReminderHour: defaults.object(forKey: NotificationSettings.debtHourKey) as? Int ?? 10,
            debtReminderMinute: defaults.object(forKey: NotificationSettings.debtMinuteKey) as? Int ?? 0,
            categoryLimitAlerts: defaults.object(forKey: NotificationManager.categoryLimitEnabledKey) as? Bool ?? true)
    }

    private static func currentAppearance() -> AppearanceBackup {
        let defaults = UserDefaults.standard
        return AppearanceBackup(
            appearance: defaults.string(forKey: AppAppearance.storageKey) ?? AppAppearance.dark.rawValue,
            accentColor: defaults.string(forKey: "appAccentColor") ?? AppThemeColor.blue.rawValue,
            textSize: defaults.string(forKey: AppTextSize.storageKey) ?? AppTextSize.sistema.rawValue)
    }

    private static func backup(from expense: QuickExpense) -> QuickExpenseBackup {
        QuickExpenseBackup(id: expense.id, label: expense.label, merchant: expense.merchant,
                           category: expense.category, amount: expense.amount, currency: expense.currency,
                           iconName: expense.iconName, sortIndex: expense.sortIndex,
                           useCount: expense.useCount, lastUsedAt: expense.lastUsedAt)
    }

    private static func backup(from expense: RecurringExpense) -> RecurringExpenseBackup {
        RecurringExpenseBackup(id: expense.id, merchant: expense.merchant, category: expense.category,
                               amount: expense.amount, currency: expense.currency,
                               frequency: expense.frequencyRaw, dayOfMonth: expense.dayOfMonth,
                               weekdays: expense.weekdays, autoConfirm: expense.autoConfirm,
                               isPaused: expense.isPaused, startDate: expense.startDate,
                               endDate: expense.endDate, lastResolvedOccurrence: expense.lastResolvedOccurrence,
                               createdAt: expense.createdAt)
    }

    // MARK: - Fechas (Postgres devuelve timestamptz con microsegundos)

    // `nonisolated(unsafe)`: `ISO8601DateFormatter` no es Sendable, pero estas
    // dos instancias sólo se leen —nunca se reconfiguran tras crearse— y
    // formatear es seguro en paralelo. Sin `(unsafe)` es error en Swift 6.
    nonisolated(unsafe) private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Postgres devuelve `timestamptz` con **microsegundos**
    /// (`2026-03-01T12:00:00.123456+00:00`) y `ISO8601DateFormatter` sólo
    /// admite hasta milésimas: sin recortar la fracción, todo el respaldo falla
    /// al decodificarse con un "Fecha inválida" difícil de rastrear.
    nonisolated static func parseDate(_ text: String) -> Date? {
        if let date = isoWithFraction.date(from: text) { return date }
        if let date = isoPlain.date(from: text) { return date }
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let fraction = text[text.index(after: dot)..<end]
            if fraction.count > 3 {
                let trimmed = text[..<dot] + "." + fraction.prefix(3) + text[end...]
                if let date = isoWithFraction.date(from: String(trimmed)) { return date }
            }
            let withoutFraction = String(text[..<dot] + text[end...])
            if let date = isoPlain.date(from: withoutFraction) { return date }
        }
        return TransactionKey.dayFormatter.date(from: text)
    }

    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = parseDate(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Fecha inválida: \(text)")
        }
        return decoder
    }

    nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoWithFraction.string(from: date))
        }
        return encoder
    }
}

// MARK: - Formas que viajan

struct QuickExpenseBackup: Codable {
    var id: UUID
    var label: String
    var merchant: String
    var category: String
    @MoneyCoded var amount: Double
    var currency: String
    var iconName: String
    var sortIndex: Int
    var useCount: Int
    var lastUsedAt: Date?
}

struct RecurringExpenseBackup: Codable {
    var id: UUID
    var merchant: String
    var category: String
    @MoneyCoded var amount: Double
    var currency: String
    var frequency: String
    var dayOfMonth: Int
    var weekdays: [Int]
    var autoConfirm: Bool
    var isPaused: Bool
    var startDate: Date
    var endDate: Date?
    var lastResolvedOccurrence: Date?
    var createdAt: Date
}

struct BudgetSettingsBackup: Codable {
    @MoneyCoded var monthlyBudget: Double
    var enabled: Bool
    var tracksIncome: Bool
}

struct NotificationSettingsBackup: Codable {
    var budgetEnabled: Bool
    var remindRecurring: Bool
    var debtReminderEnabled: Bool
    var debtReminderHour: Int
    var debtReminderMinute: Int
    var categoryLimitAlerts: Bool
}

struct AppearanceBackup: Codable {
    var appearance: String
    var accentColor: String
    var textSize: String
}



/// Un gasto o ingreso escrito a mano: no hay correo del que rearmarlo.
struct ManualTransactionBackup: Codable {
    var id: UUID
    var kind: String            // "expense" | "income"
    @MoneyCoded var amount: Double
    var currency: String
    var title: String           // gasto: comercio · ingreso: origen
    var subtitle: String?       // ingreso: título ("Sueldo")
    var category: String
    var occurredAt: Date
    var notes: String?
    var isSubscription: Bool
    var isDebt: Bool
    /// Opcional: los respaldos anteriores no lo traen.
    var debtSettled: Bool? = nil
    /// Las etiquetas del gasto. Opcional por lo mismo. En los ingresos no
    /// aplica: las etiquetas son de gastos.
    var tags: [String]? = nil
    var cardLastDigits: String?
    /// Gasto: la fuente elegida al anotarlo (Efectivo, Yape…). Opcional: los
    /// respaldos anteriores no la traen.
    var source: String? = nil
    @RateCoded var fxRate: Double?
    var debtMarkKey: String?
    var isFinalDebtPayment: Bool
    var createdAt: Date
    /// Gasto: parte de un pago dividido, con la llave de ese pago
    /// (`ExpenseSplit`). Opcional: los respaldos anteriores no lo traen.
    var splitOf: String? = nil
    var splitIndex: Int? = nil
}

/// Lo que se sube. Es también lo que se resume en la huella.
struct ConfigSnapshot: Codable {
    var merchantRules: [String: String]
    var categoryCatalog: [CustomCategory]
    var categoryBudgets: [CategoryBudget]
    var budgetSettings: BudgetSettingsBackup
    var bankSources: [String: Bool]
    var notificationSettings: NotificationSettingsBackup
    var appearance: AppearanceBackup
    /// Todas las preferencias de `UserDefaults` en un solo sitio: añadir una
    /// no exige tocar el esquema (ver `AppPreferences`).
    var preferences: [String: AnyCodableValue]
    var quickExpenses: [QuickExpenseBackup]
    var recurringExpenses: [RecurringExpenseBackup]
    var expenseEdits: [ExpenseEdit]
    var manualTransactions: [ManualTransactionBackup]

    /// Cuerpo del RPC. Cada bloque se manda como JSON ya serializado para que
    /// Postgres lo reciba como `jsonb` sin que haya que describir aquí cada
    /// campo dos veces.
    var rpcBody: [String: Any] {
        let encoder = ConfigBackupManager.makeEncoder()
        func json(_ value: some Encodable) -> Any {
            guard let data = try? encoder.encode(value),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { return NSNull() }
            return object
        }
        return [
            "p_merchant_rules": merchantRules,
            "p_category_catalog": json(categoryCatalog),
            "p_category_budgets": json(categoryBudgets),
            "p_budget_settings": json(budgetSettings),
            "p_bank_sources": bankSources,
            "p_notification_settings": json(notificationSettings),
            "p_appearance": json(appearance),
            "p_preferences": preferences.mapValues(\.jsonValue),
            "p_quick_expenses": json(quickExpenses),
            "p_recurring_expenses": json(recurringExpenses),
            "p_expense_edits": json(expenseEdits),
            "p_manual_transactions": json(manualTransactions)
        ]
    }
}

/// Lo que devuelve `read_config_backup`.
struct ConfigBackupPayload: Codable {
    var backupCode: String?
    var updatedAt: Date
    var accountEmail: String?
    var merchantRules: [String: String]
    var categoryCatalog: [CustomCategory]
    var categoryBudgets: [CategoryBudget]
    var budgetSettings: BudgetSettingsBackup
    var bankSources: [String: Bool]
    var notificationSettings: NotificationSettingsBackup
    var appearance: AppearanceBackup
    var preferences: [String: AnyCodableValue]?
    var quickExpenses: [QuickExpenseBackup]
    var recurringExpenses: [RecurringExpenseBackup]
    var expenseEdits: [ExpenseEdit]?
    var manualTransactions: [ManualTransactionBackup]
}

/// Lo que la sincronización guardaría de este teléfono, desglosado. Sustituye
/// al viejo "412 gastos en este dispositivo": los gastos del correo nunca se
/// suben, así que ese número decía exactamente lo contrario de la verdad.
struct BackupSummary {
    var rules = 0
    var categories = 0
    var limits = 0
    var shortcuts = 0
    var recurring = 0
    var expenseEdits = 0
    var manualExpenses = 0
    var manualIncomes = 0

    var total: Int {
        rules + categories + limits + shortcuts + recurring
        + expenseEdits + manualExpenses + manualIncomes
    }

    struct Row: Identifiable {
        let title: String
        let icon: String
        let count: Int
        var id: String { title }
    }

    /// Las filas que se enseñan, ya sin las vacías: una lista con seis ceros no
    /// informa, sólo ocupa.
    var rows: [Row] {
        [
            Row(title: "Reglas de comercio", icon: "slider.horizontal.3", count: rules),
            Row(title: "Categorías y renombrados", icon: "square.grid.2x2", count: categories),
            Row(title: "Límites por categoría", icon: "gauge.with.dots.needle.33percent", count: limits),
            Row(title: "Atajos rápidos", icon: "bolt.fill", count: shortcuts),
            Row(title: "Gastos recurrentes", icon: "repeat", count: recurring),
            Row(title: "Cambios en gastos del correo", icon: "hand.point.up.left", count: expenseEdits),
            Row(title: "Gastos anotados a mano", icon: "square.and.pencil", count: manualExpenses),
            Row(title: "Ingresos anotados a mano", icon: "arrow.down.left.circle", count: manualIncomes)
        ].filter { $0.count > 0 }
    }
}

/// Cabecera de `peek_config_backup`: saber qué hay antes de traerlo todo.
struct BackupHeader: Codable, Identifiable, Equatable {
    var backupCode: String
    var updatedAt: Date?
    var deviceLabel: String?
    var accountEmail: String?
    var hasData: Bool
    // Cuentas para poder decir "38 reglas, 12 categorías" en vez de "hay un
    // respaldo": la diferencia entre aceptar y no aceptar tiene que verse.
    var ruleCount: Int?
    var categoryCount: Int?
    var limitCount: Int?
    var shortcutCount: Int?
    var manualCount: Int?
    // Desde v5 (`agrupay_sync_v5_fx_rates_and_cleanup.sql`). Opcionales: con
    // el servidor anterior no llegan y la advertencia cae a los de arriba.
    var createdAt: Date?
    var quickCount: Int?
    var recurringCount: Int?
    var manualTxCount: Int?
    var editCount: Int?

    var id: String { backupCode }
}
