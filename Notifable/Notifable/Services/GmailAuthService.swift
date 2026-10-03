import Foundation
import AuthenticationServices
import CryptoKit

class GmailAuthService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    
    static let shared = GmailAuthService()
    
    @Published var isAuthenticated: Bool = false
    /// Google dejó de aceptar el permiso (se revocó desde la cuenta, cambió la
    /// contraseña o caducó): hay que volver a vincular. Antes la app seguía
    /// diciendo «Conectado» y simplemente dejaba de leer.
    @Published private(set) var accessRevoked = UserDefaults.standard.bool(forKey: Keys.accessRevoked)
    /// Hay cuenta, pero Google no dio `gmail.readonly`: en su pantalla de
    /// permisos la casilla de Gmail se puede dejar sin marcar. La identidad
    /// (respaldo, amigos) funciona; leer el correo no. Renovar el token no lo
    /// arregla —un `refresh_token` nunca trae más permisos de los concedidos—,
    /// sólo volver a vincular marcando la casilla.
    @Published private(set) var missingGmailScope = GmailAuthService.lacksGmailScope
    
    private let clientID = "565627106864-cd3nnm389bdf9cfdqo015d7tbm052bdr.apps.googleusercontent.com"
    private let redirectURI = "com.googleusercontent.apps.565627106864-cd3nnm389bdf9cfdqo015d7tbm052bdr:/oauth2callback"
    private let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenURL = "https://oauth2.googleapis.com/token"
    /// `openid email` va además de Gmail: con ellos Google devuelve un
    /// `id_token` que `BackupAccount` canjea en Supabase, así el respaldo se
    /// amarra a la cuenta del usuario sin pedirle un segundo login.
    private let scope = "openid%20email%20https://www.googleapis.com/auth/gmail.readonly"
    
    private var authSession: ASWebAuthenticationSession?

    enum Keys {
        /// En `SecureStore.gmail`.
        static let accessToken = "accessToken"
        static let refreshToken = "refreshToken"
        /// En `UserDefaults`: sólo si el login trae identidad, no el token.
        static let hasIdentity = "GmailHasIdentity"
        static let accountEmail = "GmailAccountEmail"
        static let accessRevoked = "GmailAccessRevoked"
        static let missingGmailScope = "GmailMissingGmailScope"
    }

    /// El `id_token` vive una hora y sólo sirve para canjearlo en Supabase:
    /// se guarda en memoria, nunca en disco. Si hace falta otro, se pide con
    /// el `refresh_token`.
    private var idToken: String?
    private let idTokenLock = NSLock()

    override init() {
        CredentialMigration.runIfNeeded()
        super.init()
        checkAuthStatus()
    }
    
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first as? UIWindowScene
        return windowScene?.windows.first ?? ASPresentationAnchor()
    }
    
    func checkAuthStatus() {
        isAuthenticated = getAccessToken() != nil || getRefreshToken() != nil
    }
    
    /// Vinculación recién empezada. Lo lee `GmailLinkFlow` para saber que, en
    /// cuanto llegue el token, hay que hacer las dos preguntas de después de
    /// conectar: restaurar la configuración y desde cuándo leer el correo.
    ///
    /// Se marca aquí y no en cada botón porque hay cuatro sitios que vinculan
    /// —la tarjeta de arriba de Ajustes, Gmail y bancos, la pantalla de copia
    /// de seguridad y el onboarding— y el que lo olvide deja al usuario sin la
    /// secuencia, que es justo lo que pasaba con la tarjeta de Ajustes.
    static let pendingLinkFlowKey = "pendingGmailLinkFlow"

    /// PKCE (RFC 7636) y `state`: el esquema `com.googleusercontent.apps…`
    /// lo puede registrar cualquier app, así que otra podría recibir el
    /// `code`. Sin el `code_verifier`, que no sale de esta sesión, ese código
    /// no se puede canjear; y el `state` descarta una respuesta que no pidió
    /// este login.
    func signIn() {
        UserDefaults.standard.set(true, forKey: Self.pendingLinkFlowKey)
        let verifier = Self.randomURLSafe(bytes: 32)
        let state = Self.randomURLSafe(bytes: 16)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        guard let url = URL(string: "\(authURL)?client_id=\(clientID)&redirect_uri=\(redirectURI)&response_type=code&scope=\(scope)&prompt=consent&access_type=offline&code_challenge=\(challenge)&code_challenge_method=S256&state=\(state)") else { return }

        let scheme = "com.googleusercontent.apps.565627106864-cd3nnm389bdf9cfdqo015d7tbm052bdr"

        authSession = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callbackURL, error in
            guard error == nil, let callbackURL = callbackURL else {
                print("Auth Error: \(String(describing: error))")
                let nsError = error as NSError?
                Diagnostics.shared.log("Gmail auth: la ventana de Google terminó sin respuesta (\(nsError?.domain ?? "?") \(nsError?.code ?? 0): \(nsError?.localizedDescription ?? "sin error"))")
                return
            }

            guard let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
                  items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                print("Gmail: respuesta de Google sin código o con otro state; se descarta.")
                let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let googleError = items.first(where: { $0.name == "error" })?.value ?? "ninguno"
                Diagnostics.shared.log("Gmail auth: ✗ respuesta sin código o con otro state (error de Google: \(googleError))")
                return
            }

            self.exchangeCodeForToken(code: code, verifier: verifier)
        }
        
        authSession?.presentationContextProvider = self
        let started = authSession?.start() ?? false
        Diagnostics.shared.log("Gmail auth: se abre la ventana de Google (\(started ? "ok" : "✗ no arrancó"))")
    }
    
    /// Desvincular también revoca el permiso en Google: una copia del token
    /// que hubiera quedado en otro lado deja de servir.
    func signOut() {
        Diagnostics.shared.log("Gmail auth: se desvincula la cuenta")
        UserDefaults.standard.removeObject(forKey: Self.grantedScopeKey)
        setMissingGmailScope(false)
        if let token = getRefreshToken() ?? getAccessToken() { revoke(token) }
        SecureStore.gmail.removeAll()
        setIDToken(nil)
        UserDefaults.standard.removeObject(forKey: Keys.hasIdentity)
        UserDefaults.standard.removeObject(forKey: Keys.accountEmail)
        setAccessRevoked(false)
        GmailSyncService.shared.clearFailedEmails(provider: .gmail)
        DispatchQueue.main.async {
            self.isAuthenticated = false
        }
    }

    /// `invalid_grant` al renovar: el `refresh_token` ya no vale y no volverá
    /// a valer. Se borran los tokens (el correo se queda, para decir cuál
    /// cuenta hay que volver a vincular) y la app lo muestra.
    private func markAccessRevoked() {
        Diagnostics.shared.log("Gmail auth: ✗ Google respondió invalid_grant; el permiso ya no vale y hay que volver a conectar")
        SecureStore.gmail.removeAll()
        setIDToken(nil)
        UserDefaults.standard.removeObject(forKey: Keys.hasIdentity)
        setAccessRevoked(true)
        DispatchQueue.main.async {
            self.isAuthenticated = false
        }
    }

    private func setAccessRevoked(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Keys.accessRevoked)
        DispatchQueue.main.async { self.accessRevoked = value }
    }

    private func revoke(_ token: String) {
        guard let url = URL(string: "https://oauth2.googleapis.com/revoke") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "token=\(Self.formEncoded(token))".data(using: .utf8)
        URLSession.shared.dataTask(with: request).resume()
    }

    private func exchangeCodeForToken(code: String, verifier: String) {
        guard let url = URL(string: tokenURL) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let bodyString = "code=\(Self.formEncoded(code))&client_id=\(clientID)&redirect_uri=\(Self.formEncoded(redirectURI))&grant_type=authorization_code&code_verifier=\(verifier)"
        request.httpBody = bodyString.data(using: .utf8)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                Diagnostics.shared.log("Gmail auth: ✗ canje del código, error de red: \(error?.localizedDescription ?? "sin datos")")
                return
            }
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    Diagnostics.shared.log("Gmail auth: canje del código HTTP \(status) · access: \(json["access_token"] != nil ? "sí" : "no") · refresh: \(json["refresh_token"] != nil ? "sí" : "no") · id_token: \(json["id_token"] != nil ? "sí" : "no") · permisos: \(json["scope"] as? String ?? "?") · error: \(json["error"] as? String ?? "ninguno") \(json["error_description"] as? String ?? "")")
                    if let scope = json["scope"] as? String {
                        self.rememberGrantedScope(scope)
                        if !scope.contains("gmail.readonly") {
                            // Sin permiso no hay nada que preguntar sobre
                            // cuánto correo leer: la cadena de después de
                            // vincular se salta y la app pide volver a conectar.
                            Diagnostics.shared.log("Gmail auth: ✗ Google no dio permiso para leer el correo (casilla de Gmail sin marcar)")
                            UserDefaults.standard.set(false, forKey: Self.pendingLinkFlowKey)
                        }
                    }
                    if let accessToken = json["access_token"] as? String {
                        self.saveAccessToken(accessToken)
                    }
                    if let refreshToken = json["refresh_token"] as? String {
                        self.saveRefreshToken(refreshToken)
                    }
                    self.saveIdentity(from: json)
                    if json["refresh_token"] != nil { self.setAccessRevoked(false) }
                    DispatchQueue.main.async {
                        self.checkAuthStatus()
                    }
                }
            } catch {
                print("Failed to parse token response: \(error)")
            }
        }.resume()
    }
    
    func refreshAccessToken(completion: @escaping (String?) -> Void) {
        guard let refreshToken = getRefreshToken(), let url = URL(string: tokenURL) else {
            Diagnostics.shared.log("Gmail auth: ✗ no se puede renovar, no hay refresh token guardado")
            completion(nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let bodyString = "client_id=\(clientID)&refresh_token=\(Self.formEncoded(refreshToken))&grant_type=refresh_token"
        request.httpBody = bodyString.data(using: .utf8)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                Diagnostics.shared.log("Gmail auth: ✗ renovación, error de red: \(error?.localizedDescription ?? "sin datos")")
                completion(nil)
                return
            }
            do {
                let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                Diagnostics.shared.log("Gmail auth: renovación HTTP \(status) · access: \(json?["access_token"] != nil ? "sí" : "no") · permisos: \(json?["scope"] as? String ?? "?") · error: \(json?["error"] as? String ?? "ninguno") \(json?["error_description"] as? String ?? "")")
                if let scope = json?["scope"] as? String { self.rememberGrantedScope(scope) }
                if let json, let newAccessToken = json["access_token"] as? String {
                    self.saveAccessToken(newAccessToken)
                    self.saveIdentity(from: json)
                    completion(newAccessToken)
                } else {
                    if json?["error"] as? String == "invalid_grant" { self.markAccessRevoked() }
                    completion(nil)
                }
            } catch {
                Diagnostics.shared.log("Gmail auth: ✗ renovación con respuesta ilegible (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))")
                completion(nil)
            }
        }.resume()
    }

    /// Los permisos que Google concedió de verdad. En la pantalla de
    /// consentimiento se puede desmarcar la casilla de Gmail: la cuenta queda
    /// «conectada» (hay token) pero cada lectura responde 403.
    static let grantedScopeKey = "GmailGrantedScope"

    private func rememberGrantedScope(_ scope: String) {
        UserDefaults.standard.set(scope, forKey: Self.grantedScopeKey)
        setMissingGmailScope(!scope.contains("gmail.readonly"))
    }

    /// Gmail respondió 403 por permisos insuficientes. Cubre a quien vinculó
    /// antes de que se guardaran los permisos concedidos.
    func markMissingGmailScope() {
        setMissingGmailScope(true)
    }

    private func setMissingGmailScope(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Keys.missingGmailScope)
        DispatchQueue.main.async { self.missingGmailScope = value }
    }

    /// Lo mismo que `missingGmailScope`, legible desde cualquier hilo. Mira
    /// también los permisos guardados: quien quedó así con la 3.0.2 todavía
    /// no tiene la marca.
    static var lacksGmailScope: Bool {
        UserDefaults.standard.bool(forKey: Keys.missingGmailScope) || hasGmailScope == false
    }

    static let missingScopeMessage = "Google no dio permiso para leer el correo. Vuelve a conectar Gmail y marca la casilla para ver tus correos."

    static var grantedScope: String? { UserDefaults.standard.string(forKey: grantedScopeKey) }

    /// `nil` si todavía no se sabe (se conectó antes de guardarlo).
    static var hasGmailScope: Bool? {
        grantedScope.map { $0.contains("gmail.readonly") }
    }

    var hasRefreshToken: Bool { getRefreshToken() != nil }
    
    // MARK: - Identidad (para la sincronización con cuenta)

    /// Correo de la cuenta de Google conectada, leído del `id_token`. Se queda
    /// en el teléfono para mostrarlo; no se sube a ningún lado.
    var accountEmail: String? { UserDefaults.standard.string(forKey: Keys.accountEmail) }

    /// `false` para quien conectó Gmail antes de que se pidiera `openid email`:
    /// su `refresh_token` no da `id_token`, así que tiene que volver a conectar
    /// el correo (o quedarse con el código de respaldo).
    var hasIdentityToken: Bool { UserDefaults.standard.bool(forKey: Keys.hasIdentity) }

    /// `id_token` con vida por delante. Supabase lo valida contra `exp`, así que
    /// uno de hace horas no sirve: si le queda poco se pide otro.
    func freshIdentityToken() async -> String? {
        let current = currentIDToken()
        if let current, Self.expiry(of: current)?.timeIntervalSinceNow ?? 0 > 120 { return current }
        guard getRefreshToken() != nil else { return nil }
        return await withCheckedContinuation { continuation in
            self.refreshAccessToken { _ in
                continuation.resume(returning: self.currentIDToken())
            }
        }
    }

    private func currentIDToken() -> String? {
        idTokenLock.lock()
        defer { idTokenLock.unlock() }
        return idToken
    }

    private func setIDToken(_ token: String?) {
        idTokenLock.lock()
        idToken = token
        idTokenLock.unlock()
    }

    private func saveIdentity(from json: [String: Any]) {
        guard let token = json["id_token"] as? String else { return }
        setIDToken(token)
        UserDefaults.standard.set(true, forKey: Keys.hasIdentity)
        if let email = Self.claim("email", of: token) as? String {
            UserDefaults.standard.set(email, forKey: Keys.accountEmail)
        }
    }

    private static func expiry(of jwt: String) -> Date? {
        guard let exp = claim("exp", of: jwt) as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// Lee un campo del cuerpo del JWT. No valida la firma —no hace falta: el
    /// token viene de Google por HTTPS y quien lo valida de verdad es Supabase.
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

    // MARK: - Tokens (Llavero)

    /// ¿Hay Gmail conectado en este teléfono? Sin tocar la red. Lo usa el
    /// arranque para saber si quien abre la app ya la venía usando.
    static var hasStoredSession: Bool {
        CredentialMigration.runIfNeeded()
        return SecureStore.gmail.read(Keys.refreshToken) != nil
            || SecureStore.gmail.read(Keys.accessToken) != nil
    }

    private func saveAccessToken(_ token: String) {
        SecureStore.gmail.write(token, for: Keys.accessToken)
    }

    func getAccessToken() -> String? {
        SecureStore.gmail.read(Keys.accessToken)
    }

    private func saveRefreshToken(_ token: String) {
        SecureStore.gmail.write(token, for: Keys.refreshToken)
    }

    private func getRefreshToken() -> String? {
        SecureStore.gmail.read(Keys.refreshToken)
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

    /// Un token o un código puede traer `/`, `+` o `=`: sin codificar, el
    /// cuerpo `x-www-form-urlencoded` los leería mal.
    private static func formEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

class WindowPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    let window: UIWindow
    init(window: UIWindow) {
        self.window = window
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return window
    }
}
