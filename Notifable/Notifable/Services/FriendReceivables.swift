import Foundation

/// Una parte de deuda que un amigo **me** debe (`debt_shares`, lado de quien
/// cobra): «Joseph te debe S/ 50 de la pizza». La otra cara de `OwedShare`.
struct ReceivableShare: Identifiable, Equatable {
    let id: String
    /// Quien debe: el `id` del amigo.
    let debtor: String
    /// El gasto en este teléfono (`TransactionKey`).
    let debtKey: String
    let merchant: String
    let occurredOn: Date?
    let amount: Double
    let currency: String
    var paidAmount: Double
    var status: Status
    let createdAt: Date
    var closedOn: Date?
    /// Cómo llegó el último pago: «Yape», «Plin», «manual»…
    var via: String?
    /// Cada día en que se le cobró, del más antiguo al más reciente.
    var reminders: [Date]

    enum Status: String {
        case open, paid, forgiven, archived
    }

    var remaining: Double { Money.clampedToZero(Money.subtract(amount, paidAmount)) }
    var isOpen: Bool { status == .open && Money.cents(remaining) > 0 }
    /// La fecha de la deuda: la del gasto o, si no la trae, cuando se cobró.
    var date: Date { occurredOn ?? createdAt }
    var sentToday: Bool { reminders.contains { Calendar.current.isDateInToday($0) } }
}

/// «Te deben» (pestaña Cobros de Social), sobre `agrupay_receivables_v14_creditor_view.sql`.
///
/// Las deudas nacen de un recordatorio con monto (v12). Aquí sólo se leen y se
/// cierran: registrar un pago que llegó por fuera, perdonar o archivar.
@MainActor
@Observable
final class FriendReceivables {

    static let shared = FriendReceivables()

    private let auth = SupabaseAuthManager.shared
    private var baseURL: String { auth.baseURL }

    private(set) var shares: [ReceivableShare] = []
    private(set) var lastErrorMessage: String?
    private(set) var hasLoaded = false
    private var isListening = false

    var open: [ReceivableShare] { shares.filter(\.isOpen) }
    /// Lo cerrado, lo último primero.
    var closed: [ReceivableShare] {
        shares.filter { !$0.isOpen }
            .sorted { ($0.closedOn ?? $0.createdAt) > ($1.closedOn ?? $1.createdAt) }
    }

    // MARK: - Servidor

