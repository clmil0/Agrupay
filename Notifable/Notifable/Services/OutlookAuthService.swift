import Foundation
import AuthenticationServices
import CryptoKit

/// Outlook, Hotmail y Live: el mismo login de Microsoft para cuentas
/// personales y de trabajo, y el correo se lee con Microsoft Graph.
///
/// Es el gemelo de `GmailAuthService`: ASWebAuthenticationSession con PKCE y
/// `state`, sin MSAL. Microsoft no tiene un permiso «restringido» como
/// `gmail.readonly`: `Mail.Read` sólo pide el registro de la app en Azure.
///
/// Los tokens van en `SecureStore.outlook`. A diferencia de Google, Microsoft
/// cambia el `refresh_token` en cada renovación: siempre se guarda el nuevo.
final class OutlookAuthService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {

    static let shared = OutlookAuthService()

    /// «Application (client) ID» del registro en el portal de Azure (Entra
    /// ID). Vacío = Outlook todavía no está configurado y no se ofrece.
    static let clientID = ""

    /// Lo genera Azure para la plataforma «iOS / macOS» con el bundle ID de
    /// la app; tiene que coincidir letra por letra con el del registro.
    private static let callbackScheme = "msauth.clmilo.Notifable"
    private static let redirectURI = "msauth.clmilo.Notifable://auth"
    /// `common`: cuentas personales (outlook.com, hotmail, live) y de trabajo.
    private static let authority = "https://login.microsoftonline.com/common/oauth2/v2.0"
    /// `openid email` dan el `id_token` con el que `BackupAccount` entra en
    /// Supabase; `offline_access`, el `refresh_token`.
    private static let scope = "openid email offline_access https://graph.microsoft.com/Mail.Read"

    @Published private(set) var isAuthenticated = false
    /// Microsoft respondió `invalid_grant`: se cambió la contraseña o se
    /// retiró el permiso. Hay que volver a vincular.
    @Published private(set) var accessRevoked = UserDefaults.standard.bool(forKey: Keys.accessRevoked)

    enum Keys {
        /// En `SecureStore.outlook`.
        static let accessToken = "accessToken"
        static let refreshToken = "refreshToken"
        /// En `UserDefaults`.
        static let expiresAt = "OutlookAccessExpiresAt"
        static let accountEmail = "OutlookAccountEmail"
        static let hasIdentity = "OutlookHasIdentity"
        static let accessRevoked = "OutlookAccessRevoked"
    }

    private var authSession: ASWebAuthenticationSession?
    private var idToken: String?
    private let lock = NSLock()

    static var isConfigured: Bool { !clientID.isEmpty }

    override init() {
        super.init()
        isAuthenticated = Self.hasStoredSession
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return windowScene?.windows.first ?? ASPresentationAnchor()
    }

    /// ¿Hay Outlook conectado en este teléfono? Sin tocar la red.
    static var hasStoredSession: Bool {
        SecureStore.outlook.read(Keys.refreshToken) != nil
    }

    var accountEmail: String? { UserDefaults.standard.string(forKey: Keys.accountEmail) }
    var hasIdentityToken: Bool { UserDefaults.standard.bool(forKey: Keys.hasIdentity) }

    // MARK: - Vincular

