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
    /// Alguien sin la app: vive en este teléfono (`OfflineDebts`) y se le
    /// cobra por WhatsApp.
    var isContact: Bool { OfflineDebts.isContact(debtor) }
}

/// «Joseph dice que te pagó S/ 30 en efectivo»: un «Ya le pagué» que espera
/// que lo aceptes (`list_pending_confirmations`, v17).
struct PendingConfirmation: Identifiable, Equatable {
    let id: String
    let shareID: String
    let debtor: String
    let debtKey: String
    let merchant: String
    let amount: Double
    let currency: String
    let paidAt: Date
    let via: String
}

/// «Te deben» (pestaña Cobros de Social), sobre v14 y v17.
///
/// Una deuda nace al compartir un gasto (`share_expense`, v17) o, como antes,
/// de un recordatorio con monto. Aquí se juntan las del servidor con las de
/// personas sin la app (`OfflineDebts`), y se registran pagos, se cierran
/// (pagó o perdonar) y se aceptan los «Ya le pagué».
@MainActor
@Observable
final class FriendReceivables {

    static let shared = FriendReceivables()

    private let auth = SupabaseAuthManager.shared
    private var baseURL: String { auth.baseURL }

    /// Lo del servidor. `shares` le suma lo de personas sin la app.
    private(set) var serverShares: [ReceivableShare] = []
    private(set) var pending: [PendingConfirmation] = []
    private(set) var lastErrorMessage: String?
    private(set) var hasLoaded = false
    private var isListening = false
    private var notifiedPending: Set<String> = []

    var shares: [ReceivableShare] { serverShares + OfflineDebts.shared.receivables }

    var open: [ReceivableShare] { shares.filter(\.isOpen) }
    /// Lo cerrado, lo último primero. Lo archivado (v14) ya no se ofrece y
    /// se muestra como cerrado.
    var closed: [ReceivableShare] {
        shares.filter { !$0.isOpen }
            .sorted { ($0.closedOn ?? $0.createdAt) > ($1.closedOn ?? $1.createdAt) }
    }

    /// Las partes de un gasto, abiertas y cerradas.
    func shares(forDebtKey key: String) -> [ReceivableShare] {
        shares.filter { $0.debtKey == key }
    }

    func hasOpenShares(debtKey: String) -> Bool {
        shares.contains { $0.debtKey == debtKey && $0.isOpen }
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
        serverShares = rows.compactMap(Self.share(from:))
        hasLoaded = true
        await refreshPending()
        ExpenseSharing.shared.reconcileLegacy()
        await ExpenseSharing.shared.cleanOrphans()
        listenForChanges()
    }