    func refresh() async {
        #if DEBUG
        if QAMode.isOn { hasLoaded = true; return }
        #endif
        guard auth.isReady else { return }
        guard let data = await rpc("list_my_receivables", body: [:]),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            hasLoaded = true
            return
        }
        shares = rows.compactMap(Self.share(from:))
        hasLoaded = true
        listenForChanges()
    }

    private func listenForChanges() {
        guard !isListening else { return }
        isListening = true
        for table in ["debt_shares", "debt_payments", "payment_reminders"] {
            _ = SupabaseRealtimeClient.shared.subscribe(table: table) { [weak self] _ in
                Task { await self?.refresh() }
            }
        }
    }

    #if DEBUG
    func seedForQA(_ shares: [ReceivableShare]) {
        self.shares = shares
        hasLoaded = true
    }
    #endif

    // MARK: - Acciones

    /// «Registrar pago»: el monto se recorta a lo que falta. Devuelve lo que
    /// se aplicó, o `nil` si el servidor no lo aceptó.
    @discardableResult
    func recordPayment(_ share: ReceivableShare, amount: Double) async -> Double? {
        let applied = min(Money.normalized(amount), share.remaining)
        guard Money.cents(applied) > 0 else { return nil }

        #if DEBUG
        let offline = QAMode.isOn
        #else
        let offline = false
        #endif
        if !offline {
            let body: [String: Any] = ["p_share_id": share.id, "p_amount": Money.decimalText(applied)]
            guard await rpc("creditor_record_payment", body: body) != nil else { return nil }
        }

        guard let index = shares.firstIndex(where: { $0.id == share.id }) else { return applied }
        shares[index].paidAmount = Money.normalized(shares[index].paidAmount + applied)
        shares[index].via = "manual"
        if Money.cents(shares[index].remaining) == 0 {
            shares[index].status = .paid
            shares[index].closedOn = Date()
        }

        // Como cualquier pago de un amigo: ingreso abonado al gasto. Si ya no
        // queda ninguna parte abierta de ese gasto, lo que falte es tuyo.
        let allPaid = !shares.contains { $0.debtKey == share.debtKey && $0.isOpen }
        FriendDebts.shared.recordCreditorPayment(debtor: share.debtor, debtKey: share.debtKey,
                                                 merchant: share.merchant, amount: applied,
                                                 currency: share.currency, allPaid: allPaid)
        return applied
    }

    /// Perdonar (le llega a quien debe) o archivar (sólo sale de tu lista).
    @discardableResult
    func close(_ share: ReceivableShare, as status: ReceivableShare.Status) async -> Bool {
        guard status == .forgiven || status == .archived else { return false }
        #if DEBUG
        let offline = QAMode.isOn
        #else
        let offline = false
        #endif
        if !offline {
            let body: [String: Any] = ["p_share_id": share.id, "p_status": status.rawValue]
            guard await rpc("close_debt_share", body: body) != nil else { return false }
        }
        if let index = shares.firstIndex(where: { $0.id == share.id }) {
            shares[index].status = status
            shares[index].closedOn = Date()
        }
        // Perdonar la última parte abierta: el resto del gasto es tuyo. Al
        // archivar no se toca nada: es sólo quitarla de la vista.
        if status == .forgiven, !shares.contains(where: { $0.debtKey == share.debtKey && $0.isOpen }) {
            FriendDebts.shared.settleLocalDebt(debtKey: share.debtKey)
        }
        return true
    }

    // MARK: - Red

    private func rpc(_ name: String, body: [String: Any]) async -> Data? {
        guard let url = URL(string: "\(baseURL)/rest/v1/rpc/\(name)"),
              var request = await auth.authorizedRequest(url: url, method: "POST") else {
            lastErrorMessage = "Sin sesión: entra con tu cuenta de Google en Amigos"
            return nil
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            lastErrorMessage = "Sin conexión"
            return nil
        }
        guard (200...299).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            lastErrorMessage = raw.contains("Could not find the function")
                ? "Falta correr agrupay_receivables_v14_creditor_view.sql en Supabase."
                : (raw.isEmpty ? "Error \(http.statusCode)" : raw)
            Diagnostics.shared.log("Cobros: \(name) devolvió \(http.statusCode) · \(raw.prefix(300))")
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
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func timestamp(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return timestampFormatter.date(from: text) ?? fractionalFormatter.date(from: text)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func share(from row: [String: Any]) -> ReceivableShare? {
        guard let id = row["id"] as? String, let debtor = row["debtor"] as? String,
              let amount = number(row["amount"]) else { return nil }
        let status = (row["status"] as? String).flatMap(ReceivableShare.Status.init(rawValue:)) ?? .open
        let reminders = (row["reminder_dates"] as? [String] ?? []).compactMap(dayFormatter.date(from:))
        return ReceivableShare(id: id, debtor: debtor,
                               debtKey: row["debt_key"] as? String ?? "",
                               merchant: row["merchant"] as? String ?? "Un gasto",
                               occurredOn: (row["occurred_on"] as? String).flatMap(dayFormatter.date(from:)),
                               amount: amount,
                               currency: row["currency"] as? String ?? "PEN",
                               paidAmount: number(row["paid_amount"]) ?? 0,
                               status: status,
                               createdAt: timestamp(row["created_at"]) ?? Date(),
                               closedOn: timestamp(row["closed_at"]) ?? timestamp(row["paid_at"]),
                               via: row["last_via"] as? String,
                               reminders: reminders.sorted())
    }
}
