import Foundation
import SwiftData

/// «Compartir gasto»: una sola deuda, siempre con persona.
///
/// Compartir un gasto guarda tu parte en el gasto (`Expense.ownShare`, que es
/// lo único que suma a tu mes) y crea una deuda por persona: en el servidor
/// para tus amigos (`share_expense`, v17) y en este teléfono para quien no
/// tiene la app (`OfflineDebts`). Anotar y avisar son pasos distintos:
/// `notify` decide si además se les manda el recordatorio.
@MainActor
@Observable
final class ExpenseSharing {

    static let shared = ExpenseSharing()

    private var container: ModelContainer?
    private var context: ModelContext? { container?.mainContext }

    func start(container: ModelContainer) {
        self.container = container
    }

    /// Resultado de guardar: a quién hay que escribirle por WhatsApp (los
    /// que no tienen la app) si se pidió avisar.
    struct Outcome {
        var failed: String?
        var whatsApp: [ReceivableShare] = []
        var notifiedFriends: Int = 0
    }

    /// - Parameters:
    ///   - amounts: persona (`Friend.id` o `OfflineContact.personID`) → monto.
    ///   - mine: tu parte. `amounts` + `mine` = el importe del gasto.
    func share(_ expense: Expense, mine: Double, amounts: [String: Double], notify: Bool) async -> Outcome {
        let debtKey = TransactionKey.key(for: expense)
        let merchant = Accounting.displayName(expense.merchant)
        let friends = amounts.filter { !OfflineDebts.isContact($0.key) && Money.cents($0.value) > 0 }
        let contacts = amounts.filter { OfflineDebts.isContact($0.key) && Money.cents($0.value) > 0 }
        let receivables = FriendReceivables.shared

        // Al servidor sólo si hay amigos ahora o los había antes (para sacar
        // a quien ya no está).
        let hadFriends = receivables.serverShares.contains { $0.debtKey == debtKey }
        if !friends.isEmpty || hadFriends {
            let saved = await receivables.saveShares(debtKey: debtKey, merchant: merchant,
                                                     occurredOn: expense.date, currency: expense.currency,
                                                     amounts: friends)
            guard saved else {
                return Outcome(failed: receivables.lastErrorMessage ?? "No se pudo guardar. Revisa tu conexión.")
            }
        }
        OfflineDebts.shared.setShares(
            debtKey: debtKey, merchant: merchant, occurredOn: expense.date, currency: expense.currency,
            amounts: Dictionary(uniqueKeysWithValues: contacts.map {
                (String($0.key.dropFirst(OfflineDebts.personPrefix.count)), $0.value)
            }))

        let others = Money.sum(Array(amounts.values))
        if Money.cents(others) == 0 {
            // Nadie más: deja de ser compartido.
            expense.ownShare = nil
            expense.forgivenAmount = 0
            expense.isDebt = false
        } else {
            expense.ownShare = Money.normalized(mine)
            expense.debtSettled = false
            expense.isDebt = Money.cents(Accounting.outstanding(of: expense)) > 0
        }
        ExpenseShareStore.record(expense)
        ExpenseEditStore.record(expense, isDebt: expense.isDebt, debtSettled: expense.debtSettled)
        if let context {
            try? context.save()
            Expense.refreshDebtNotification(in: context)
        }

        var outcome = Outcome()
        guard notify else { return outcome }

        if !friends.isEmpty {
            let result = await PaymentReminders.shared.send(
                debtKey: debtKey, merchant: merchant, occurredOn: expense.date,
                currency: expense.currency, message: "", intensity: .soft,
                to: Array(friends.keys), amounts: friends)
            outcome.notifiedFriends = result.delivered
            await receivables.refresh()
        }
        outcome.whatsApp = receivables.shares(forDebtKey: debtKey).filter { $0.isContact && $0.isOpen }
        return outcome
    }

    /// «Repartir después»: queda en Cobros › Falta repartir hasta que se
    /// elija con quién.
    func markForLater(_ expense: Expense) {
        guard let context, !expense.isShared else { return }
        expense.toggleDebt(in: context)
    }

