import Foundation
import SwiftUI

/// Lo que este teléfono recuerda de Amigos y **no** vive en el servidor.
///
/// El apodo, el color y el emoji de un amigo son míos: los ve sólo quien los
/// puso, y subirlos convertiría una nota privada en algo que el otro podría
/// leer. Por eso se guardan aquí y viajan en el respaldo de configuración —que
/// es de una sola persona— y no en `profiles` ni en `friend_shares`.
///
/// Guardado como un único JSON en `UserDefaults`: así entra en
/// `AppPreferences.syncable` sin abrir una columna nueva por cada campo, y el
/// respaldo lo lleva junto a los límites, las reglas y los atajos.
struct FriendPreferences: Codable, Hashable {
    /// Cómo llamo yo a este amigo. Vacío = su nombre real.
    var nickname: String = ""
    /// Índice dentro de `SocialPalette.colors`. `nil` = el color derivado de su
    /// id, que es el que tenía antes de que se pudiera elegir.
    var colorIndex: Int?
    /// Emoji en lugar de la inicial. `nil` = inicial.
    var emoji: String?

    /// Espejo local de lo que le comparto. La verdad está en el servidor, pero
    /// sin esta copia el respaldo no podría devolver "a Camila le compartías el
    /// total y dos categorías" al cambiar de teléfono: `friend_shares` se
    /// reescribe cada mes y no viaja en la copia de configuración.
    var sharedTotal: Bool = false
    var sharedCategories: [String] = []
    /// Cuándo se tocó por última vez lo compartido con este amigo.
    var sharedUpdatedAt: Date?
}

/// Los ocho colores de amigo del diseño, en el mismo orden.
enum SocialPalette {
    static let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo, .red]

    /// El color de siempre cuando nadie eligió uno: estable por id.
    static func defaultIndex(for id: String) -> Int {
        let hash = id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return hash % colors.count
    }

    static func color(for id: String, index: Int?) -> Color {
        colors[(index ?? defaultIndex(for: id)) % colors.count]
    }
}

/// Mi identidad social y mis notas por amigo.
@Observable
final class SocialProfileStore {

    static let shared = SocialProfileStore()

    enum Keys {
        /// El mismo que ya usaba `SupabaseAuthManager`: el nombre que ven los amigos.
        static let displayName = "socialDisplayName"
        /// Una línea que ven mis amigos ("Ahorrando para el viaje a Cusco").
        static let status = "socialStatus"
        /// Emoji de mi avatar; vacío = mi inicial.
        static let avatarEmoji = "socialAvatarEmoji"
        /// Índice dentro de `SocialBanner.allCases` para mi cabecera. -1 = sin
        /// elegir todavía (usa el primero).
        static let bannerIndex = "socialBannerIndex"
        /// JSON `PenguinLook`: mi pingüino. Ausente = el clásico.
        static let penguin = "socialPenguin"
        /// JSON `SocialStyle`: cielo, aura, fondo, marco y entrada del perfil
        /// Pro. Ausente = sin adornos.
        static let style = "socialStyle"
        /// JSON `[idDeAmigo: FriendPreferences]`.
        static let friendPreferences = "socialFriendPreferences"
    }

    /// El estado cabe en una línea: más que eso deja de leerse de un vistazo en
    /// la tarjeta, que es el único sitio donde aparece.
    static let statusLimit = 60

    private(set) var preferences: [String: FriendPreferences] = [:]

    /// Guardados **y** publicados: leerlos de `UserDefaults` en cada acceso los
    /// dejaba fuera de la observación, y la tarjeta de perfil no se enteraba de
    /// que el usuario acababa de cambiarse el nombre.
    var displayName: String = "" {
        didSet { UserDefaults.standard.set(displayName, forKey: Keys.displayName) }
    }

    var status: String = "" {
        didSet {
            let trimmed = String(status.prefix(Self.statusLimit))
            if trimmed != status { status = trimmed; return }
            UserDefaults.standard.set(status, forKey: Keys.status)
        }
    }

    var avatarEmoji: String? {
        didSet { UserDefaults.standard.set(avatarEmoji ?? "", forKey: Keys.avatarEmoji) }
    }

    /// Índice en `SocialBanner.allCases`. `nil` = todavía no elegido (se pinta
    /// el primero, pero no cuenta como una elección que respaldar).
    var bannerIndex: Int? {
        didSet { UserDefaults.standard.set(bannerIndex ?? -1, forKey: Keys.bannerIndex) }
    }

    var penguin: PenguinLook = PenguinLook() {
        didSet {
            guard let data = try? JSONEncoder().encode(penguin),
                  let json = String(data: data, encoding: .utf8) else { return }
            UserDefaults.standard.set(json, forKey: Keys.penguin)
        }
    }

