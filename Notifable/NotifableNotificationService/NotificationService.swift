import Intents
import SwiftUI
import UserNotifications

/// El aviso de un cobro con estilo de mensaje de iOS (`1a` de «Cobros entre
/// amigos»): la cara del personaje de quien cobra manda y el ícono de la app
/// va de insignia.
///
/// El servidor (`send-reminder-push`) manda `mutable-content` y los datos de
/// quien cobra en `sender`. Si algo falla aquí —sin personaje, sin permiso de
/// mensajes—, el aviso sale tal cual llegó: el título ya es el nombre y el
/// cuerpo ya dice de cuánto es.
final class NotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        // Un cobro más en el numerito del ícono. Al abrir la app se vuelve a
        // contar todo (`AppBadge`).
        let badge = ReminderSenders.storedBadge + 1
        ReminderSenders.storeBadge(badge)
        let bumped = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        bumped.badge = NSNumber(value: badge)
        original = bumped

        guard let sender = request.content.userInfo["sender"] as? [String: Any],
              let id = sender["id"] as? String else {
            contentHandler(bumped)
            return
        }

        // Lo que ve este teléfono (apodo, emoji en vez de personaje) manda
        // sobre lo que dice el servidor.
        let local = ReminderSenders.sender(id: id)
        let name = local?.name ?? (sender["name"] as? String) ?? request.content.title
        let look = local.map(\.look) ?? Self.look(from: sender["look"])

        Task { @MainActor in
            let image = look.flatMap(Self.avatarPNG).map(INImage.init(imageData:))
            let person = INPerson(personHandle: INPersonHandle(value: id, type: .unknown),
                                  nameComponents: nil,
                                  displayName: name,
                                  image: image,
                                  contactIdentifier: nil,
                                  customIdentifier: id)
            let intent = INSendMessageIntent(recipients: nil,
                                             outgoingMessageType: .outgoingMessageText,
                                             content: bumped.body,
                                             speakableGroupName: nil,
                                             conversationIdentifier: "payment-reminder-" + id,
                                             serviceName: nil,
                                             sender: person,
                                             attachments: nil)
            if let image { intent.setImage(image, forParameterNamed: \.sender) }

            let interaction = INInteraction(intent: intent, response: nil)
            interaction.direction = .incoming
            interaction.donate { _ in
                let updated = (try? bumped.updating(from: intent)) ?? bumped
                contentHandler(updated)
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let original { contentHandler(original) }
    }

    // MARK: - Personaje

    private static func look(from value: Any?) -> PenguinLook? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(PenguinLook.self, from: data)
    }

    /// El avatar redondo de Amigos sobre el gris azulado del diseño.
    @MainActor
    private static func avatarPNG(_ look: PenguinLook) -> Data? {
        let renderer = ImageRenderer(content:
            PenguinAvatar(look: look, size: 60, background: Color(red: 0.137, green: 0.157, blue: 0.220))
        )
        renderer.scale = 3
        return renderer.uiImage?.pngData()
    }
}