    func signIn() {
        guard Self.isConfigured else {
            Diagnostics.shared.log("Outlook auth: ✗ falta el client ID de Azure")
            return
        }
        let verifier = Self.randomURLSafe(bytes: 32)
        let state = Self.randomURLSafe(bytes: 16)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        var components = URLComponents(string: "\(Self.authority)/authorize")
        components?.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "response_mode", value: "query"),
            .init(name: "scope", value: Self.scope),
            .init(name: "prompt", value: "select_account"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state)
        ]
        guard let url = components?.url else { return }

        authSession = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { callbackURL, error in
            guard error == nil, let callbackURL else {
                let nsError = error as NSError?
                Diagnostics.shared.log("Outlook auth: la ventana de Microsoft terminó sin respuesta (\(nsError?.domain ?? "?") \(nsError?.code ?? 0))")
                return
            }
            let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                let msError = items.first(where: { $0.name == "error_description" })?.value
                    ?? items.first(where: { $0.name == "error" })?.value ?? "ninguno"
                Diagnostics.shared.log("Outlook auth: ✗ respuesta sin código o con otro state (error de Microsoft: \(msError))")
                return
            }
            self.requestToken(body: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": Self.redirectURI,
                "code_verifier": verifier
            ], isLink: true) { _ in }
        }
        authSession?.presentationContextProvider = self
        let started = authSession?.start() ?? false
        Diagnostics.shared.log("Outlook auth: se abre la ventana de Microsoft (\(started ? "ok" : "✗ no arrancó"))")
    }

    /// Microsoft no tiene un endpoint para revocar el token de una cuenta
    /// personal: se borra del teléfono y el permiso se quita en
    /// account.live.com (el botón «Permisos de Microsoft»).
    func signOut() {
        Diagnostics.shared.log("Outlook auth: se desvincula la cuenta")
        SecureStore.outlook.removeAll()
        setIDToken(nil)
        let d = UserDefaults.standard
        [Keys.expiresAt, Keys.accountEmail, Keys.hasIdentity].forEach { d.removeObject(forKey: $0) }
        setAccessRevoked(false)
        GmailSyncService.shared.clearFailedEmails(provider: .outlook)
        DispatchQueue.main.async { self.isAuthenticated = false }
    }

    // MARK: - Tokens

    /// Token de acceso con al menos cinco minutos de vida; si no, se renueva.
    func validAccessToken(completion: @escaping (String?) -> Void) {
        if let token = SecureStore.outlook.read(Keys.accessToken),
           let expiresAt = UserDefaults.standard.object(forKey: Keys.expiresAt) as? Date,
           expiresAt.timeIntervalSinceNow > 300 {
            return completion(token)
        }
        refresh(completion: completion)
    }

    func validAccessToken() async -> String? {
        await withCheckedContinuation { continuation in
            validAccessToken { continuation.resume(returning: $0) }
        }
    }

    func refresh(completion: @escaping (String?) -> Void) {
        guard let refreshToken = SecureStore.outlook.read(Keys.refreshToken) else {
            Diagnostics.shared.log("Outlook auth: ✗ no se puede renovar, no hay refresh token guardado")
            return completion(nil)
        }
        requestToken(body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": Self.scope
        ], isLink: false, completion: completion)
    }

    /// `id_token` con vida por delante, para `BackupAccount`.
    func freshIdentityToken() async -> String? {
        if let current = currentIDToken(),
           (Self.claim("exp", of: current) as? Double).map({ $0 - Date().timeIntervalSince1970 > 120 }) == true {
            return current
        }
        guard Self.hasStoredSession else { return nil }
        return await withCheckedContinuation { continuation in
            refresh { _ in continuation.resume(returning: self.currentIDToken()) }
        }
    }

    private func requestToken(body: [String: String], isLink: Bool, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "\(Self.authority)/token") else { return completion(nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields = body
        fields["client_id"] = Self.clientID
        request.httpBody = fields.map { "\($0.key)=\(Self.formEncoded($0.value))" }
            .joined(separator: "&").data(using: .utf8)

        let label = isLink ? "canje del código" : "renovación"
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data, error == nil else {
                Diagnostics.shared.log("Outlook auth: ✗ \(label), error de red: \(error?.localizedDescription ?? "sin datos")")
                return completion(nil)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            Diagnostics.shared.log("Outlook auth: \(label) HTTP \(status) · access: \(json["access_token"] != nil ? "sí" : "no") · refresh: \(json["refresh_token"] != nil ? "sí" : "no") · id_token: \(json["id_token"] != nil ? "sí" : "no") · permisos: \(json["scope"] as? String ?? "?") · error: \(json["error"] as? String ?? "ninguno")")

            guard let access = json["access_token"] as? String else {
                if json["error"] as? String == "invalid_grant", !isLink { self.markAccessRevoked() }
                return completion(nil)
            }
            SecureStore.outlook.write(access, for: Keys.accessToken)
            if let refresh = json["refresh_token"] as? String {
                SecureStore.outlook.write(refresh, for: Keys.refreshToken)
            }
            let expiresIn = (json["expires_in"] as? Double) ?? (json["expires_in"] as? String).flatMap(Double.init) ?? 3600
            UserDefaults.standard.set(Date().addingTimeInterval(expiresIn), forKey: Keys.expiresAt)
            self.saveIdentity(from: json)
            self.setAccessRevoked(false)
            completion(access)

            DispatchQueue.main.async {
                let wasConnected = self.isAuthenticated
                self.isAuthenticated = Self.hasStoredSession
                // Recién vinculada: se lee su pasado con el mismo alcance que
                // «Leer ahora». Sólo Outlook: releer Gmail no hace falta.
                if isLink, !wasConnected, self.isAuthenticated {
                    GmailSyncService.shared.syncEmails(force: true, startDate: GmailLookback.startDate,
                                                       endDate: Date(), providers: [.outlook])
                }
            }
        }.resume()
    }

    private func markAccessRevoked() {
        Diagnostics.shared.log("Outlook auth: ✗ Microsoft respondió invalid_grant; hay que volver a conectar")
        SecureStore.outlook.removeAll()
        setIDToken(nil)
        UserDefaults.standard.removeObject(forKey: Keys.hasIdentity)
        setAccessRevoked(true)
        DispatchQueue.main.async { self.isAuthenticated = false }
    }

    private func setAccessRevoked(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Keys.accessRevoked)
        DispatchQueue.main.async { self.accessRevoked = value }
    }

    // MARK: - Identidad

    private func saveIdentity(from json: [String: Any]) {
        guard let token = json["id_token"] as? String else { return }
        setIDToken(token)
        UserDefaults.standard.set(true, forKey: Keys.hasIdentity)
        // Una cuenta de trabajo puede no traer `email`; `preferred_username`
        // suele ser la misma dirección.
        if let email = (Self.claim("email", of: token) ?? Self.claim("preferred_username", of: token)) as? String {
            UserDefaults.standard.set(email, forKey: Keys.accountEmail)
        }
    }

    private func currentIDToken() -> String? {
        lock.lock(); defer { lock.unlock() }
        return idToken
    }

    private func setIDToken(_ token: String?) {
        lock.lock(); idToken = token; lock.unlock()
    }

    static func claim(_ name: String, of jwt: String) -> Any? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json[name]
    }

    // MARK: - Utilidades

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - Correo (Microsoft Graph)

