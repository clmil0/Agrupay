import Foundation

/// El «visto» de la bandeja de Pendientes, dentro de la pestaña Movimientos.
///
/// Mientras haya algo sin clasificar que todavía no se vio, tocar Movimientos
/// abre la bandeja en vez de la lista; una vez vista, Movimientos vuelve a
/// abrir la lista. Se guardan los movimientos que estaban en la bandeja la
/// última vez que se mostró: si llega uno nuevo sin clasificar, vuelve a
/// llevar ahí una vez más.
enum PendingInbox {
    private static let seenKey = "pendingInbox.seen"

    /// Hay algo en la bandeja que no estaba la última vez que se vio.
    static func hasUnseen(_ ids: [UUID], defaults: UserDefaults = .standard) -> Bool {
        let seen = Set(defaults.stringArray(forKey: seenKey) ?? [])
        return ids.contains { !seen.contains($0.uuidString) }
    }

    /// Guarda lo que hay ahora en la bandeja. Sólo eso: lo ya clasificado se
    /// cae de la lista y no crece con el tiempo.
    static func markSeen(_ ids: [UUID], defaults: UserDefaults = .standard) {
        let current = ids.map(\.uuidString).sorted()
        guard current != defaults.stringArray(forKey: seenKey) else { return }
        defaults.set(current, forKey: seenKey)
    }
}
