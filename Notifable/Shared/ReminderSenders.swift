import Foundation

/// Cómo se ve cada amigo en **este** teléfono —con el apodo que le puse y su
/// personaje—, para que la extensión de notificaciones pinte el aviso de un
/// cobro con la misma cara que Amigos (`1a` de «Cobros entre amigos»).
///
/// La app lo escribe en el App Group cada vez que cambia la lista de amigos;
/// la extensión sólo lo lee. Si falta (amigo nuevo, app sin abrir), la
/// extensión usa el nombre y el personaje que manda el servidor.
enum ReminderSenders {

    struct Sender: Codable, Equatable {
        let id: String
        let name: String
        /// `nil` si le puse un emoji: esa nota privada manda sobre su
        /// personaje, y en el aviso no se dibuja.
        let look: PenguinLook?
    }

    private static let key = "reminderSenders"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: WidgetSnapshotStore.appGroupID) }

    static func save(_ senders: [Sender]) {
        guard let data = try? JSONEncoder().encode(senders) else { return }
        guard defaults?.data(forKey: key) != data else { return }
        defaults?.set(data, forKey: key)
    }

    // MARK: - Numerito del ícono

    private static let badgeKey = "appBadgeCount"

    /// El último numerito que puso la app, para que la extensión lo suba en
    /// uno al llegar un cobro con la app cerrada.
    static func storeBadge(_ count: Int) {
        defaults?.set(count, forKey: badgeKey)
    }

    static var storedBadge: Int { defaults?.integer(forKey: badgeKey) ?? 0 }

    static func sender(id: String) -> Sender? {
        guard let data = defaults?.data(forKey: key),
              let senders = try? JSONDecoder().decode([Sender].self, from: data) else { return nil }
        return senders.first { $0.id == id }
    }
}
