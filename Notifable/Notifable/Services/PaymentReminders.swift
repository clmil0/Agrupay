import Foundation
import SwiftUI
import UIKit
import UserNotifications

/// Un recordatorio de cobro: «me estás debiendo esto».
///
/// No crea ninguna deuda del lado de quien lo recibe ni mueve un sol en la
/// contabilidad de nadie. Es un recado con el comercio, la fecha y —si quien
/// cobra lo puso— un monto.
struct PaymentReminder: Identifiable, Equatable {
    let id: String
    let fromUser: String
    let merchant: String
    let occurredOn: Date?
    let amount: Double?
    let currency: String
    let message: String
    let createdAt: Date
    var intensity: Intensity = .soft

    /// Cómo llega (`1b`/`1c` de «Cobros entre amigos»). Lo elige quien cobra.
    enum Intensity: String, CaseIterable {
        /// La notificación de siempre y el cobro entra en Amigos con un
        /// destello y un saltito del avatar.
        case soft
        /// Además, al abrir la app, un modal con el personaje del amigo.
        case intense
    }

    /// Un recordatorio renovado conserva su `id` pero cambia de fecha: para
    /// «¿ya lo vi?» cuenta como uno nuevo.
    var arrivalKey: String { id + "@" + String(Int(createdAt.timeIntervalSince1970)) }
}

/// Recordatorios de cobro entre amigos (`payment_reminders` + la función
/// `send-reminder-push`).
///
/// **El tope de uno por día lo pone el servidor**, no esta clase: el teléfono
/// sólo enseña lo que el servidor contesta. Así no hace falta confiar en el
/// reloj del que cobra ni en que la app esté al día.
@MainActor
@Observable
final class PaymentReminders {

    static let shared = PaymentReminders()

    private let auth = SupabaseAuthManager.shared
    private var baseURL: String { auth.baseURL }

    /// Lo que me están recordando y todavía no cierro.
    private(set) var inbox: [PaymentReminder] = [] {
        didSet { AppBadge.apply() }
    }
    /// Lo último que contestó el servidor cuando algo falló. Se enseña tal
    /// cual: «no se pudo enviar» a secas no deja arreglar nada.
    private(set) var lastErrorMessage: String?
    private var isListening = false

    /// Los recordatorios cuya entrada ya se animó en Amigos o cuyo modal ya
    /// salió. Guardados por `arrivalKey`: el modal sale una vez por
    /// recordatorio, y el del día siguiente (renovado) vuelve a salir.
    private(set) var seenArrivals: Set<String>
    private(set) var shownModals: Set<String>
    private static let seenKey = "paymentReminders.seenArrivals"
    private static let modalsKey = "paymentReminders.shownModals"

