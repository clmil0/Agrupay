import Foundation
import SwiftData

/// Una parte tal como sale del editor (`SplitExpenseSheet`).
struct SplitPart: Equatable {
    var amount: Double
    var category: String
    var tags: [String]
}

/// Dividir un gasto en partes relacionadas (`2a`–`2d`).
///
/// Un Yape de S/ 150 que en realidad fueron S/ 100 de supermercado y S/ 50 de
/// almuerzo se parte en **gastos hijos**: cada uno con su categoría y sus
/// etiquetas, y cada uno cuenta en su límite. El pago original deja de sumar
/// (`isSplit` → `ExpenseSnapshot.isVoided`) y queda como referencia.
///
/// Las partes son gastos de verdad, no un adorno del original: así las ven sin
/// cambios los totales, los límites, las etiquetas, el detalle de categoría y
/// los widgets. Se crean sin correo detrás, de modo que se respaldan enteras
/// (`ManualTransactionBackup`) y sobreviven a «Volver a leer el correo desde
/// cero». Apuntan a su pago por `TransactionKey`, la misma llave con la que
/// las ediciones encuentran un gasto que se rearmó con otro `UUID`.
enum ExpenseSplit {

    /// Se puede dividir: suma como gasto (o ya está dividido), no es a su vez
    /// una parte y no lleva un cobro encima —lo que te devuelven es del pago
    /// entero, y repartirlo entre las partes no tendría una respuesta obvia—.
    static func canSplit(_ expense: Expense) -> Bool {
        guard expense.splitOf == nil else { return false }
        guard expense.isSplit || expense.countsAsSpending else { return false }
        // Primero se separa y luego se comparte cada parte: uno ya compartido
        // no se separa.
        guard !expense.isShared else { return false }
        return !expense.isDebt && !expense.debtSettled
            && (expense.payments ?? []).isEmpty
            && Money.cents(expense.amount) >= 2
    }

    // MARK: - Leer

    /// Las partes de un pago, en orden, entre gastos ya cargados.
    static func parts(of parent: Expense, among expenses: [Expense]) -> [Expense] {
        let keys = TransactionKey.lookupKeys(for: parent)
        return expenses
            .filter { $0.splitOf.map(keys.contains) == true }
            .sorted(by: order)
    }

    static func parts(of parent: Expense, in context: ModelContext) -> [Expense] {
        parts(of: parent, among: allParts(in: context))
    }

    /// Todas las partes, agrupadas por la llave de su pago.
    static func partsByParent(_ expenses: [Expense]) -> [String: [Expense]] {
        Dictionary(grouping: expenses.filter { $0.splitOf != nil }, by: { $0.splitOf ?? "" })
            .mapValues { $0.sorted(by: order) }
    }

    /// Las partes de un pago en un índice ya armado (`partsByParent`).
    static func parts(of parent: Expense, in index: [String: [Expense]]) -> [Expense] {
        for key in TransactionKey.lookupKeys(for: parent) {
            if let found = index[key] { return found }
        }
        return []
    }

    /// El pago del que salió una parte, entre gastos ya cargados.
    static func parent(of part: Expense, among expenses: [Expense]) -> Expense? {
        guard let key = part.splitOf else { return nil }
        if key.hasPrefix("mail:") {
            let id = String(key.dropFirst(5))
            return expenses.first { $0.emailID == id }
                ?? expenses.first { $0.relatedEmailID == id && $0.emailID != nil }
        }
        // Sólo los anotados a mano tienen llave `fp:`; calcularla es un hash,
        // así que no se calcula para todo el historial.
        return expenses.first { $0.emailID == nil && $0.splitOf == nil && TransactionKey.key(for: $0) == key }
    }

