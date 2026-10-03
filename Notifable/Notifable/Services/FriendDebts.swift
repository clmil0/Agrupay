import Foundation
import SwiftData
import UIKit
import UserNotifications

/// Pagos entre amigos que se detectan solos (`agrupay_debts_v12_friend_payments.sql`).
///
/// A quien cobra casi nunca le llega el correo del Yape que recibe; a quien
/// paga siempre le llega el de su Yape enviado. Así que esta clase hace dos
/// trabajos, según de qué lado estés:
///
/// - **Debes** (`owed`): cada vez que entra un gasto con destinatario, el
///   `DebtPaymentMatcher` mira si paga una deuda abierta. Si el destinatario
///   ya está vinculado al amigo y el monto es exacto, se avisa al servidor
///   solo; si no, queda una pregunta (`suggestions`).
/// - **Te deben**: los pagos que tus amigos declararon llegan como ingreso
///   abonado a la deuda, igual que si lo hubieras registrado a mano.
///
/// Al servidor sólo sube «pagó S/ X de la deuda Y»: ni el correo ni el nombre
/// del destinatario.
@MainActor
@Observable
final class FriendDebts {

    static let shared = FriendDebts()

    private let auth = SupabaseAuthManager.shared
    private var baseURL: String { auth.baseURL }

    /// Lo que yo debo: abierto y lo pagado en los últimos 30 días.
    private(set) var owed: [OwedShare] = []
    /// Envíos que podrían ser el pago de una deuda y esperan que decidas.
    private(set) var suggestions: [DebtPaymentMatcher.Suggestion] = []
    /// El último pago que se marcó solo, para el aviso con «Deshacer».
    private(set) var lastAuto: AutoPayment?
    private(set) var lastErrorMessage: String?

    struct AutoPayment: Equatable {
        let paymentID: String
        let shareID: String
        let candidateKey: String
        let friendID: String
        let amount: Double
        let currency: String
        let merchant: String
    }

    private var container: ModelContainer?
    private var observers: [NSObjectProtocol] = []
    private var pendingMatch: Task<Void, Never>?
    private var isListening = false
    private var isProcessingIncoming = false

    private let defaults = UserDefaults.standard
    private static let linksKey = "friendDebts.payeeLinks"
    private static let rejectedKey = "friendDebts.rejectedLinks"
    private static let handledKey = "friendDebts.handledCandidates"
    private static let processedKey = "friendDebts.processedPayments"

    #if DEBUG
    /// Modo QA: los pagos que «llegan» de amigos, sin servidor.
    private var qaIncoming: [IncomingPayment] = []
    #endif

    // MARK: - Arranque

    func start(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        let center = NotificationCenter.default
        // Entró un gasto (un Yape nuevo del correo): ¿paga alguna deuda?
        observers.append(center.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
            guard !SocialCacheSave.isCacheOnly(note) else { return }
            Task { @MainActor in self?.scheduleMatch() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        })
    }

