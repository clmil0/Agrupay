import Foundation

/// Correos de banco que la búsqueda encontró pero no se pudieron descargar.
///
/// La lectura normal mira sólo desde la última lectura (menos una hora): un
/// correo que fallaba por un corte de red quedaba fuera de esa ventana en la
/// siguiente vuelta y su gasto no llegaba nunca, sin aviso. Aquí se guardan
/// con sus intentos y `GmailSyncService` los vuelve a pedir por su ID.
enum FailedEmails {

    static let key = "failedEmailIDs"

    /// Después de tantos intentos se da por perdido (y queda en Diagnóstico):
    /// uno que falla siempre no puede tener el aviso encendido para siempre.
    static let maxAttempts = 8

    /// ID → intentos fallidos.
    static func load(_ defaults: UserDefaults = .standard) -> [String: Int] {
        defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    /// Apunta el resultado de una lectura y devuelve cuántos quedan.
    ///
    /// - Parameters:
    ///   - failed: los que esta vez no se pudieron descargar.
    ///   - attempted: todos los que se intentaron; los que no fallaron salen.
    ///   - gone: los que Gmail ya no tiene (borrados por el usuario).
    @discardableResult
    static func record(failed: [String], attempted: [String], gone: Set<String>,
                       defaults: UserDefaults = .standard) -> Int {
        var pending = load(defaults)
        let failedSet = Set(failed)
        for id in attempted where !failedSet.contains(id) {
            pending[id] = nil
        }
        for id in failedSet {
            if gone.contains(id) {
                pending[id] = nil
                continue
            }
            let attempts = (pending[id] ?? 0) + 1
            if attempts >= maxAttempts {
                pending[id] = nil
                Diagnostics.shared.log("Sync Gmail: ✗ correo \(id) no se pudo descargar en \(attempts) intentos; se deja de reintentar")
            } else {
                pending[id] = attempts
            }
        }
        if !gone.isEmpty {
            Diagnostics.shared.log("Sync Gmail: \(gone.count) correos ya no existen en Gmail; no se reintentan")
        }
        if pending.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(pending, forKey: key)
        }
        return pending.count
    }
}