/// Buscar y bajar correos de Outlook. Sus IDs van con el prefijo `ms:` en
/// `Expense.emailID`, `processedEmailIDs` y `FailedEmails`: así no chocan con
/// los de Gmail y `GmailSyncService` sabe a quién pedir cada uno.
///
/// Se piden IDs **inmutables** (`Prefer: IdType="ImmutableId"`): el ID normal
/// de Graph cambia cuando el correo se mueve de carpeta, y el mismo aviso
/// volvería a importarse como nuevo.
enum OutlookMail {

    static let idPrefix = "ms:"
    private static let baseURL = "https://graph.microsoft.com/v1.0/me"

    static func isOutlookID(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    enum Failure: Error { case http(Int, String) }

    /// IDs (con prefijo) de los correos de esos remitentes entre esas fechas.
    /// Mira todas las carpetas, también No deseado: ahí acaban a veces los
    /// avisos del banco en Outlook.
    ///
    /// El filtro por remitente va en el servidor. Si algún buzón lo rechaza
    /// (400), se repite sólo por fechas y los remitentes se filtran aquí: más
    /// datos, pero la lectura no se queda sin nada.
    static func list(senders: [String], after: Date, before: Date?, token: String,
                     completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        let iso = ISO8601DateFormatter()
        var dates = "receivedDateTime ge \(iso.string(from: after))"
        if let before { dates += " and receivedDateTime le \(iso.string(from: before))" }
        let unique = Set(senders.map { $0.lowercased() })
        let bySender = unique.isEmpty ? dates
            : dates + " and (" + unique.sorted().map { "from/emailAddress/address eq '\($0)'" }.joined(separator: " or ") + ")"

        func url(_ filter: String, select: String) -> URL? {
            var components = URLComponents(string: "\(baseURL)/messages")
            components?.queryItems = [
                .init(name: "$filter", value: filter),
                .init(name: "$select", value: select),
                .init(name: "$top", value: "500")
            ]
            return components?.url
        }
        guard let first = url(bySender, select: "id") else { return completion(.success([])) }
        Diagnostics.shared.log("Sync Outlook: búsqueda «\(bySender)»")
        page(url: first, token: token, senders: nil, accumulated: []) { result in
            guard case .failure(Failure.http(400, _)) = result, !unique.isEmpty,
                  let fallback = url(dates, select: "id,from") else { return completion(result) }
            Diagnostics.shared.log("Sync Outlook: el filtro por remitente no se aceptó; se busca por fechas y se filtra aquí")
            page(url: fallback, token: token, senders: unique, accumulated: [], completion: completion)
        }
    }

    /// - Parameter senders: si no es `nil`, sólo se quedan los de esos remitentes.
    private static func page(url: URL, token: String, senders: Set<String>?, accumulated: [[String: Any]],
                             completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        URLSession.shared.dataTask(with: request(url, token: token)) { data, response, error in
            if let error { return completion(.failure(error)) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(status), let data else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.prefix(300)) } ?? ""
                Diagnostics.shared.log("Sync Outlook: ✗ lista HTTP \(status): \(body)")
                return completion(.failure(Failure.http(status, body)))
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let found = (json?["value"] as? [[String: Any]] ?? []).compactMap { item -> [String: Any]? in
                guard let id = item["id"] as? String else { return nil }
                if let senders {
                    let from = ((item["from"] as? [String: Any])?["emailAddress"] as? [String: Any])?["address"] as? String
                    guard let from, senders.contains(from.lowercased()) else { return nil }
                }
                return ["id": idPrefix + id]
            }
            let total = accumulated + found
            Diagnostics.shared.log("Sync Outlook: página con \(found.count) correos (acumulado \(total.count))")
            if let next = (json?["@odata.nextLink"] as? String).flatMap(URL.init(string:)), total.count < 10_000 {
                page(url: next, token: token, senders: senders, accumulated: total, completion: completion)
            } else {
                completion(.success(total))
            }
        }.resume()
    }