    private func scheduleMatch() {
        pendingMatch?.cancel()
        pendingMatch = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.rematch()
        }
    }

    // MARK: - Servidor

    func refresh() async {
        #if DEBUG
        if QAMode.isOn {
            await processIncoming()
            await rematch()
            return
        }
        #endif
        guard auth.isReady else { return }
        if let data = await rpc("list_my_debts", body: [:]),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            owed = rows.compactMap(Self.share(from:))
        }
        listenForChanges()
        await processIncoming()
        await rematch()
    }

    private func listenForChanges() {
        guard !isListening else { return }
        isListening = true
        for table in ["debt_shares", "debt_payments"] {
            _ = SupabaseRealtimeClient.shared.subscribe(table: table) { [weak self] _ in
                Task { await self?.refresh() }
            }
        }
    }

    #if DEBUG
    func seedForQA(owed: [OwedShare], incoming: [IncomingPayment]) {
        self.owed = owed
        qaIncoming = incoming
    }
    #endif

    // MARK: - Lado de quien debe

    /// Vuelve a mirar los envíos recientes contra lo que debo.
    func rematch() async {
        guard let context = container?.mainContext else { return }
        let result = DebtPaymentMatcher.match(
            candidates: Self.candidates(in: context),
            shares: owed,
            links: links,
            rejectedLinks: rejected,
            handled: Set(handled.keys),
            friendNames: friendNames
        )
        suggestions = result.suggestions
        for auto in result.autos {
            await pay(auto.share, amount: auto.candidate.amount, candidate: auto.candidate, automatic: true)
        }
    }

    /// «Sí, era para esa deuda.» Si el destinatario no estaba vinculado,
    /// queda vinculado: el próximo pago exacto a él ya no pregunta.
    func confirm(_ suggestion: DebtPaymentMatcher.Suggestion, share: OwedShare) async {
        if suggestion.needsLink {
            var current = links
            current[suggestion.candidate.payeeKey] = suggestion.friendID
            links = current
        }
        suggestions.removeAll { $0.id == suggestion.id }
        await pay(share, amount: suggestion.candidate.amount, candidate: suggestion.candidate, automatic: false)
    }

    /// «No era para eso.» Si además preguntaba por el vínculo, no se vuelve a
    /// preguntar por esa persona con ese amigo.
    func reject(_ suggestion: DebtPaymentMatcher.Suggestion) {
        if suggestion.needsLink {
            var current = rejected
            current.insert(DebtPaymentMatcher.rejectKey(payee: suggestion.candidate.payeeKey, friend: suggestion.friendID))
            rejected = current
        }
        markHandled(suggestion.candidate.key, as: "no")
        suggestions.removeAll { $0.id == suggestion.id }
    }

    /// «Ya le pagué» sin correo detrás (efectivo, otra cuenta).
    func payManually(_ share: OwedShare) async {
        await pay(share, amount: share.remaining, sourceKey: "manual:" + UUID().uuidString,
                  paidAt: Date(), via: "manual", automatic: false, candidateKey: nil)
    }

    func undoLastAuto() async {
        guard let auto = lastAuto else { return }
        lastAuto = nil
        // Descartado y no borrado: si no, el mismo envío se volvería a pagar
        // solo en la siguiente pasada.
        markHandled(auto.candidateKey, as: "no")
        #if DEBUG
        if QAMode.isOn {
            if let index = owed.firstIndex(where: { $0.id == auto.shareID }) {
                owed[index].paidAmount = Money.subtract(owed[index].paidAmount, auto.amount)
                owed[index].isPaid = false
                owed[index].paidAt = nil
            }
            return
        }
        #endif
        guard let data = await rpc("undo_debt_payment", body: ["p_payment_id": auto.paymentID]),
              (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? Bool == true else {
            let name = FriendsManager.shared.friend(with: auto.friendID).name
            lastErrorMessage = "\(name) ya lo vio: pídele que lo borre de su lado."
            return
        }
        await refresh()
    }

    func dismissAutoNotice() { lastAuto = nil }

    private func pay(_ share: OwedShare, amount: Double, candidate: DebtPaymentCandidate, automatic: Bool) async {
        await pay(share, amount: amount, sourceKey: candidate.key, paidAt: candidate.date,
                  via: candidate.via.name, automatic: automatic, candidateKey: candidate.key)
    }

    private func pay(_ share: OwedShare, amount: Double, sourceKey: String, paidAt: Date,
                     via: String, automatic: Bool, candidateKey: String?) async {
        let applied = min(Money.normalized(amount), share.remaining)
        guard Money.cents(applied) > 0 else { return }

        var paymentID = "qa-" + UUID().uuidString
        #if DEBUG
        let offline = QAMode.isOn
        #else
        let offline = false
        #endif
        if !offline {
            let body: [String: Any] = [
                "p_share_id": share.id,
                "p_amount": Money.decimalText(applied),
                "p_source_key": sourceKey,
                "p_paid_at": Self.timestampFormatter.string(from: paidAt),
                "p_via": via
            ]
            guard let data = await rpc("pay_debt_share", body: body),
                  let row = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first else { return }
            paymentID = row["payment_id"] as? String ?? ""
        }

        if let candidateKey { markHandled(candidateKey, as: share.id) }
        if let index = owed.firstIndex(where: { $0.id == share.id }) {
            owed[index].paidAmount = Money.normalized(owed[index].paidAmount + applied)
            if Money.cents(owed[index].remaining) == 0 {
                owed[index].isPaid = true
                owed[index].paidAt = Date()
            }
        }

        guard automatic, let candidateKey, !paymentID.isEmpty else { return }
        let auto = AutoPayment(paymentID: paymentID, shareID: share.id, candidateKey: candidateKey,
                               friendID: share.creditor, amount: applied, currency: share.currency,
                               merchant: share.merchant)
        lastAuto = auto
        let name = FriendsManager.shared.friend(with: share.creditor).name
        notify(id: "debt-paid-" + share.id,
               title: "Pago a \(name) detectado",
               body: Money.format(applied, currency: share.currency) + " · " + share.merchant
                   + ". Ya le figura que le pagaste.")
    }

    /// Los envíos recientes con destinatario: lo único que puede ser un pago.
    private static func candidates(in context: ModelContext) -> [DebtPaymentCandidate] {
        let since = Date().addingTimeInterval(-DebtPaymentMatcher.lookback)
        let descriptor = FetchDescriptor<Expense>(predicate: #Predicate { $0.date >= since })
        let expenses = (try? context.fetch(descriptor)) ?? []
        return expenses.compactMap { expense in
            guard !expense.isTransfer, !expense.isVoided, expense.splitOf == nil,
                  let payee = expense.payee, let key = expense.payeeKey else { return nil }
            return DebtPaymentCandidate(key: TransactionKey.key(for: expense), payeeKey: key,
                                        payeeName: payee.name, via: payee.via,
                                        amount: expense.amount, currency: expense.currency, date: expense.date)
        }
    }

    private var friendNames: [String: [String]] {
        let manager = FriendsManager.shared
        var result: [String: [String]] = [:]
        for creditor in Set(owed.map(\.creditor)) {
            let friend = manager.friend(with: creditor)
            result[creditor] = [friend.displayName, friend.name]
        }
        return result
    }

    // MARK: - Lado de quien cobra

    struct IncomingPayment: Equatable {
        let id: String
        let debtor: String
        let debtKey: String
        let merchant: String
        let amount: Double
        let currency: String
        let paidAt: Date
        let via: String
        /// Ya no queda nada que cobrar de ese gasto: lo que falte es tuyo.
        let allPaid: Bool
    }

    /// Cada pago que un amigo declaró se vuelve un ingreso abonado a la deuda,
    /// como si lo hubieras registrado a mano. Luego se le avisa al servidor
    /// para no anotarlo dos veces.
    private func processIncoming() async {
        guard !isProcessingIncoming, let context = container?.mainContext else { return }
        isProcessingIncoming = true
        defer { isProcessingIncoming = false }

        var payments: [IncomingPayment] = []
        #if DEBUG
        if QAMode.isOn {
            payments = qaIncoming
            qaIncoming = []
        }
        #endif
        if payments.isEmpty, auth.isReady,
           let data = await rpc("list_incoming_debt_payments", body: [:]),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            payments = rows.compactMap(Self.incoming(from:))
        }
        guard !payments.isEmpty else { return }

        var processed = Set(defaults.stringArray(forKey: Self.processedKey) ?? [])
        let fresh = payments.filter { !processed.contains($0.id) }
        if !fresh.isEmpty {
            let expenses = (try? context.fetch(FetchDescriptor<Expense>())) ?? []
            let byKey = TransactionKey.expensesByLookupKey(expenses)
            for payment in fresh {
                record(payment, debt: byKey[payment.debtKey], in: context)
                processed.insert(payment.id)
            }
            // Antes de avisar al servidor: si el aviso falla, la próxima vez
            // se reconoce y no se anota dos veces.
            defaults.set(Array(processed), forKey: Self.processedKey)
            try? context.save()
        }

        #if DEBUG
        if QAMode.isOn { return }
        #endif
        _ = await rpc("ack_debt_payments", body: ["p_ids": payments.map(\.id)])
    }

    /// «Registrar pago» desde Cobros (lado de quien cobra): lo que te pagaron
    /// por fuera —efectivo, un Yape cuyo correo no llegó— entra igual que un
    /// pago que declaró el amigo: ingreso abonado a la deuda, y la deuda
    /// saldada si ya no queda nada por cobrar.
    func recordCreditorPayment(debtor: String, debtKey: String, merchant: String,
                               amount: Double, currency: String, allPaid: Bool) {
        guard let context = container?.mainContext else { return }
        let payment = IncomingPayment(id: "creditor:" + UUID().uuidString, debtor: debtor, debtKey: debtKey,
                                      merchant: merchant, amount: amount, currency: currency,
                                      paidAt: Date(), via: "manual", allPaid: allPaid)
        let expenses = (try? context.fetch(FetchDescriptor<Expense>())) ?? []
        record(payment, debt: TransactionKey.expensesByLookupKey(expenses)[debtKey], in: context,
               notifies: false, note: "Su parte de " + merchant + " · registrado a mano")
        try? context.save()
    }

    /// Perdonaste la última parte abierta de un gasto: lo que queda es tuyo.
    func settleLocalDebt(debtKey: String) {
        guard let context = container?.mainContext else { return }
        let expenses = (try? context.fetch(FetchDescriptor<Expense>())) ?? []
        guard let debt = TransactionKey.expensesByLookupKey(expenses)[debtKey], debt.isDebt else { return }
        debt.settleDebt(in: context)
        try? context.save()
    }

    private func record(_ payment: IncomingPayment, debt: Expense?, in context: ModelContext,
                        notifies: Bool = true, note: String? = nil) {
        let name = FriendsManager.shared.friend(with: payment.debtor).name
        let source = ["Yape", "Plin"].contains(payment.via) ? payment.via : "Transferencia"

        guard let debt, debt.currency == payment.currency else {
            // El gasto ya no está (se borró) o está en otra moneda: igual es
            // plata que te llegó.
            let income = Income(amount: payment.amount, currency: payment.currency, source: source,
                                title: name, date: payment.paidAt,
                                notes: note ?? "Su parte de " + payment.merchant)
            context.insert(income)
            if notifies { notifyReceived(payment, from: name) }
            return
        }

        let outstanding = Accounting.outstanding(of: debt)
        let amount = min(Money.normalized(payment.amount), outstanding)
        if Money.cents(amount) > 0 {
            let cancels = Money.isZero(Money.subtract(outstanding, amount))
            // Si sí te llegó el correo del Yape recibido, ése es el ingreso:
            // se abona a la deuda en vez de crear otro.
            let income = Self.matchingEmailIncome(amount: amount, currency: payment.currency,
                                                  date: payment.paidAt, sender: name, in: context)
                ?? {
                    let created = Income(amount: amount, currency: payment.currency, source: source,
                                         title: name, date: payment.paidAt,
                                         notes: note ?? "Su parte de " + payment.merchant + " · lo detectó su teléfono")
                    context.insert(created)
                    return created
                }()
            income.debtReference = debt
            income.isFinalDebtPayment = cancels
            IncomeLinkStore.record(income: income, expense: debt, isFinal: cancels)
            if cancels {
                debt.isDebt = false
                ExpenseEditStore.record(debt, isDebt: false)
            }
        }

        // Todos pagaron su parte: lo que queda de la deuda es lo tuyo.
        if payment.allPaid, debt.isDebt {
            debt.settleDebt(in: context)
        }
        if notifies { notifyReceived(payment, from: name) }
    }

    /// Un ingreso del correo, todavía suelto, del mismo monto, ±2 días y de
    /// alguien que se llama parecido.
    private static func matchingEmailIncome(amount: Double, currency: String, date: Date,
                                            sender: String, in context: ModelContext) -> Income? {
        let from = date.addingTimeInterval(-2 * 86_400)
        let to = date.addingTimeInterval(2 * 86_400)
        let descriptor = FetchDescriptor<Income>(predicate: #Predicate { $0.date >= from && $0.date <= to })
        let incomes = (try? context.fetch(descriptor)) ?? []
        return incomes.first { income in
            income.emailID != nil && income.debtReference == nil && !income.isTransfer
                && income.currency == currency && Money.cents(income.amount) == Money.cents(amount)
                && DebtPaymentMatcher.namesMatch(payee: income.senderName ?? "", friend: [sender])
        }
    }

    private func notifyReceived(_ payment: IncomingPayment, from name: String) {
        notify(id: "debt-received-" + payment.id,
               title: "\(name) te pagó",
               body: Money.format(payment.amount, currency: payment.currency) + " · " + payment.merchant
                   + (payment.allPaid ? ". Ya te pagaron todos." : ""))
    }

    // MARK: - Guardado local

    /// Destinatario (`p:…`) → amigo. Sólo en este teléfono: es cómo **yo**
    /// reconozco a mi amigo en mis correos.
    private var links: [String: String] {
        get { (defaults.dictionary(forKey: Self.linksKey) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Self.linksKey) }
    }

    private var rejected: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.rejectedKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: Self.rejectedKey) }
    }

    /// Envío → `id` de la deuda que pagó, o "no" si no era un pago.
    private var handled: [String: String] {
        get { (defaults.dictionary(forKey: Self.handledKey) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Self.handledKey) }
    }

    private func markHandled(_ key: String, as value: String) {
        var current = handled
        current[key] = value
        handled = current
    }

    /// El amigo con el que vinculaste este destinatario, si lo hiciste.
    func linkedFriend(payeeKey: String) -> String? { links[payeeKey] }

    // MARK: - Avisos

    private func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Diagnostics.shared.log("Deudas: aviso no salió (\(error.localizedDescription))") }
        }
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
                ? "Falta correr agrupay_debts_v12_friend_payments.sql en Supabase."
                : (raw.isEmpty ? "Error \(http.statusCode)" : raw)
            Diagnostics.shared.log("Deudas: \(name) devolvió \(http.statusCode) · \(raw.prefix(300))")
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

    private static func share(from row: [String: Any]) -> OwedShare? {
        guard let id = row["id"] as? String, let creditor = row["creditor"] as? String,
              let amount = number(row["amount"]) else { return nil }
        return OwedShare(id: id, creditor: creditor,
                         debtKey: row["debt_key"] as? String ?? "",
                         merchant: row["merchant"] as? String ?? "Un gasto",
                         occurredOn: (row["occurred_on"] as? String).flatMap(dayFormatter.date(from:)),
                         amount: amount,
                         currency: row["currency"] as? String ?? "PEN",
                         paidAmount: number(row["paid_amount"]) ?? 0,
                         isPaid: ["paid", "forgiven"].contains(row["status"] as? String ?? ""),
                         createdAt: timestamp(row["created_at"]) ?? Date(),
                         paidAt: timestamp(row["paid_at"]),
                         isForgiven: row["status"] as? String == "forgiven",
                         closedAt: timestamp(row["closed_at"]))
    }

    private static func incoming(from row: [String: Any]) -> IncomingPayment? {
        guard let id = row["id"] as? String, let debtor = row["debtor"] as? String,
              let amount = number(row["amount"]) else { return nil }
        return IncomingPayment(id: id, debtor: debtor,
                               debtKey: row["debt_key"] as? String ?? "",
                               merchant: row["merchant"] as? String ?? "Un gasto",
                               amount: amount,
                               currency: row["currency"] as? String ?? "PEN",
                               paidAt: timestamp(row["paid_at"]) ?? Date(),
                               via: row["via"] as? String ?? "manual",
                               allPaid: row["all_paid"] as? Bool ?? false)
    }
}
