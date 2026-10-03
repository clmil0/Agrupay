import Foundation

/// Sesión de Supabase **con la cuenta de Google del usuario**, para que la
/// sincronización no dependa de que él guarde un código.
///
/// No abre ningún login nuevo: reusa el mismo inicio de sesión de Google que la
/// app ya hace para leer el correo (`GmailAuthService`). A ese login se le
/// añadieron los permisos `openid email`, así que Google devuelve además un
/// `id_token`; ese token se canjea una sola vez en Supabase
/// (`grant_type=id_token`) por una sesión propia, y a partir de ahí se renueva
/// con el `refresh_token` de Supabase sin volver a pasar por Google.
///
/// Es deliberadamente independiente de `SupabaseAuthManager` (la sesión
/// anónima de Amigos): aquella identifica al dispositivo y sus amistades
/// cuelgan de ese `auth.uid()`; ésta identifica a la persona. Fundirlas
/// significaría migrar las amistades a la cuenta nueva, que es un trabajo
/// aparte.
@MainActor
@Observable
final class BackupAccount {

    static let shared = BackupAccount()

    private let projectURL = "https://zjzzqaeusmxmtszgdncl.supabase.co"
    private let apiKey = "sb_publishable_NVM2GcvxZFmf0VLNbaBr7A_y_8EMS97"

    enum Keys {
        // `UserDefaults`: no abren nada por sí solos.
        static let userID = "backupAccountUserID"
        static let email = "backupAccountEmail"
        static let expiresAt = "backupAccountExpiresAt"
        // `SecureStore.backup`.
        static let accessToken = "accessToken"
        static let refreshToken = "refreshToken"
    }

    private(set) var userID: String?
    private(set) var email: String?

    private var accessToken: String?
    private var refreshToken: String?
    private var expiresAt: Date?

    var isSignedIn: Bool { userID != nil && refreshToken != nil }

    /// `true` si el usuario podría entrar sin ver ninguna pantalla nueva:
    /// Gmail u Outlook ya están conectados y su login trae `id_token`.
    var canSignInSilently: Bool {
        GmailAuthService.shared.hasIdentityToken || OutlookAuthService.shared.hasIdentityToken
    }

    /// Con qué cuenta se entra. Google manda si están las dos: es con la que
    /// ya entraba todo el que tenía respaldo antes de Outlook, y cambiar de
    /// proveedor sería otra cuenta de Supabase (otro respaldo).
    private enum Provider: String {
        case google, azure
        var label: String { self == .google ? "Google" : "Microsoft (Azure)" }
    }

    private var provider: Provider {
        GmailAuthService.shared.hasIdentityToken || !OutlookAuthService.shared.hasIdentityToken ? .google : .azure
    }

    private init() {
        CredentialMigration.runIfNeeded()
        let d = UserDefaults.standard
        userID = d.string(forKey: Keys.userID)
        email = d.string(forKey: Keys.email)
        accessToken = SecureStore.backup.read(Keys.accessToken)
        refreshToken = SecureStore.backup.read(Keys.refreshToken)
        expiresAt = d.object(forKey: Keys.expiresAt) as? Date
    }

    // MARK: - Entrar

