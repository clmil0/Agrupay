import Foundation

/// Pide ir a una sección desde donde sea —p. ej. «Te deben S/ 90 · 3
/// personas» en una fila de Movimientos lleva a Cobros—. `ContentView` cambia
/// de pestaña. Quien lo pide desde una hoja la cierra antes.
enum SectionRequest {

    static let notification = Notification.Name("sectionOpenRequest")

    static func open(_ section: AppSection) {
        NotificationCenter.default.post(name: notification, object: nil, userInfo: ["section": section.rawValue])
    }

    static func section(from note: Notification) -> AppSection? {
        (note.userInfo?["section"] as? Int).flatMap(AppSection.init(rawValue:))
    }
}
