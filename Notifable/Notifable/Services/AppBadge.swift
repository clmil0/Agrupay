import Foundation
import UserNotifications

/// El numerito del ícono de la app: lo que espera que hagas algo.
///
/// Suma tres cosas, cada una calculada donde ya se calculaba:
/// - los pendientes de este mes (el número grande de la tarjeta Pendientes),
///   que cuenta `NotificationManager` en cada guardado;
/// - lo de Amigos: solicitudes de amistad y cobros que te recuerdan (el mismo
///   globo que la tarjeta Amigos);
/// - las categorías que pasaron su límite.
///
/// La extensión de notificaciones lo sube en uno cuando llega un cobro con la
/// app cerrada; al abrirla se vuelve a contar desde aquí.
@MainActor
enum AppBadge {

    private static let pendingKey = "appBadge.pending"
    private static let overLimitsKey = "appBadge.overLimits"

    /// Guarda la parte que cuenta la base de datos y vuelve a pintar.
    static func update(pending: Int, overLimits: Int) {
        let defaults = UserDefaults.standard
        defaults.set(pending, forKey: pendingKey)
        defaults.set(overLimits, forKey: overLimitsKey)
        apply()
    }

    /// Lo de Amigos cambió (tiempo real, «Listo», una solicitud aceptada).
    static func apply() {
        set(total)
    }

    static var total: Int {
        let defaults = UserDefaults.standard
        let friends = FriendsManager.shared.incomingRequests.count + PaymentReminders.shared.inbox.count
        return defaults.integer(forKey: pendingKey) + defaults.integer(forKey: overLimitsKey) + friends
    }

    private static var lastSet: Int?

    private static func set(_ count: Int) {
        ReminderSenders.storeBadge(count)
        guard count != lastSet else { return }
        lastSet = count
        UNUserNotificationCenter.current().setBadgeCount(count)
    }
}