    /// Lo perdonado pasa a ser gasto tuyo. Si ya no queda nada abierto, el
    /// cobro de ese gasto se cierra.
    func addForgiven(_ amount: Double, debtKey: String, closes: Bool) {
        guard let context, let expense = self.expense(forKey: debtKey) else { return }
        if expense.isShared {
            expense.forgivenAmount = Money.normalized(expense.forgivenAmount + amount)
            ExpenseShareStore.record(expense)
        }
        if closes || Money.cents(Accounting.outstanding(of: expense)) == 0 {
            expense.settleDebt(in: context)
        } else {
            try? context.save()
        }
    }

    /// Lo marcado «por cobrar» antes de esta versión que ya tenía deudas con
    /// monto en el servidor (de un recordatorio): su parte se deduce de las
    /// deudas, así deja de figurar como «Falta repartir».
    func reconcileLegacy() {
        guard let context else { return }
        let shares = FriendReceivables.shared.shares
        guard !shares.isEmpty else { return }
        let descriptor = FetchDescriptor<Expense>(predicate: #Predicate { $0.isDebt == true })
        let debts = ((try? context.fetch(descriptor)) ?? []).filter(\.needsSplitting)
        var touched = false
        for expense in debts {
            let keys = Set(TransactionKey.lookupKeys(for: expense))
            let mine = shares.filter { keys.contains($0.debtKey) && $0.currency == expense.currency }
            guard !mine.isEmpty else { continue }
            let others = Money.sum(mine) { $0.amount }
            expense.ownShare = Money.clampedToZero(Money.subtract(expense.amount, others))
            expense.forgivenAmount = Money.sum(mine.filter { $0.status == .forgiven }) { $0.remaining }
            expense.isDebt = mine.contains(where: \.isOpen)
            ExpenseShareStore.record(expense)
            ExpenseEditStore.record(expense, isDebt: expense.isDebt)
            touched = true
        }
        if touched { try? context.save() }
    }

    /// Deudas cuyo gasto ya no existe: se borró antes de que borrar un gasto
    /// limpiara sus deudas. Se borran en el servidor —también desaparecen del
    /// lado del amigo— sólo cuando es seguro que el gasto se borró:
    ///
    /// - anotado a mano (`fp:`): vive en este teléfono y en su respaldo; si el
    ///   teléfono ya leyó el correo alguna vez y tiene gastos, que no esté es
    ///   que se borró (un teléfono recién instalado sin restaurar no limpia);
    /// - del correo (`mail:`): sólo si su correo está entre los borrados a
    ///   mano. Uno más viejo que el rango de lectura no se toca.
    func cleanOrphans() async {
        guard let context, !isCleaning else { return }
        let keys = Set(FriendReceivables.shared.shares.map(\.debtKey))
        guard !keys.isEmpty else { return }
        let expenses = (try? context.fetch(FetchDescriptor<Expense>())) ?? []
        let readMailOnce = UserDefaults.standard.object(forKey: "lastSyncDate") != nil
        guard !expenses.isEmpty, readMailOnce else { return }
        let known = TransactionKey.expensesByLookupKey(expenses)
        let deletedMail = Set(UserDefaults.standard.stringArray(forKey: "pendingRecoveryIDs") ?? [])

        let orphans = keys.filter { key in
            guard known[key] == nil else { return false }
            if key.hasPrefix("fp:") { return true }
            if key.hasPrefix("mail:") { return deletedMail.contains(String(key.dropFirst(5))) }
            return false
        }
        guard !orphans.isEmpty else { return }
        isCleaning = true
        defer { isCleaning = false }
        for key in orphans {
            Diagnostics.shared.log("Cobros: deuda sin gasto (\(key)), se borra")
            await FriendReceivables.shared.deleteDebts(debtKey: key)
        }
    }

    private var isCleaning = false

    func expense(forKey key: String) -> Expense? {
        guard let context else { return nil }
        let expenses = (try? context.fetch(FetchDescriptor<Expense>())) ?? []
        return TransactionKey.expensesByLookupKey(expenses)[key]
    }
}
