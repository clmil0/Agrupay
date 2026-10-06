import Foundation
import SwiftUI
import SwiftData

/// Un amigo conectado: su nombre, el estado que él escribió, y las notas
/// privadas que yo le puse (apodo, color, emoji), que salen de
/// `SocialProfileStore` y nunca del servidor. Nada financiero vive aquí — eso
/// es `FriendShareRow`.
struct Friend: Identifiable, Hashable {
    let id: String
    /// Como se llama él a sí mismo. Para lo que se enseña en pantalla usa
    /// `name`, que respeta el apodo.
    let displayName: String
    /// Su línea de estado, si el servidor ya la sirve.
    var status: String = ""
    /// Cuándo se hicieron amigos (`friendships.created_at`). `nil` si esa
    /// amistad viene de la caché local, de antes de que se empezara a pedir
    /// la columna.
    var friendSince: Date? = nil
    /// El pingüino que él se armó, si el servidor ya lo sirve y lo guardó.
    var penguin: PenguinLook? = nil
    /// Su cabecera y sus adornos del perfil Pro (`profiles.social_style`).
    var style: SocialStyle? = nil

    /// Su tema, si es Pro: el anillo, la tira del feed y el chip de su ficha.
    var proTheme: ProTheme? { style?.pro == true ? style?.tintTheme : nil }

    private var preferences: FriendPreferences { SocialProfileStore.shared.preferences(for: id) }

    /// Cómo lo llamo yo: el apodo si le puse uno.
    var name: String { SocialProfileStore.shared.name(for: id, realName: displayName) }

    var hasNickname: Bool {
        !preferences.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var initial: String { SocialProfileStore.initial(of: name) }

    /// Emoji si lo eligió; si no, la inicial.
    var glyph: String { SocialProfileStore.shared.glyph(for: id, realName: displayName) }

    var usesEmoji: Bool { preferences.emoji?.isEmpty == false }

    /// El color elegido, o el de siempre derivado del id.
    var tint: Color { SocialProfileStore.shared.color(for: id) }
}

/// Una fila de `friend_shares`: lo que un amigo (`sharerID`) decidió mostrarle
/// a otro (`viewerID`) este mes. `categoryTotals` sólo trae las categorías que
/// el propio dueño marcó — el servidor nunca ve ni guarda las demás.
struct FriendShareRow: Identifiable, Codable, Hashable {
    let id: String
    let sharerID: String
    let viewerID: String
    let shareTotal: Bool
    let shareCategories: [String]
    let totalAmount: Double?
    let categoryTotals: [CategoryAmount]
    let viewerStatus: String
    let updatedAt: String

    struct CategoryAmount: Codable, Hashable {
        let name: String
        let amount: Double
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sharerID = "sharer_id"
        case viewerID = "viewer_id"
        case shareTotal = "share_total"
        case shareCategories = "share_categories"
        case totalAmount = "total_amount"
        case categoryTotals = "category_totals"
        case viewerStatus = "viewer_status"
        case updatedAt = "updated_at"
    }
}

/// Una invitación recién creada. El token sólo existe aquí y en el enlace que
/// se manda: el servidor guarda su hash. Sirve una vez y caduca a las 72 h.
struct FriendInvite: Equatable {
    let token: String
    let expiresAt: Date

    /// `XXXX-XXXX-XXXX-XXXX-XXXX`, para leerlo o dictarlo.
    var grouped: String { InviteLinks.grouped(token) }
}

/// Alguien con quien hay una solicitud de amistad abierta, en cualquiera de
/// las dos direcciones. Sólo nombre y personaje: hasta que se acepta, no es
/// amigo y su perfil no se puede leer.
struct FriendRequest: Identifiable, Hashable {
    let id: String
    let personID: String
    let displayName: String
    let penguin: PenguinLook?
    let createdAt: Date?
}

/// Qué pasó al canjear una invitación.
enum InviteRedeemOutcome: Equatable {
    /// Solicitud enviada: falta que `name` la acepte.
    case sent(name: String)
    case alreadyFriends(name: String)
    /// No existe, caducó, ya se usó, se revocó o es tuya. El servidor no
    /// distingue a propósito: así no sirve para tantear invitaciones.
    case invalid
    case rateLimited
    case failed
}

/// Capa de red para Amigos: amistades, solicitudes, invitaciones, lo que te
/// comparten y lo que compartes. Todas las escrituras pasan por funciones RPC
/// del esquema SQL (`redeem_friend_invite`, `respond_friend_request`,
/// `upsert_my_share`, …) — nunca un INSERT/UPDATE directo, así el servidor
/// decide quién puede tocar qué, no el cliente.
///
/// `@MainActor`: sin esto, dos llamadas a `refresh()` casi simultáneas (el
/// `.task` inicial y un pull-to-refresh que se cruza, por ejemplo) podían
/// correr de verdad en paralelo en hilos distintos y las dos pasar el guard
/// de `startListeningForChanges` antes de que ninguna marcara
/// `isListeningForChanges` — eso abría dos conexiones de Realtime a la vez
/// (se veía en los logs: todo duplicado). Aislado al actor principal, esa
/// comprobación y esa asignación no pueden entrelazarse con otra llamada.
@MainActor
@Observable
final class FriendsManager {