    private struct SessionResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Int?
        let user: UserPayload
        struct UserPayload: Decodable {
            let id: String
            let email: String?
        }
    }

    /// Canjea el `id_token` de Google —o, si sólo hay Outlook, el de
    /// Microsoft— por una sesión de Supabase. Devuelve el motivo del fallo, o
    /// `nil` si salió bien.
    @discardableResult
    func signInWithMailAccount() async -> String? {
        let provider = provider
        let token = provider == .google
            ? await GmailAuthService.shared.freshIdentityToken()
            : await OutlookAuthService.shared.freshIdentityToken()
        guard let idToken = token else {
            return "Conecta tu correo de Gmail u Outlook para usar tu cuenta (Ajustes → Correo y bancos)."
        }
        guard let url = URL(string: "\(projectURL)/auth/v1/token?grant_type=id_token") else {
            return "URL inválida."
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "apikey")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "provider": provider.rawValue,
            "id_token": idToken
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                return Self.explain(status: status, body: data, idToken: idToken, provider: provider)
            }
            let session = try JSONDecoder().decode(SessionResponse.self, from: data)
            store(session)
            return nil
        } catch {
            return "No se pudo iniciar sesión: \(error.localizedDescription)"
        }
    }

    /// Traduce el rechazo de Supabase a la corrección concreta.
    ///
    /// El caso real: Google emite el `id_token` con `aud` = el client ID que
    /// pidió el login (el de iOS, porque el login lo hace la app), y Supabase
    /// lo compara contra su lista de "Client IDs". Si ahí sólo está el cliente
    /// web, responde "Unacceptable audience" — un mensaje que no dice dónde se
    /// arregla ni qué valor falta. Aquí se dice, con el ID listo para copiar.
    private static func explain(status: Int, body: Data, idToken: String, provider: Provider) -> String {
        let text = String(data: body, encoding: .utf8) ?? ""

        if text.localizedCaseInsensitiveContains("audience") {
            let audience = claim("aud", of: idToken) as? String ?? "el client ID de iOS"
            return """
            Supabase no reconoce este client ID. Añádelo en Authentication →             Providers → \(provider.label), campo «Client IDs» (van separados por coma,             junto al que ya tienes):

            \(audience)
            """
        }

        if text.localizedCaseInsensitiveContains("nonce") {
            return "Supabase esperaba un «nonce» que este login no envía. Activa «Skip nonce checks» en Authentication → Providers → \(provider.label)."
        }

        if text.localizedCaseInsensitiveContains("provider is not enabled")
            || text.localizedCaseInsensitiveContains("unsupported provider") {
            return "El proveedor \(provider.label) está apagado en Supabase. Actívalo en Authentication → Providers → \(provider.label)."
        }

        if status == 401 || status == 403 {
            return "Supabase rechazó la sesión (HTTP \(status)). Revisa que el proveedor \(provider.label) esté activado. \(text.prefix(140))"
        }

        return "No se pudo iniciar sesión (HTTP \(status)). \(text.prefix(180))"
    }

    /// Lee un campo del cuerpo del JWT, sin validar la firma: sólo sirve para
    /// poder enseñar el `aud` que Supabase acaba de rechazar.
    private static func claim(_ name: String, of jwt: String) -> Any? {
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

    private func store(_ session: SessionResponse) {
        userID = session.user.id
        email = session.user.email ?? GmailAuthService.shared.accountEmail ?? OutlookAuthService.shared.accountEmail
        accessToken = session.access_token
        refreshToken = session.refresh_token
        expiresAt = Date().addingTimeInterval(TimeInterval(session.expires_in ?? 3600))

        let d = UserDefaults.standard
        d.set(userID, forKey: Keys.userID)
        d.set(email, forKey: Keys.email)
        d.set(expiresAt, forKey: Keys.expiresAt)
        SecureStore.backup.write(accessToken, for: Keys.accessToken)
        SecureStore.backup.write(refreshToken, for: Keys.refreshToken)
    }

    func signOut() {
        userID = nil
        email = nil
        accessToken = nil
        refreshToken = nil
        expiresAt = nil
        let d = UserDefaults.standard
        [Keys.userID, Keys.email, Keys.expiresAt].forEach { d.removeObject(forKey: $0) }
        SecureStore.backup.removeAll()
    }

    // MARK: - Token vivo

    /// Token de acceso válido, renovándolo si le queda menos de un minuto. Si
    /// el `refresh_token` ya no sirve (sesión revocada), intenta volver a
    /// entrar con Google en silencio antes de darse por vencido.
    func validAccessToken() async -> String? {
        if let accessToken, let expiresAt, expiresAt.timeIntervalSinceNow > 60 {
            return accessToken
        }
        if await refreshSession() { return accessToken }
        if canSignInSilently, await signInWithMailAccount() == nil { return accessToken }
        return nil
    }

    @discardableResult
    private func refreshSession() async -> Bool {
        guard let refreshToken else { return false }
        guard let url = URL(string: "\(projectURL)/auth/v1/token?grant_type=refresh_token") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "apikey")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return false }
            let session = try JSONDecoder().decode(SessionResponse.self, from: data)
            store(session)
            return true
        } catch {
            return false
        }
    }

    /// Petición firmada con la cuenta si hay sesión; si no, con la apikey
    /// anónima (el camino del código de respaldo).
    func authorizedRequest(url: URL) async -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "apikey")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = await validAccessToken() {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    var baseURL: String { projectURL }
}
