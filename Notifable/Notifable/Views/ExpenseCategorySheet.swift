import SwiftUI
import SwiftData

/// Asignar —o quitar— la categoría de **un** gasto. La misma hoja desde su
/// detalle y desde la pulsación larga de su fila: antes cada sitio armaba la
/// suya y sólo el detalle ofrecía «Quitar categoría».
struct ExpenseCategorySheet: View {
    let expense: Expense

    @Environment(\.modelContext) private var modelContext
    /// Se consulta aquí y no en quien la abre: una fila no debería cargar el
    /// historial entero sólo por si alguien la mantiene presionada.
    @Query private var history: [Expense]

    var body: some View {
        AssignCategorySheet(context: .expense(expense),
                            history: history,
                            onClear: {
            // Vuelve a Pendientes. También se anota, o la relectura
            // del correo le devolvería la categoría que tenía.
            if expense.category != Accounting.unclassified {
                Analytics.track(.movementUnclassified, ["via": "detail"])
                _ = ClassificationLedger.take(expense.id)
            }
            expense.category = Accounting.unclassified
            ExpenseEditStore.record(expense, category: Accounting.unclassified)
            try? modelContext.save()
        }) { newCategory, createRule in
            Analytics.classified([(expense.id, expense.category)], to: newCategory,
                                 via: .detail, ruleCreated: createRule)
            if createRule { Analytics.ruleCreated(origin: "detail") }
            expense.category = newCategory
            // Se anota aunque haya regla: la regla sólo mira hacia
            // adelante, y sin la anotación la próxima relectura del
            // correo devolvería este gasto a su categoría original.
            ExpenseEditStore.record(expense, category: newCategory)
            if createRule {
                // Sólo para lo que llegue: el historial del comercio
                // se reclasifica desde Pendientes, no desde aquí.
                MerchantRules.set(newCategory, for: expense.merchant)
            }
            try? modelContext.save()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }
}