    static let shared = FriendsManager()

    private let auth = SupabaseAuthManager.shared

    var friends: [Friend] = [] {
        // La extensión de notificaciones pinta el aviso de un cobro con la
        // cara y el apodo que ves aquí (`ReminderSenders`).
        didSet {
            if !friends.isEmpty, oldValue.isEmpty { Analytics.milestone(.firstFriend) }
            ReminderSenders.save(friends.map {
                .init(id: $0.id, name: $0.name, look: $0.usesEmoji ? nil : $0.penguin)
            })
        }
    }
    /// Te comparten algo pero todavía no lo aceptaste (aparece bajo "Te quieren compartir").
    var pendingIncoming: [FriendShareRow] = []
    /// Ya aceptado: lo que ves de cada amigo este mes.
    var acceptedIncoming: [FriendShareRow] = []
    /// Canjearon una invitación mía y esperan que los acepte.
    var incomingRequests: [FriendRequest] = [] {
        didSet { AppBadge.apply() }
    }
    /// Canjeé la invitación de alguien y espero que me acepte.
    var outgoingRequests: [FriendRequest] = []
    /// Lo que tú compartes con cada amigo este mes (una fila por amigo, si ya la tocaste).
    var outgoing: [FriendShareRow] = []
    var isLoading = false
    var lastErrorMessage: String?

    private var profileNames: [String: String] = [:]
    private var profileStatuses: [String: String] = [:]
    private var profilePenguins: [String: PenguinLook] = [:]
    private var profileStyles: [String: SocialStyle] = [:]

