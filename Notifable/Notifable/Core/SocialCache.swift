import Foundation
import SwiftData

/// Última foto conocida de un amigo, guardada en el propio teléfono.
///
/// `FriendsManager` la pinta primero (instantáneo, sin esperar red) y luego
/// la reemplaza en cuanto llega la respuesta del servidor — que es también
/// quien la mantiene actualizada. Esta caché nunca decide nada por su cuenta,
/// sólo evita la pantalla en blanco del primer instante.
@Model
final class CachedFriend {
    @Attribute(.unique) var id: String
    var displayName: String
    var status: String
    var friendSince: Date?
    /// JSON de `PenguinLook`; `nil` si él no tiene o el servidor no lo sirve.
    var penguinJSON: String?
    /// JSON de `SocialStyle` (su perfil Pro); `nil` si no tiene.
    var styleJSON: String?

    init(id: String, displayName: String, status: String, friendSince: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.status = status
        self.friendSince = friendSince
    }
}

/// Última foto conocida de una fila de `friend_shares` (lo que un amigo te
/// comparte, o lo que tú le compartes a él). `categoryTotals`/`shareCategories`
/// van como JSON porque SwiftData no guarda arrays de structs directamente.
@Model
final class CachedFriendShare {
    @Attribute(.unique) var id: String
    var sharerID: String
    var viewerID: String
    var shareTotal: Bool
    var shareCategoriesData: Data
    var totalAmount: Double?
    var categoryTotalsData: Data
    var viewerStatus: String
    var updatedAt: String

    init(row: FriendShareRow) {
        id = row.id
        sharerID = row.sharerID
        viewerID = row.viewerID
        shareTotal = row.shareTotal
        shareCategoriesData = (try? JSONEncoder().encode(row.shareCategories)) ?? Data()
        totalAmount = row.totalAmount
        categoryTotalsData = (try? JSONEncoder().encode(row.categoryTotals)) ?? Data()
        viewerStatus = row.viewerStatus
        updatedAt = row.updatedAt
    }

    /// Sólo asigna lo que cambió: para SwiftData, asignar el mismo valor
    /// también es un cambio, y guardarlo hace releer todas las `@Query`.
    func update(from row: FriendShareRow) {
        let categories = (try? JSONEncoder().encode(row.shareCategories)) ?? Data()
        let totals = (try? JSONEncoder().encode(row.categoryTotals)) ?? Data()
        if sharerID != row.sharerID { sharerID = row.sharerID }
        if viewerID != row.viewerID { viewerID = row.viewerID }
        if shareTotal != row.shareTotal { shareTotal = row.shareTotal }
        if shareCategoriesData != categories { shareCategoriesData = categories }
        if totalAmount != row.totalAmount { totalAmount = row.totalAmount }
        if categoryTotalsData != totals { categoryTotalsData = totals }
        if viewerStatus != row.viewerStatus { viewerStatus = row.viewerStatus }
        if updatedAt != row.updatedAt { updatedAt = row.updatedAt }
    }

    var asRow: FriendShareRow {
        let categories = (try? JSONDecoder().decode([String].self, from: shareCategoriesData)) ?? []
        let totals = (try? JSONDecoder().decode([FriendShareRow.CategoryAmount].self, from: categoryTotalsData)) ?? []
        return FriendShareRow(id: id, sharerID: sharerID, viewerID: viewerID, shareTotal: shareTotal,
                               shareCategories: categories, totalAmount: totalAmount,
                               categoryTotals: totals, viewerStatus: viewerStatus, updatedAt: updatedAt)
    }
}

/// Reconoce los guardados que sólo tocaron estas cachés.
///
/// Los que escuchan `ModelContext.didSave` para recalcular algo tuyo —lo que
/// compartes con amigos, los widgets, los avisos, el respaldo— no tienen nada
/// que hacer cuando lo guardado es sólo lo que llegó de Supabase. Y si
/// reaccionaban, se armaba un bucle: dos teléfonos con la misma cuenta y
/// datos distintos se pisaban lo compartido cada 2–4 s (uno sube, el otro lo
/// recibe, lo guarda en la caché, eso lo despierta y vuelve a subir lo suyo),
/// y cada vuelta hacía releer el historial a todas las pantallas, también a
/// mitad de un deslizamiento.
enum SocialCacheSave {
    private static let entities: Set<String> = ["CachedFriend", "CachedFriendShare"]

    static func isCacheOnly(_ note: Notification) -> Bool {
        let ids = (note.userInfo ?? [:]).values.compactMap { $0 as? [PersistentIdentifier] }.joined()
        // Sin detalle de qué cambió, se trata como un cambio de verdad.
        guard !ids.isEmpty else { return false }
        return ids.allSatisfy { entities.contains($0.entityName) }
    }
}