    /// Sin el SQL v17 no hay confirmaciones: se queda vacío sin avisar.
    private func refreshPending() async {
        guard let data = await rpc("list_pending_confirmations", body: [:], quiet: true),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        pending = rows.compactMap(Self.pending(from:))
        // Aviso local la primera vez que se ve cada uno (no hay push para esto).
        for item in pending where !notifiedPending.contains(item.id) {
            notifiedPending.insert(item.id)
            let name = FriendsManager.shared.friend(with: item.debtor).name
            LocalNotice.post(id: "debt-confirm-" + item.id,
                             title: "\(name) dice que ya te pagó " + Money.format(item.amount, currency: item.currency),
                             body: Self.viaLabel(item.via) + " · " + item.merchant)
        }
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
    func seedForQA(_ shares: [ReceivableShare], pending: [PendingConfirmation] = []) {
        self.serverShares = shares
        self.pending = pending
        hasLoaded = true
    }
    #endif

    private var offline: Bool {
        #if DEBUG
        return QAMode.isOn
        #else
        return false
        #endif
    }

    // MARK: - Compartir

    /// Anota la parte de cada amigo de un gasto, **sin avisarle**. Quien salió
    /// del reparto sin haber pagado deja de deber.
    func saveShares(debtKey: String, merchant: String, occurredOn: Date?, currency: String,
                    amounts: [String: Double]) async -> Bool {
        if offline {
            for (friend, amount) in amounts {
                if let index = serverShares.firstIndex(where: { $0.debtKey == debtKey && $0.debtor == friend }) {
                    serverShares[index] = ReceivableShare(
                        id: serverShares[index].id, debtor: friend, debtKey: debtKey, merchant: merchant,
                        occurredOn: occurredOn, amount: amount, currency: currency,
                        paidAmount: serverShares[index].paidAmount, status: serverShares[index].status,
                        createdAt: serverShares[index].createdAt, closedOn: serverShares[index].closedOn,
                        via: serverShares[index].via, reminders: serverShares[index].reminders)
                } else {
                    serverShares.append(ReceivableShare(id: "qa-" + UUID().uuidString, debtor: friend,
                                                        debtKey: debtKey, merchant: merchant, occurredOn: occurredOn,
                                                        amount: amount, currency: currency, paidAmount: 0,
                                                        status: .open, createdAt: Date(), closedOn: nil,
                                                        via: nil, reminders: []))
                }
            }
            serverShares.removeAll { $0.debtKey == debtKey && amounts[$0.debtor] == nil
                && $0.status == .open && Money.cents($0.paidAmount) == 0 }
            return true
        }
        var body: [String: Any] = [
            "p_debt_key": debtKey,
            "p_merchant": merchant,
            "p_currency": currency,
            "p_shares": amounts.mapValues { Money.decimalText($0) }
        ]
        if let occurredOn { body["p_occurred_on"] = Self.dayFormatter.string(from: occurredOn) }
        guard await rpc("share_expense", body: body) != nil else { return false }
        await refresh()
        return true
    }

    // MARK: - Acciones

    /// «Registrar pago»: el monto se recorta a lo que falta. Devuelve lo que
    /// se aplicó, o `nil` si no se aceptó.
    ///
    /// - Parameter income: el ingreso que ya es ese pago (desde un ingreso o
    ///   «¿Quién te pagó?»). Sin él se crea uno abonado al gasto.
    @discardableResult
    func recordPayment(_ share: ReceivableShare, amount: Double, via: String = "Otro",
                       income: Income? = nil) async -> Double? {
        let applied = min(Money.normalized(amount), share.remaining)
        guard Money.cents(applied) > 0 else { return nil }

        if share.isContact {
            guard OfflineDebts.shared.recordPayment(shareID: share.id, amount: applied, via: via) != nil else { return nil }
        } else {
            if !offline {
                let body: [String: Any] = ["p_share_id": share.id, "p_amount": Money.decimalText(applied), "p_via": via]
                guard await rpc("creditor_record_payment", body: body) != nil else { return nil }
            }
            if let index = serverShares.firstIndex(where: { $0.id == share.id }) {
                serverShares[index].paidAmount = Money.normalized(serverShares[index].paidAmount + applied)
                serverShares[index].via = via
                if Money.cents(serverShares[index].remaining) == 0 {
                    serverShares[index].status = .paid
                    serverShares[index].closedOn = Date()
                }
            }
            pending.removeAll { $0.shareID == share.id }
        }

        // Como cualquier pago de un amigo: ingreso abonado al gasto. Si ya no
        // queda ninguna parte abierta de ese gasto, el cobro se cierra.
        let allPaid = !hasOpenShares(debtKey: share.debtKey)
        FriendDebts.shared.recordCreditorPayment(debtor: share.debtor, debtKey: share.debtKey,
                                                 merchant: share.merchant, amount: applied,
                                                 currency: share.currency, via: via,
                                                 allPaid: allPaid, income: income)
        return applied
    }

    /// «Perdonar»: lo que falta pasa a ser gasto tuyo. `notify` le avisa al
    /// amigo («Dani te perdonó S/ 10»); sin aviso, la deuda deja de verse de
    /// su lado.
    @discardableResult
    func forgive(_ share: ReceivableShare, notify: Bool) async -> Bool {
        let remaining = share.remaining
        if share.isContact {
            OfflineDebts.shared.forgive(shareID: share.id)
        } else {
            if !offline {
                let body: [String: Any] = ["p_share_id": share.id, "p_status": "forgiven", "p_notify": notify]
                guard await rpc("close_debt_share", body: body) != nil else { return false }
            }
            if let index = serverShares.firstIndex(where: { $0.id == share.id }) {
                serverShares[index].status = .forgiven
                serverShares[index].closedOn = Date()
            }
            pending.removeAll { $0.shareID == share.id }
        }
        ExpenseSharing.shared.addForgiven(remaining, debtKey: share.debtKey,
                                          closes: !hasOpenShares(debtKey: share.debtKey))
        return true
    }

    /// «Sí, me pagó» / «No me llegó». Aceptado, el pago llega como ingreso
    /// por el camino de siempre (`FriendDebts.refresh`).
    @discardableResult
    func confirm(_ item: PendingConfirmation, accept: Bool) async -> Bool {
        if !offline {
            let body: [String: Any] = ["p_payment_id": item.id, "p_accept": accept]
            guard await rpc("confirm_debt_payment", body: body) != nil else { return false }
        }
        pending.removeAll { $0.id == item.id }
        if offline, accept, let share = serverShares.first(where: { $0.id == item.shareID }) {
            await recordPayment(share, amount: item.amount, via: Self.viaLabel(item.via))
            return true
        }
        await FriendDebts.shared.refresh()
        await refresh()
        return true
    }

    /// Se borró el gasto: sus deudas, pagos y recordatorios se van con él,
    /// también para el amigo (`delete_expense_debts`, v17).
    @discardableResult
    func deleteDebts(debtKey: String) async -> Bool {
        let hadServer = serverShares.contains { $0.debtKey == debtKey }
        if hadServer && !offline {
            guard await rpc("delete_expense_debts", body: ["p_debt_key": debtKey]) != nil else { return false }
        }
        serverShares.removeAll { $0.debtKey == debtKey }
        pending.removeAll { $0.debtKey == debtKey }
        OfflineDebts.shared.removeDebts(debtKey: debtKey)
        return true
    }

    /// Se editó un gasto anotado a mano y cambió su llave: sus deudas se
    /// mudan con él (`rekey_expense_debts`, v17).
    func rekey(from old: String, to new: String) async {
        guard old != new else { return }
        if serverShares.contains(where: { $0.debtKey == old }), !offline {
            guard await rpc("rekey_expense_debts", body: ["p_old_key": old, "p_new_key": new]) != nil else { return }
            await refresh()
        }
        OfflineDebts.shared.rekey(from: old, to: new)
    }

    /// Cobrar a alguien sin la app: WhatsApp con el monto.
    func remindByWhatsApp(_ share: ReceivableShare) {
        OfflineDebts.shared.remindByWhatsApp(share)
    }

    static func viaLabel(_ via: String) -> String {
        switch via.lowercased() {
        case "manual", "creditor", "": return "Efectivo u otro"
        default: return via
        }
    }

    // MARK: - Red

    private func rpc(_ name: String, body: [String: Any], quiet: Bool = false) async -> Data? {
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
            Diagnostics.shared.log("Cobros: \(name) devolvió \(http.statusCode) · \(raw.prefix(300))")
            if quiet { return nil }
            lastErrorMessage = raw.contains("Could not find the function")
                ? "Falta correr agrupay_cobros_v17_compartir.sql en Supabase."
                : (raw.isEmpty ? "Error \(http.statusCode)" : raw)
            return nil
        }
        if !quiet { lastErrorMessage = nil }
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

    private static func pending(from row: [String: Any]) -> PendingConfirmation? {
        guard let id = row["id"] as? String, let shareID = row["share_id"] as? String,
              let debtor = row["debtor"] as? String, let amount = number(row["amount"]) else { return nil }
        return PendingConfirmation(id: id, shareID: shareID, debtor: debtor,
                                   debtKey: row["debt_key"] as? String ?? "",
                                   merchant: row["merchant"] as? String ?? "Un gasto",
                                   amount: amount, currency: row["currency"] as? String ?? "PEN",
                                   paidAt: timestamp(row["paid_at"]) ?? Date(),
                                   via: row["via"] as? String ?? "manual")
    }
}
