import Foundation
import UserNotifications

/// Un aviso local inmediato: lo que pasa con tus cobros mientras no hay push
/// del servidor para eso («Joseph dice que ya te pagó», «Pago detectado»).
enum LocalNotice {
    static func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Diagnostics.shared.log("Aviso local no salió (\(error.localizedDescription))") }
        }
    }
}