    /// Mis elecciones del perfil Pro. Se guardan aunque deje de ser Pro: al
    /// volver, todo está como lo dejé.
    var style: SocialStyle = SocialStyle() {
        didSet {
            guard let data = try? JSONEncoder().encode(style),
                  let json = String(data: data, encoding: .utf8) else { return }
            UserDefaults.standard.set(json, forKey: Keys.style)
        }
    }

    /// Lo que se sube a `profiles.social_style` y lo que pinta mi tarjeta:
    /// con la cabecera básica elegida, si hoy soy Pro y, en lo que no elegí,
    /// mi fondo Pro de Apariencia.
    var publishedStyle: SocialStyle { styled(style, banner: bannerIndex) }

    /// `draft` tal como lo verían mis amigos con la cabecera `banner`.
    func styled(_ draft: SocialStyle, banner: Int?) -> SocialStyle {
        var value = draft.withDefaults(ProTheme.current)
        value.banner = banner
        value.pro = ProStore.isPro
        return value
    }

    private static func storedStyle() -> SocialStyle? {
        guard let raw = UserDefaults.standard.string(forKey: Keys.style),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SocialStyle.self, from: data)
    }

    private static func storedPenguin() -> PenguinLook? {
        guard let raw = UserDefaults.standard.string(forKey: Keys.penguin),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PenguinLook.self, from: data)
    }

    private init() {
        let defaults = UserDefaults.standard
        displayName = defaults.string(forKey: Keys.displayName) ?? ""
        status = defaults.string(forKey: Keys.status) ?? ""
        let emoji = defaults.string(forKey: Keys.avatarEmoji) ?? ""
        avatarEmoji = emoji.isEmpty ? nil : emoji
        let banner = defaults.object(forKey: Keys.bannerIndex) as? Int ?? -1
        bannerIndex = banner < 0 ? nil : banner
        penguin = Self.storedPenguin() ?? PenguinLook()
        style = Self.storedStyle() ?? SocialStyle()
        load()
    }

    // MARK: - Por amigo

    func preferences(for friendID: String) -> FriendPreferences {
        preferences[friendID] ?? FriendPreferences()
    }

    /// El nombre con el que aparece en toda la app: el apodo si lo puse, y si
    /// no, el que él eligió.
    func name(for friendID: String, realName: String) -> String {
        let nickname = preferences(for: friendID).nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return nickname.isEmpty ? realName : nickname
    }

    func color(for friendID: String) -> Color {
        SocialPalette.color(for: friendID, index: preferences(for: friendID).colorIndex)
    }

    /// Emoji si lo eligió, y si no la inicial del nombre con el que lo veo.
    func glyph(for friendID: String, realName: String) -> String {
        if let emoji = preferences(for: friendID).emoji, !emoji.isEmpty { return emoji }
        return Self.initial(of: name(for: friendID, realName: realName))
    }

    func save(_ value: FriendPreferences, for friendID: String) {
        preferences[friendID] = value
        persist()
    }

    func update(_ friendID: String, _ change: (inout FriendPreferences) -> Void) {
        var value = preferences(for: friendID)
        change(&value)
        save(value, for: friendID)
    }

    /// Lo que le comparto, registrado en cuanto se guarda en el servidor.
    func rememberShare(friendID: String, shareTotal: Bool, categories: [String]) {
        update(friendID) {
            $0.sharedTotal = shareTotal
            $0.sharedCategories = categories.sorted()
            $0.sharedUpdatedAt = Date()
        }
    }

    func forgetShare(friendID: String) {
        update(friendID) {
            $0.sharedTotal = false
            $0.sharedCategories = []
            $0.sharedUpdatedAt = Date()
        }
    }

    /// "Eliminar amigo" borra también lo que yo había anotado de él.
    func forget(friendID: String) {
        preferences.removeValue(forKey: friendID)
        persist()
    }

    static func initial(of name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "?" : String(trimmed.prefix(1)).uppercased()
    }

    // MARK: - Persistencia

    private func load() {
        guard let raw = UserDefaults.standard.string(forKey: Keys.friendPreferences),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: FriendPreferences].self, from: data) else { return }
        preferences = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: Keys.friendPreferences)
    }

    /// Tras restaurar un respaldo: `UserDefaults` ya trae los valores nuevos,
    /// pero esta instancia sigue con lo que leyó al arrancar.
    func reloadFromDefaults() {
        let defaults = UserDefaults.standard
        displayName = defaults.string(forKey: Keys.displayName) ?? displayName
        status = defaults.string(forKey: Keys.status) ?? status
        let emoji = defaults.string(forKey: Keys.avatarEmoji) ?? ""
        avatarEmoji = emoji.isEmpty ? nil : emoji
        let banner = defaults.object(forKey: Keys.bannerIndex) as? Int ?? -1
        bannerIndex = banner < 0 ? nil : banner
        penguin = Self.storedPenguin() ?? penguin
        style = Self.storedStyle() ?? style
        preferences = [:]
        load()
    }
}