    private static func decodeStyle(_ json: String?) -> SocialStyle? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SocialStyle.self, from: data)
    }

    private static func encodeStyle(_ style: SocialStyle?) -> String? {
        guard let style, let data = try? JSONEncoder().encode(style) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodePenguin(_ json: String?) -> PenguinLook? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PenguinLook.self, from: data)
    }

    private static func encodePenguin(_ look: PenguinLook?) -> String? {
        guard let look, let data = try? JSONEncoder().encode(look) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Sólo se arma una vez por sesión: no hace falta re-suscribirse en cada
    /// `refresh()` (pull-to-refresh, reabrir la pestaña...), sólo la primera
    /// vez que hay sesión.
    private var isListeningForChanges = false

    private var baseURL: String { auth.baseURL }

    private static var currentMonthKey: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-01"
        return f.string(from: Date())
    }

    // MARK: - Caché local

    private var container: ModelContainer?

    /// Se llama una sola vez, al arrancar la app. Pinta con lo último que se
    /// vio **antes** de que exista sesión o red — así Amigos no vuelve a
    /// empezar en blanco cada vez que se abre la app; sólo se actualiza con lo
    /// que llegue después, por `refresh()` o por Realtime.
    func configure(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        loadFromCache()
        // Lo que un amigo te comparte sólo se pedía al abrir la app en frío
        // (o con pull-to-refresh). Realtime no cubre el hueco: en segundo
        // plano el socket se cae y lo que cambió mientras tanto no se vuelve
        // a mandar, así que al volver seguías viendo sus 500 aunque él ya
        // llevara 600. Cada vuelta al primer plano se pide de nuevo.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.auth.isReady else { return }
                await self.refresh()
            }
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.persistCachesIfStale() }
        }
    }

    private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?

    /// Lo que llegó del servidor y aún no está en la caché.
    ///
    /// La caché sólo sirve para pintar Amigos al instante en la próxima
    /// apertura, así que se escribe al pasar a segundo plano y no con cada
    /// respuesta: cada guardado en SwiftData hace que todas las `@Query` de
    /// la app vuelvan a leer el historial, y con Realtime llegaban respuestas
    /// cada pocos segundos —también a mitad de un deslizamiento en
    /// Movimientos—.
    @ObservationIgnored private var friendsCacheIsStale = false
    @ObservationIgnored private var sharesCacheIsStale = false

    private func persistCachesIfStale() {
        if friendsCacheIsStale { friendsCacheIsStale = false; persistFriendsCache() }
        if sharesCacheIsStale { sharesCacheIsStale = false; persistSharesCache() }
    }

    private func loadFromCache() {
        guard let container else { return }
        let context = ModelContext(container)

        if let cached = try? context.fetch(FetchDescriptor<CachedFriend>()), !cached.isEmpty {
            friends = cached.map {
                Friend(id: $0.id, displayName: $0.displayName, status: $0.status,
                       friendSince: $0.friendSince, penguin: Self.decodePenguin($0.penguinJSON),
                       style: Self.decodeStyle($0.styleJSON))
            }
            for friend in friends {
                profileNames[friend.id] = friend.displayName
                profileStatuses[friend.id] = friend.status
                profilePenguins[friend.id] = friend.penguin
                profileStyles[friend.id] = friend.style
            }
        }

        guard let uid = auth.userID,
              let cachedShares = try? context.fetch(FetchDescriptor<CachedFriendShare>()) else { return }
        let rows = cachedShares.map { $0.asRow }
        let asViewer = rows.filter { $0.viewerID == uid }
        pendingIncoming = asViewer.filter { $0.viewerStatus == "pending" }
        acceptedIncoming = asViewer.filter { $0.viewerStatus == "accepted" }
        outgoing = rows.filter { $0.sharerID == uid }
    }

    /// Reemplaza la caché de amigos por `friends` tal como está ahora — el
    /// servidor manda, esto sólo recuerda su última respuesta. El que ya no
    /// aparece (amistad eliminada en otro dispositivo) se borra de aquí
    /// también, si no la próxima apertura seguiría mostrándolo.
    private func persistFriendsCache() {
        guard let container else { return }
        let context = ModelContext(container)
        let existing = (try? context.fetch(FetchDescriptor<CachedFriend>())) ?? []
        var stale = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for friend in friends {
            if let row = stale.removeValue(forKey: friend.id) {
                // Sólo lo que cambió: asignar el mismo valor también cuenta
                // como cambio para SwiftData.
                let penguin = Self.encodePenguin(friend.penguin)
                if row.displayName != friend.displayName { row.displayName = friend.displayName }
                if row.status != friend.status { row.status = friend.status }
                if row.friendSince != friend.friendSince { row.friendSince = friend.friendSince }
                if row.penguinJSON != penguin { row.penguinJSON = penguin }
                let style = Self.encodeStyle(friend.style)
                if row.styleJSON != style { row.styleJSON = style }
            } else {
                let row = CachedFriend(id: friend.id, displayName: friend.displayName,
                                       status: friend.status, friendSince: friend.friendSince)
                row.penguinJSON = Self.encodePenguin(friend.penguin)
                row.styleJSON = Self.encodeStyle(friend.style)
                context.insert(row)
            }
        }
        for leftover in stale.values { context.delete(leftover) }
        // Sin cambios no se guarda. Cada guardado hace que todas las
        // `@Query` de la app vuelvan a leer el historial —Movimientos y el
        // dashboard de debajo—, y esto corre en cada recarga de amigos: al
        // volver a la app y con cada aviso de Supabase, también a mitad de un
        // deslizamiento.
        if context.hasChanges { try? context.save() }
    }

    /// Igual que `persistFriendsCache()`, para las tres listas de compartidos
    /// juntas (son la misma tabla del servidor, sólo filtrada distinto).
    private func persistSharesCache() {
        guard let container else { return }
        let context = ModelContext(container)
        let existing = (try? context.fetch(FetchDescriptor<CachedFriendShare>())) ?? []
        var stale = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for row in pendingIncoming + acceptedIncoming + outgoing {
            if let cached = stale.removeValue(forKey: row.id) {
                cached.update(from: row)
            } else {
                context.insert(CachedFriendShare(row: row))
            }
        }
        for leftover in stale.values { context.delete(leftover) }
        if context.hasChanges { try? context.save() }
    }

    func refresh() async {
        guard auth.isReady else { return }
        isLoading = true
        defer { isLoading = false }
        await loadFriendships()
        await loadShares()
        await loadRequests()
        await startListeningForChanges()
    }

    /// Escucha en vivo lo que cambia del lado de un amigo: si él canjea tu
    /// código, o si activa/edita lo que te comparte, esto llega solo — sin
    /// esperar a que el usuario haga pull-to-refresh. RLS ya filtra: sólo
    /// llegan filas donde este usuario es `user_a`/`user_b` (amistades) o
    /// `sharer_id`/`viewer_id` (compartidos).
    private func startListeningForChanges() async {
        guard !isListeningForChanges else { return }
        isListeningForChanges = true

        let realtime = SupabaseRealtimeClient.shared
        // `subscribe` no es async y devuelve el id de la suscripción: sin el
        // `_ =` el resultado queda sin usar, y el `await` sobraba.
        _ = realtime.subscribe(table: "friendships") { [weak self] _ in
            Task { await self?.loadFriendships() }
        }
        _ = realtime.subscribe(table: "friend_shares") { [weak self] _ in
            Task { await self?.loadShares() }
        }
        // Una solicitud nueva, aceptada o rechazada. Al aceptarse también
        // cambia `friendships`, que ya tiene su propia suscripción.
        _ = realtime.subscribe(table: "friend_requests") { [weak self] _ in
            Task { await self?.loadRequests() }
        }
        // Estado, nombre o personaje nuevo de un amigo. Llega todo cambio de
        // `profiles` (su RLS deja leer todas las filas), así que se vuelve a
        // pedir la lista sólo si el cambio es de alguien que ya es amigo.
        _ = realtime.subscribe(table: "profiles") { [weak self] change in
            guard let id = change.record["id"] as? String else { return }
            Task { @MainActor in
                guard let self, self.friends.contains(where: { $0.id == id }) else { return }
                await self.loadFriendships()
            }
        }
    }

    // MARK: - Amistades

    private func loadFriendships() async {
        guard let uid = auth.userID else { return }
        guard let url = URL(string: "\(baseURL)/rest/v1/friendships?or=(user_a.eq.\(uid),user_b.eq.\(uid))&select=user_a,user_b,created_at") else { return }
        guard let request = await auth.authorizedRequest(url: url, method: "GET") else { return }

        struct Row: Decodable { let user_a: String; let user_b: String; let created_at: String }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                lastErrorMessage = "No se pudieron cargar tus amigos."
                return
            }
            let rows = try JSONDecoder().decode([Row].self, from: data)
            let friendIDs = rows.map { $0.user_a == uid ? $0.user_b : $0.user_a }
            // "Amigos desde", en el perfil del amigo (`FriendProfileView`).
            var since: [String: Date] = [:]
            for row in rows {
                let friendID = row.user_a == uid ? row.user_b : row.user_a
                since[friendID] = ConfigBackupManager.parseDate(row.created_at)
            }
            guard var fetched = await fetchProfiles(ids: friendIDs) else {
                lastErrorMessage = "No se pudieron cargar tus amigos."
                return
            }
            for index in fetched.indices { fetched[index].friendSince = since[fetched[index].id] }
            friends = fetched
            friendsCacheIsStale = true
        } catch {
            lastErrorMessage = "No se pudieron cargar tus amigos."
        }
    }

    /// Tres formas de la misma consulta, de más a menos columnas, para un
    /// proyecto de Supabase al que todavía no se le ha corrido el SQL de las
    /// columnas nuevas. Sin el repliegue, no cargaría ni la lista de amigos.
    /// `nil` si ni la más básica respondió (sin red, por ejemplo): así quien
    /// llama no pisa la caché con una lista vacía.
    private func fetchProfiles(ids: [String]) async -> [Friend]? {
        guard !ids.isEmpty else { return [] }
        for columns in ["id,display_name,status,penguin,avatar,social_style",
                        "id,display_name,status,penguin,avatar", "id,display_name,status,penguin",
                        "id,display_name,status", "id,display_name"] {
            if let friends = await fetchProfiles(ids: ids, columns: columns) { return friends }
        }
        return nil
    }

    private func fetchProfiles(ids: [String], columns: String) async -> [Friend]? {
        let list = ids.joined(separator: ",")
        guard let url = URL(string: "\(baseURL)/rest/v1/profiles?id=in.(\(list))&select=\(columns)") else { return nil }
        guard let request = await auth.authorizedRequest(url: url, method: "GET") else { return nil }

        struct Row: Decodable {
            let id: String
            let display_name: String
            let status: String?
            let penguin: PenguinLook?
            let avatar: PenguinLook?
            let social_style: SocialStyle?

            /// `avatar` es el personaje completo; `penguin`, el de antes.
            var look: PenguinLook? { avatar ?? penguin }
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let rows = try JSONDecoder().decode([Row].self, from: data)
            for row in rows {
                profileNames[row.id] = row.display_name
                profileStatuses[row.id] = row.status ?? ""
                profilePenguins[row.id] = row.look
                profileStyles[row.id] = row.social_style
            }
            return rows.map { Friend(id: $0.id, displayName: $0.display_name, status: $0.status ?? "",
                                     penguin: $0.look, style: $0.social_style) }
        } catch {
            return nil
        }
    }

    /// El nombre real, tal como él lo escribió.
    func name(for id: String) -> String { profileNames[id] ?? "Amigo" }

    /// Cómo lo veo yo: el apodo que le puse, o su nombre.
    func displayName(for id: String) -> String {
        SocialProfileStore.shared.name(for: id, realName: name(for: id))
    }

    func status(for id: String) -> String { profileStatuses[id] ?? "" }

    func penguin(for id: String) -> PenguinLook? { profilePenguins[id] }

    func friend(with id: String) -> Friend {
        friends.first { $0.id == id }
            ?? Friend(id: id, displayName: name(for: id), status: status(for: id), penguin: penguin(for: id),
                      style: profileStyles[id])
    }

    // MARK: - Compartidos

    /// El mes (`yyyy-MM-01`) del que `outgoing` trae la respuesta del
    /// servidor. La caché puede ser de un mes anterior: hasta que se pida el
    /// actual, no se sabe qué hay publicado ahora.
    private var outgoingMonth: String?

    /// `true` si `outgoing` es la respuesta del servidor para el mes en curso;
    /// si no lo era, la pide. Sin red se queda en `false`.
    func ensureCurrentOutgoing() async -> Bool {
        if outgoingMonth == Self.currentMonthKey { return true }
        await loadShares()
        return outgoingMonth == Self.currentMonthKey
    }

    private func loadShares() async {
        guard let uid = auth.userID else { return }
        let month = Self.currentMonthKey

        var touched = false
        if let asViewer = await fetchShares(query: "viewer_id=eq.\(uid)&period_month=eq.\(month)") {
            pendingIncoming = asViewer.filter { $0.viewerStatus == "pending" }
            acceptedIncoming = asViewer.filter { $0.viewerStatus == "accepted" }
            touched = true
        }
        if let asSharer = await fetchShares(query: "sharer_id=eq.\(uid)&period_month=eq.\(month)") {
            outgoing = asSharer
            outgoingMonth = month
            touched = true
        }
        // Sólo si al menos una de las dos llamadas trajo algo de verdad: si
        // ambas fallaron (sin red, por ejemplo), no hay nada nuevo que
        // guardar y lo de la caché sigue siendo lo último confiable.
        if touched { sharesCacheIsStale = true }
    }

    private func fetchShares(query: String) async -> [FriendShareRow]? {
        guard let url = URL(string: "\(baseURL)/rest/v1/friend_shares?\(query)") else { return nil }
        guard let request = await auth.authorizedRequest(url: url, method: "GET") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode([FriendShareRow].self, from: data)
        } catch {
            return nil
        }
    }

    /// Mi fila de salida hacia un amigo puntual, si ya la toqué este mes.
    func myShare(toward friendID: String) -> FriendShareRow? {
        outgoing.first { $0.viewerID == friendID }
    }

    // MARK: - Invitaciones

    // MARK: - Invitaciones y solicitudes

    enum InviteCreateFailure: Error {
        /// Sin red, o el servidor no respondió.
        case offline
        /// Ya hay 10 abiertas: hay que invalidarlas antes de crear otra.
        case tooMany
    }

    /// La última invitación creada y cuándo. Abrir la hoja de invitar varias
    /// veces seguidas no debe gastar una invitación cada vez (hay un tope de
    /// 10 abiertas); pasado un rato se crea otra, por si aquella ya se usó.
    private var lastInvite: (invite: FriendInvite, createdAt: Date)?

    /// La invitación reciente si la hay; si no, una nueva.
    func inviteForSharing() async -> Result<FriendInvite, InviteCreateFailure> {
        if let lastInvite, Date().timeIntervalSince(lastInvite.createdAt) < 15 * 60,
           lastInvite.invite.expiresAt > Date() {
            return .success(lastInvite.invite)
        }
        return await createInvite()
    }

    /// Una invitación nueva de un solo uso.
    func createInvite() async -> Result<FriendInvite, InviteCreateFailure> {
        struct Response: Decodable { let token: String; let expires_at: String }
        guard let data = await rpc("create_friend_invite", body: [:]),
              let response = try? JSONDecoder().decode(Response.self, from: data) else {
            let tooMany = lastErrorMessage?.localizedCaseInsensitiveContains("demasiadas") == true
            return .failure(tooMany ? .tooMany : .offline)
        }
        let invite = FriendInvite(token: response.token,
                                  expiresAt: ConfigBackupManager.parseDate(response.expires_at)
                                      ?? Date().addingTimeInterval(72 * 3600))
        lastInvite = (invite, Date())
        return .success(invite)
    }

    /// Invalida todas mis invitaciones abiertas.
    func revokeInvites() async {
        _ = await rpc("revoke_my_friend_invites", body: [:])
        lastInvite = nil
    }

    /// Canjea la invitación de alguien: crea una solicitud que esa persona
    /// tiene que aceptar (o la amistad, si ella ya me había pedido a mí).
    func redeem(token: String) async -> InviteRedeemOutcome {
        struct Response: Decodable {
            let status: String
            let owner: Person?
        }
        guard let data = await rpc("redeem_friend_invite", body: ["p_token": token]),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return .failed }
        let name = response.owner?.display_name ?? "Tu amigo"
        switch response.status {
        case "sent":
            await loadRequests()
            return .sent(name: name)
        case "already_friends":
            await refresh()
            return .alreadyFriends(name: name)
        case "rate_limited":
            return .rateLimited
        default:
            return .invalid
        }
    }

    func loadRequests() async {
        struct Row: Decodable { let id: String; let created_at: String; let person: Person? }
        struct Response: Decodable { let incoming: [Row]; let outgoing: [Row] }
        guard let data = await rpc("list_friend_requests", body: [:]),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return }
        func map(_ rows: [Row]) -> [FriendRequest] {
            rows.compactMap { row in
                guard let person = row.person else { return nil }
                return FriendRequest(id: row.id, personID: person.id, displayName: person.display_name,
                                     penguin: person.avatar ?? person.penguin,
                                     createdAt: ConfigBackupManager.parseDate(row.created_at))
            }
        }
        incomingRequests = map(response.incoming)
        outgoingRequests = map(response.outgoing)
    }

    /// Acepto (nace la amistad) o rechazo una solicitud que me llegó.
    func respond(to request: FriendRequest, accept: Bool) async {
        _ = await rpc("respond_friend_request", body: ["p_request_id": request.id, "p_accept": accept])
        incomingRequests.removeAll { $0.id == request.id }
        if accept { await loadFriendships() }
    }

    /// Retiro una solicitud que mandé.
    func cancel(_ request: FriendRequest) async {
        _ = await rpc("cancel_friend_request", body: ["p_request_id": request.id])
        outgoingRequests.removeAll { $0.id == request.id }
    }

    /// Lo que el servidor deja ver de alguien que todavía no es amigo.
    private struct Person: Decodable {
        let id: String
        let display_name: String
        let avatar: PenguinLook?
        let penguin: PenguinLook?
    }

    /// Llama a una función RPC. `nil` si falló; el mensaje del servidor
    /// (p. ej. «Tienes demasiadas invitaciones abiertas») queda en
    /// `lastErrorMessage`.
    private func rpc(_ name: String, body: [String: Any]) async -> Data? {
        lastErrorMessage = nil
        guard let url = URL(string: "\(baseURL)/rest/v1/rpc/\(name)"),
              var request = await auth.authorizedRequest(url: url, method: "POST") else { return nil }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        guard (200...299).contains(http.statusCode) else {
            struct ServerError: Decodable { let message: String? }
            lastErrorMessage = (try? JSONDecoder().decode(ServerError.self, from: data))?.message
            return nil
        }
        return data
    }

    // MARK: - Permisos

    /// El amigo aceptó ver lo que le compartes (mueve la fila de "pendiente" a "aceptado").
    func accept(sharerID: String) async {
        await respond(sharerID: sharerID, status: "accepted")
    }

    func ignore(sharerID: String) async {
        await respond(sharerID: sharerID, status: "ignored")
    }

    private func respond(sharerID: String, status: String) async {
        guard let url = URL(string: "\(baseURL)/rest/v1/rpc/respond_to_share") else { return }
        guard var request = await auth.authorizedRequest(url: url, method: "POST") else { return }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["p_sharer_id": sharerID, "p_status": status])
        _ = try? await URLSession.shared.data(for: request)
        await loadShares()
    }

    /// Fija qué le muestro a un amigo este mes. `shareTotal`/`categories` deciden
    /// qué llega al servidor — lo que no está marcado nunca sale del teléfono.
    func setShare(viewerID: String,
                  shareTotal: Bool,
                  categories: [String],
                  totalAmount: Double,
                  categoryTotals: [FriendShareRow.CategoryAmount]) async {
        guard let url = URL(string: "\(baseURL)/rest/v1/rpc/upsert_my_share") else { return }
        guard var request = await auth.authorizedRequest(url: url, method: "POST") else { return }

        // `totalAmount`/`categoryTotals` llegan de sumar `Double` en
        // `PeriodTotals` — con suficientes movimientos arrastran el error de
        // punto flotante de siempre (ver `Money.swift`). Sin normalizar aquí,
        // ese "4066.4000000000001" viajaba tal cual al `numeric` de Supabase,
        // que sólo guarda lo que le llega, no lo corrige.
        let sentTotal = shareTotal ? Money.normalized(totalAmount) : nil
        let sentCategories = categoryTotals.filter { categories.contains($0.name) }
        let categoryPayload = sentCategories.map { ["name": $0.name, "amount": Money.normalized($0.amount)] as [String: Any] }

        var payload: [String: Any] = [
            "p_viewer_id": viewerID,
            "p_share_total": shareTotal,
            "p_share_categories": categories,
            "p_category_totals": categoryPayload
        ]
        if let sentTotal { payload["p_total_amount"] = sentTotal } else { payload["p_total_amount"] = NSNull() }

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        _ = try? await URLSession.shared.data(for: request)
        // El respaldo de configuración no lleva `friend_shares` —esa tabla se
        // reescribe cada mes y vive en el servidor—, así que lo elegido se
        // anota también aquí: es lo que devuelve "a Camila le compartías el
        // total y dos categorías" al estrenar teléfono.
        SocialProfileStore.shared.rememberShare(friendID: viewerID,
                                                shareTotal: shareTotal,
                                                categories: categories)
        await loadShares()
    }

    /// Elimina la amistad de los dos lados. Necesita la función
    /// `delete_friendship` en Supabase: borrar directo por REST lo impediría la
    /// política RLS, y debe borrar también las filas de `friend_shares` de ida
    /// y de vuelta. Si el proyecto todavía no la tiene, no se toca nada local y
    /// se dice por qué.
    @discardableResult
    func removeFriend(_ friendID: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/rest/v1/rpc/delete_friendship") else { return false }
        guard var request = await auth.authorizedRequest(url: url, method: "POST") else { return false }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["p_friend_id": friendID])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                lastErrorMessage = "Falta la función `delete_friendship` en Supabase."
                return false
            }
            SocialProfileStore.shared.forget(friendID: friendID)
            await refresh()
            return true
        } catch {
            lastErrorMessage = "No se pudo eliminar la amistad."
            return false
        }
    }

    /// Deja de compartir con un amigo puntual este mes.
    func stopSharing(viewerID: String) async {
        guard let url = URL(string: "\(baseURL)/rest/v1/rpc/stop_sharing") else { return }
        guard var request = await auth.authorizedRequest(url: url, method: "POST") else { return }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["p_viewer_id": viewerID])
        _ = try? await URLSession.shared.data(for: request)
        SocialProfileStore.shared.forgetShare(friendID: viewerID)
        await loadShares()
    }
}
