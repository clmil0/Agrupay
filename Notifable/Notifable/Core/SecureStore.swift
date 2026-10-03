import Foundation
import Security

/// Textos secretos (tokens) en el Llavero, agrupados por servicio.
///
/// `UserDefaults` es un plist sin cifrar que viaja en los respaldos del
/// teléfono: no es sitio para un token que lee todo el correo.
struct SecureStore {
    let service: String
    let accessible: CFString

    /// Tokens de Gmail y de la sesión de respaldo: sólo en este teléfono
    /// (no viajan en respaldos ni a otro equipo) y legibles con el teléfono
    /// bloqueado después del primer desbloqueo, para la lectura en segundo plano.
    static let gmail = SecureStore(service: "clmilo.Notifable.gmail",
                                   accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    static let outlook = SecureStore(service: "clmilo.Notifable.outlook",
                                     accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    static let backup = SecureStore(service: "clmilo.Notifable.backup",
                                    accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    /// El código de respaldo (`ConfigBackupManager`). Sin `ThisDeviceOnly`:
    /// pasar a otro teléfono con un respaldo cifrado se lo lleva, igual que
    /// antes se llevaba el modo que lo usa.
    static let backupCode = SecureStore(service: "clmilo.Notifable.backupcode",
                                        accessible: kSecAttrAccessibleAfterFirstUnlock)

    func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `nil` borra la entrada.
    func write(_ value: String?, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        guard let value else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = accessible
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Todo lo de este servicio.
    func removeAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Mueve los tokens que versiones anteriores dejaban en `UserDefaults` al
/// Llavero, una sola vez.
///
/// El Llavero sobrevive a borrar la app y `UserDefaults` no: antes, reinstalar
/// dejaba Gmail desconectado. Para no cambiar eso —quien borra la app espera
/// que se desconecte—, una instalación nueva limpia los tokens que hubieran
/// quedado de la anterior. Una instalación nueva se reconoce porque no tiene
/// la marca de la migración ni tokens viejos en `UserDefaults`.
enum CredentialMigration {
    private static let doneKey = "credentialsInKeychainV1"

    enum Legacy {
        static let gmailAccess = "GmailAccessToken"
        static let gmailRefresh = "GmailRefreshToken"
        static let gmailIDToken = "GmailIDToken"
        static let backupAccess = "backupAccountAccessToken"
        static let backupRefresh = "backupAccountRefreshToken"
    }

    private static let lock = NSLock()

    static func runIfNeeded(_ defaults: UserDefaults = .standard) {
        lock.lock()
        defer { lock.unlock() }
        guard !defaults.bool(forKey: doneKey) else { return }

        let legacyKeys = [Legacy.gmailAccess, Legacy.gmailRefresh, Legacy.gmailIDToken,
                          Legacy.backupAccess, Legacy.backupRefresh]
        if legacyKeys.contains(where: { defaults.string(forKey: $0) != nil }) {
            // Actualización: los tokens pasan al Llavero y salen del plist.
            SecureStore.gmail.write(defaults.string(forKey: Legacy.gmailAccess), for: GmailAuthService.Keys.accessToken)
            SecureStore.gmail.write(defaults.string(forKey: Legacy.gmailRefresh), for: GmailAuthService.Keys.refreshToken)
            if defaults.string(forKey: Legacy.gmailIDToken)?.isEmpty == false {
                defaults.set(true, forKey: GmailAuthService.Keys.hasIdentity)
            }
            SecureStore.backup.write(defaults.string(forKey: Legacy.backupAccess), for: BackupAccount.Keys.accessToken)
            SecureStore.backup.write(defaults.string(forKey: Legacy.backupRefresh), for: BackupAccount.Keys.refreshToken)
            legacyKeys.forEach { defaults.removeObject(forKey: $0) }
        } else {
            // Instalación nueva (o nunca se conectó): fuera lo de una anterior.
            SecureStore.gmail.removeAll()
            SecureStore.backup.removeAll()
            SecureStore.backupCode.removeAll()
        }
        defaults.set(true, forKey: doneKey)
    }
}