    /// El pago del que salió una parte.
    static func parent(of part: Expense, in context: ModelContext) -> Expense? {
        guard let key = part.splitOf else { return nil }
        if key.hasPrefix("mail:") {
            let id = String(key.dropFirst(5))
            let descriptor = FetchDescriptor<Expense>(predicate: #Predicate {
                $0.emailID == id || $0.relatedEmailID == id
            })
            let found = (try? context.fetch(descriptor)) ?? []
            return found.first { $0.emailID == id } ?? found.first
        }
        let descriptor = FetchDescriptor<Expense>(predicate: #Predicate {
            $0.emailID == nil && $0.splitOf == nil
        })
        return ((try? context.fetch(descriptor)) ?? []).first { TransactionKey.key(for: $0) == key }
    }

    // MARK: - Escribir

    /// Divide el pago —o rehace su división— en `parts`.
    ///
    /// Las partes que ya existían se **reutilizan** por orden en vez de
    /// borrarse y crearse otra vez: una parte puede estar marcada por cobrar,
    /// con abonos atados a ella, y rehacer la división no debería soltarlos.
    @discardableResult
    static func apply(_ parts: [SplitPart], to parent: Expense, in context: ModelContext) -> Bool {
        guard parts.count >= 2,
              parts.allSatisfy({ Money.cents($0.amount) > 0 }),
              parts.reduce(0, { $0 + Money.cents($1.amount) }) == Money.cents(parent.amount)
        else { return false }

        let key = TransactionKey.key(for: parent)
        var existing = self.parts(of: parent, in: context)
        var created: [Expense] = []

        for (index, part) in parts.enumerated() {
            let child: Expense
            if !existing.isEmpty {
                child = existing.removeFirst()
            } else {
                child = Expense(amount: part.amount,
                                merchant: parent.merchant,
                                date: parent.date,
                                category: part.category,
                                currency: parent.currency,
                                emailID: nil,
                                cardLastDigits: parent.cardLastDigits,
                                fxRateAtCapture: parent.fxRateAtCapture)
                // El origen del pago: la parte sale de la misma cuenta, así que
                // el filtro de cuentas la encuentra donde al pago.
                child.sourceBank = parent.sourceBank
                child.cardKind = parent.cardKind
                child.payeePhone = parent.payeePhone
                context.insert(child)
                created.append(child)
            }
            child.amount = Money.normalized(part.amount)
            child.category = part.category
            child.tags = Array(part.tags.compactMap { TagCatalog.shared.use($0) }
                .prefix(TagCatalog.maxPerExpense))
            child.splitOf = key
            child.splitIndex = index
        }
        // Las que sobran: la división tiene ahora menos partes.
        for leftover in existing { context.delete(leftover) }

        parent.isSplit = true
        try? context.save()

        // Las partes son nuevas para la base, no para el usuario: acaba de
        // crearlas. Sin esto Movimientos las resaltaría como recién llegadas.
        NewMovements.shared.markSeen(Set(created.compactMap(NewMovements.key)))
        return true
    }

    /// Deshace la división: borra las partes y el pago vuelve a sumar entero.
    static func undo(_ parent: Expense, in context: ModelContext) {
        for part in parts(of: parent, in: context) { context.delete(part) }
        parent.isSplit = false
        try? context.save()
    }

    /// Un pago anotado a mano cambió de comercio, monto o fecha: su llave
    /// (`fp:…`) cambió con él, y sus partes tienen que seguir encontrándolo.
    /// La de un gasto del correo no cambia nunca (`mail:…`).
    static func rekey(from old: String, to new: String, in context: ModelContext) {
        guard old != new else { return }
        let descriptor = FetchDescriptor<Expense>(predicate: #Predicate { $0.splitOf == old })
        let parts = (try? context.fetch(descriptor)) ?? []
        guard !parts.isEmpty else { return }
        for part in parts { part.splitOf = new }
        try? context.save()
    }

    /// Deja `isSplit` de acuerdo con las partes que existen.
    ///
    /// Al releer el correo el pago se rearma sin la marca, y al restaurar en
    /// un teléfono nuevo las partes llegan antes que el correo: aquí el pago
    /// la recupera en cuanto aparece. Y al revés, un pago cuyas partes ya no
    /// existen vuelve a sumar entero. Barata e idempotente: corre junto a
    /// `ExpenseEditStore.apply`.
    @discardableResult
    static func reconcile(in context: ModelContext) -> Int {
        let referenced = Set(allParts(in: context).compactMap(\.splitOf))
        let flagged = FetchDescriptor<Expense>(predicate: #Predicate { $0.isSplit == true })
        if referenced.isEmpty, ((try? context.fetchCount(flagged)) ?? 0) == 0 { return 0 }

        let candidates = (try? context.fetch(FetchDescriptor<Expense>(predicate: #Predicate {
            $0.splitOf == nil
        }))) ?? []
        var changed = 0
        for expense in candidates {
            let should = TransactionKey.lookupKeys(for: expense).contains(where: referenced.contains)
            if expense.isSplit != should {
                expense.isSplit = should
                changed += 1
            }
        }
        if changed > 0 { try? context.save() }
        return changed
    }

    // MARK: - Privado

    private static func allParts(in context: ModelContext) -> [Expense] {
        (try? context.fetch(FetchDescriptor<Expense>(predicate: #Predicate { $0.splitOf != nil }))) ?? []
    }

    private static func order(_ lhs: Expense, _ rhs: Expense) -> Bool {
        lhs.splitIndex == rhs.splitIndex
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.splitIndex < rhs.splitIndex
    }
}