    /// Texto del correo y cuándo llegó. El cuerpo HTML se limpia igual que el
    /// de Gmail, para que los lectores de cada banco vean lo mismo venga de
    /// donde venga. `gone` = el correo ya no existe (404).
    static func fetch(id: String, token: String,
                      completion: @escaping (_ body: String?, _ receivedAt: Date?, _ gone: Bool) -> Void) {
        let graphID = String(id.dropFirst(idPrefix.count))
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let encoded = graphID.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "\(baseURL)/messages/\(encoded)?$select=body,receivedDateTime,from,subject") else {
            return completion(nil, nil, false)
        }
        URLSession.shared.dataTask(with: request(url, token: token)) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard error == nil, (200...299).contains(status), let data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                Diagnostics.shared.log("Sync Outlook: ✗ correo \(id) HTTP \(status) \(error?.localizedDescription ?? "")")
                return completion(nil, nil, status == 404 || status == 410)
            }
            let body = json["body"] as? [String: Any]
            let content = body?["content"] as? String ?? ""
            let text: String
            if (body?["contentType"] as? String)?.lowercased() == "html" {
                let stripped = content.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                text = GmailSyncService.decodeHTMLEntities(stripped)
            } else {
                text = content
            }
            let from = ((json["from"] as? [String: Any])?["emailAddress"] as? [String: Any])?["address"] as? String
            Diagnostics.shared.log("Sync Outlook: correo \(id) · \(from ?? "?") · «\(json["subject"] as? String ?? "?")» · \(text.count) caracteres")
            let receivedAt = (json["receivedDateTime"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            completion(text, receivedAt, false)
        }.resume()
    }

    private static func request(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("IdType=\"ImmutableId\"", forHTTPHeaderField: "Prefer")
        return request
    }
}