    private init() {
        seenArrivals = Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [])
        shownModals = Set(UserDefaults.standard.stringArray(forKey: Self.modalsKey) ?? [])
    }

    // MARK: - Llegada

    /// El cobro intenso que todavía no enseñó su modal, el más reciente.
    var pendingModal: PaymentReminder? {
        inbox.first { $0.intensity == .intense && !shownModals.contains($0.arrivalKey) }
    }

    func isNewArrival(_ reminder: PaymentReminder) -> Bool {
        !seenArrivals.contains(reminder.arrivalKey)
    }

    /// La entrada suave ya se vio: no se repite al volver a Amigos.
    func markArrivalSeen(_ reminder: PaymentReminder) {
        guard seenArrivals.insert(reminder.arrivalKey).inserted else { return }
        persist()
    }

    /// El modal salió. «Más tarde» deja el cobro en Amigos, con su entrada
    /// suave todavía pendiente de verse.
    func markModalShown(_ reminder: PaymentReminder) {
        guard shownModals.insert(reminder.arrivalKey).inserted else { return }
        persist()
    }

    /// Sólo se guardan las llaves de lo que sigue en la bandeja: la lista no
    /// crece sin fin.
    private func persist() {
        let alive = Set(inbox.map(\.arrivalKey))
        if !inbox.isEmpty {
            seenArrivals.formIntersection(alive)
            shownModals.formIntersection(alive)
        }
        UserDefaults.standard.set(Array(seenArrivals), forKey: Self.seenKey)
        UserDefaults.standard.set(Array(shownModals), forKey: Self.modalsKey)
    }

    #if DEBUG
    /// Modo QA: la bandeja sale de `QAFakeData`, sin servidor.
    func seedForQA(_ reminders: [PaymentReminder]) {
        inbox = reminders
    }
    #endif

    // MARK: - Bandeja

    func refresh() async {
        #if DEBUG
        if QAMode.isOn { return }
        #endif
        guard auth.isReady else { return }
        guard let data = await rpc("list_my_reminders", body: [:]),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        inbox = rows.compactMap(Self.reminder(from:))
        listenForChanges()
    }

    /// Llega solo, sin esperar a la notificación: el permiso puede estar
    /// denegado y el recordatorio tiene que aparecer igual en Amigos.
    private func listenForChanges() {
        guard !isListening else { return }
        isListening = true
        _ = SupabaseRealtimeClient.shared.subscribe(table: "payment_reminders") { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    /// «Listo». Quien lo mandó puede volver a escribir en cuanto se cierra.
    func dismiss(_ reminder: PaymentReminder) async {
        inbox.removeAll { $0.id == reminder.id }
        #if DEBUG
        if QAMode.isOn { return }
        #endif
        _ = await rpc("dismiss_payment_reminder", body: ["p_id": reminder.id])
    }

    // MARK: - Enviar

    /// Lo que el servidor contestó por cada amigo.
    enum SendStatus: String {
        case sent, renewed
        /// Ya se le mandó hoy y sigue sin abrirlo: no se apila otro.
        case alreadyToday = "already_today"
        case notFriend = "not_friend"
    }

    struct SendResult {
        var byFriend: [String: SendStatus] = [:]
        /// Falló la llamada entera (sin red, sin sesión).
        var failed = false

        var delivered: Int { byFriend.values.filter { $0 == .sent || $0 == .renewed }.count }
        var skipped: Int { byFriend.values.filter { $0 == .alreadyToday }.count }
    }

    /// - Parameters:
    ///   - amounts: monto por amigo. Lo que no esté aquí va sin cifra.
    func send(debtKey: String,
              merchant: String,
              occurredOn: Date?,
              currency: String,
              message: String,
              intensity: PaymentReminder.Intensity = .soft,
              to friends: [String],
              amounts: [String: Double]) async -> SendResult {
        var result = SendResult()
        guard !friends.isEmpty else { return result }

        var body: [String: Any] = [
            "p_friends": friends,
            "p_debt_key": debtKey,
            "p_merchant": merchant,
            "p_currency": currency,
            "p_message": message,
            "p_amounts": amounts.mapValues { Money.decimalText($0) }
        ]
        if let occurredOn { body["p_occurred_on"] = Self.dayFormatter.string(from: occurredOn) }
        // Sólo se manda cuando no es el de siempre: así un servidor sin el SQL
        // v11 sigue aceptando los cobros suaves.
        if intensity != .soft { body["p_intensity"] = intensity.rawValue }

        lastErrorMessage = nil
        guard let data = await rpc("send_payment_reminders", body: body),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            if intensity != .soft, lastErrorMessage?.contains("p_intensity") == true {
                lastErrorMessage = "El servidor todavía no tiene el modo intenso: falta correr agrupay_reminders_v11_intensity.sql."
            }
            result.failed = true
            return result
        }

        var ids: [String] = []
        for row in rows {
            guard let friend = row["friend"] as? String,
                  let status = (row["status"] as? String).flatMap(SendStatus.init(rawValue:)) else { continue }
            result.byFriend[friend] = status
            if status == .sent || status == .renewed, let id = row["reminder_id"] as? String {
                ids.append(id)
            }
        }

        // La notificación va aparte: si falla (sin llave de APNs configurada,
        // el amigo sin permiso), el recordatorio ya está guardado y le llegará
        // igual al abrir Amigos.
        if !ids.isEmpty { await pushReminders(ids: ids) }
        return result
    }

    /// A quién ya le escribí por esta deuda: el compositor apaga a quien ya
    /// recibió uno hoy y marca a los demás como «enviado».
    struct SentInfo: Equatable {
        let sentOn: Date
        let dismissed: Bool
        /// Ya se le mandó hoy y no lo ha abierto: hasta mañana no va otro.
        var blocksToday: Bool {
            !dismissed && Calendar.current.isDateInToday(sentOn)
        }
    }

    func sentStatus(debtKey: String) async -> [String: SentInfo] {
        guard let data = await rpc("list_sent_reminders", body: ["p_debt_key": debtKey]),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }

        var result: [String: SentInfo] = [:]
        for row in rows {
            guard let friend = row["friend"] as? String,
                  let day = (row["sent_on"] as? String).flatMap(Self.dayFormatter.date(from:)) else { continue }
            let info = SentInfo(sentOn: day, dismissed: row["dismissed_at"] is String)
            // Las filas llegan de la más reciente a la más antigua.
            if result[friend] == nil { result[friend] = info }
        }
        return result
    }

    // MARK: - Token del teléfono

    private static let tokenKey = "apnsDeviceToken"

    /// Se pide sólo con el permiso ya concedido: `registerForRemoteNotifications`
    /// sin permiso devuelve un token que no sirve para avisos visibles.
    nonisolated static func registerForPushIfAllowed() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// Lo llama el `AppDelegate` con el token que da iOS.
    func store(deviceToken: Data) async {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        await uploadStoredToken()
    }

    /// Se vuelve a subir al entrar con la cuenta: el token se pide al arrancar,
    /// muchas veces antes de que la sesión esté lista.
    func uploadStoredToken() async {
        guard auth.isReady,
              let token = UserDefaults.standard.string(forKey: Self.tokenKey) else { return }
        // Con la app instalada desde Xcode el token es del APNs de pruebas, y
        // mandarlo al de producción devuelve `BadDeviceToken`.
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        _ = await rpc("register_device_token", body: ["p_token": token, "p_environment": environment])
    }

    // MARK: - Red

    private func pushReminders(ids: [String]) async {
        guard let url = URL(string: "\(baseURL)/functions/v1/send-reminder-push"),
              var request = await auth.authorizedRequest(url: url, method: "POST") else { return }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["reminder_ids": ids])
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            Diagnostics.shared.log("Recordatorio: guardado, pero la notificación no salió")
            return
        }
    }

    private func rpc(_ name: String, body: [String: Any]) async -> Data? {
        guard let url = URL(string: "\(baseURL)/rest/v1/rpc/\(name)") else {
            lastErrorMessage = "Dirección del servidor inválida"
            return nil
        }
        guard var request = await auth.authorizedRequest(url: url, method: "POST") else {
            lastErrorMessage = "Sin sesión: entra con tu cuenta de Google en Amigos"
            return nil
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            lastErrorMessage = error.localizedDescription
            Diagnostics.shared.log("Recordatorios: \(name) sin respuesta (\(error.localizedDescription))")
            return nil
        }
        guard let http = response as? HTTPURLResponse else { return nil }
        guard (200...299).contains(http.statusCode) else {
            // El cuerpo de PostgREST dice exactamente qué pasó: la función no
            // existe (falta correr el SQL), el tipo de un parámetro no cuadra,
            // o la excepción que lanzó la propia función.
            struct ServerError: Decodable { let message: String?; let hint: String? }
            let decoded = try? JSONDecoder().decode(ServerError.self, from: data)
            let raw = String(data: data, encoding: .utf8) ?? ""
            lastErrorMessage = decoded?.message ?? (raw.isEmpty ? "Error \(http.statusCode)" : raw)
            Diagnostics.shared.log("Recordatorios: \(name) devolvió \(http.statusCode) · \(raw.prefix(300))")
            return nil
        }
        lastErrorMessage = nil
        return data
    }

    // MARK: - Formatos

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timestampFormatter = ISO8601DateFormatter()

    private static func reminder(from row: [String: Any]) -> PaymentReminder? {
        guard let id = row["id"] as? String, let from = row["from_user"] as? String else { return nil }
        let amount: Double? = {
            if let value = row["amount"] as? Double { return value }
            if let text = row["amount"] as? String { return Double(text) }
            return nil
        }()
        let created = (row["created_at"] as? String).flatMap {
            timestampFormatter.date(from: $0) ?? ISO8601DateFormatter.withFractionalSeconds.date(from: $0)
        }
        return PaymentReminder(
            id: id,
            fromUser: from,
            merchant: row["merchant"] as? String ?? "Un gasto",
            occurredOn: (row["occurred_on"] as? String).flatMap(dayFormatter.date(from:)),
            amount: amount,
            currency: row["currency"] as? String ?? "PEN",
            message: row["message"] as? String ?? "",
            createdAt: created ?? Date(),
            intensity: (row["intensity"] as? String).flatMap(PaymentReminder.Intensity.init(rawValue:)) ?? .soft
        )
    }
}

private extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
