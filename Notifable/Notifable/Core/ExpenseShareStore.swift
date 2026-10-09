import Foundation
import SwiftData

/// Tu parte y lo perdonado de cada gasto compartido, por `TransactionKey`.
///
/// Igual que `ExpenseEditStore`: los gastos del correo se borran y se rearman
/// en cada relectura, así que lo que decidiste al compartir vive aparte, en
/// `UserDefaults`, y se vuelve a aplicar (`apply`). A diferencia de aquél,
/// guarda también los gastos anotados a mano (las partes de un pago separado
/// por categoría se comparten): es un solo sitio para las dos clases.
///
/// Viaja en el respaldo dentro del blob de preferencias
/// (`ConfigBackupManager.decisionExtras`).
enum ExpenseShareStore {

    struct Entry: Codable, Equatable {
        var key: String
        var ownShare: Double
        var forgiven: Double
        var updatedAt: Date
    }

    static let key = "expenseShares"

    static func all(_ defaults: UserDefaults = .standard) -> [String: Entry] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { $1 })
    }

    static func list(_ defaults: UserDefaults = .standard) -> [Entry] {
        all(defaults).values.sorted { $0.key < $1.key }
    }

    /// Anota lo que el gasto tiene ahora. Sin `ownShare` (se dejó de
    /// compartir) borra la entrada.
    static func record(_ expense: Expense, defaults: UserDefaults = .standard) {
        var current = all(defaults)
        let key = TransactionKey.key(for: expense)
        if let own = expense.ownShare {
            current[key] = Entry(key: key, ownShare: own, forgiven: expense.forgivenAmount, updatedAt: Date())
        } else {
            current[key] = nil
        }
        persist(current, defaults: defaults)
    }

    static func rekey(from old: String, to new: String, defaults: UserDefaults = .standard) {
        var current = all(defaults)
        guard var entry = current.removeValue(forKey: old), old != new else { return }
        entry.key = new
        entry.updatedAt = Date()
        current[new] = entry
        persist(current, defaults: defaults)
    }

    /// Lo que llega de un respaldo: gana lo más reciente de cada gasto.
    static func merge(_ incoming: [Entry], defaults: UserDefaults = .standard) {
        var current = all(defaults)
        for entry in incoming where (current[entry.key]?.updatedAt ?? .distantPast) < entry.updatedAt {
            current[entry.key] = entry
        }
        persist(current, defaults: defaults)
    }

    @discardableResult
    static func apply(in modelContext: ModelContext, defaults: UserDefaults = .standard) -> Int {
        let entries = all(defaults)
        guard !entries.isEmpty else { return 0 }
        let expenses = (try? modelContext.fetch(FetchDescriptor<Expense>())) ?? []
        var applied = 0
        for expense in expenses {
            guard let entry = TransactionKey.lookupKeys(for: expense).lazy.compactMap({ entries[$0] }).first
            else { continue }
            var touched = false
            if expense.ownShare.map(Money.cents) != Money.cents(entry.ownShare) {
                expense.ownShare = entry.ownShare; touched = true
            }
            if Money.cents(expense.forgivenAmount) != Money.cents(entry.forgiven) {
                expense.forgivenAmount = entry.forgiven; touched = true
            }
            if touched { applied += 1 }
        }
        if applied > 0 { try? modelContext.save() }
        return applied
    }

    private static func persist(_ entries: [String: Entry], defaults: UserDefaults) {
        let list = entries.values.sorted { $0.key < $1.key }
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
    }
}
