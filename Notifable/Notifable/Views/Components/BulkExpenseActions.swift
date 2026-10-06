import SwiftUI
import SwiftData

/// La barra flotante de la selección múltiple: Categorizar · Etiquetas ·
/// Eliminar. La misma en Pendientes y en Movimientos: una lista que se
/// selecciona igual se opera igual (antes sólo Pendientes podía corregir en
/// bloque, y eso obligaba a ir allí para arreglar gastos ya clasificados).
struct BulkActionBar: View {
    let count: Int
    var onCategorize: () -> Void
    var onTags: () -> Void
    var onDelete: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    // Tres botones sueltos, cada uno con su propia cápsula: dentro de una
    // cápsula común con uno relleno se leían como un control segmentado.
    var body: some View {
        HStack(spacing: 8) {
            barButton(icon: "square.grid.2x2", title: "Categorizar",
                      tint: .white, fill: accent.color, action: onCategorize)
                .accessibilityLabel("Categorizar \(count)")

            barButton(icon: "tag", title: "Etiquetar",
                      tint: palette.label, fill: palette.surface, action: onTags)
                .accessibilityLabel("Etiquetar \(count)")

            barButton(icon: "trash", title: "Eliminar",
                      tint: palette.negative, fill: palette.surface, action: onDelete)
                .accessibilityLabel(count == 1 ? "Eliminar el movimiento elegido"
                                               : "Eliminar los \(count) movimientos elegidos")
        }
        .padding(.horizontal, ShellMetrics.sideInset)
    }

    private func barButton(icon: String, title: String, tint: Color, fill: Color,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(fill, in: Capsule())
            .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
            .contentShape(Capsule())
            .shadow(color: Color.black.opacity(0.12), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
    }
}

/// La casilla redonda de la selección: vacía, con guion (parte de un grupo)
/// o marcada.
struct SelectionCheck: View {
    enum State { case off, partial, on }

    let state: State
    var size: CGFloat = 24

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    var body: some View {
        let filled = state != .off
        ZStack {
            Circle()
                .strokeBorder(filled ? accent.buttonFill : palette.hairline, lineWidth: filled ? 0 : 1.5)
                .background(Circle().fill(filled ? accent.buttonFill : Color.clear))
                .frame(width: size, height: size)

            if filled {
                Image(systemName: state == .on ? "checkmark" : "minus")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(accent.buttonText)
            }
        }
    }
}

/// Lo que hacen las tres acciones sobre los gastos elegidos, sin vista:
/// Pendientes y Movimientos sólo deciden qué está elegido.
enum BulkExpenseEdit {

    /// Las etiquetas que tienen **todos** los elegidos: son las que el
    /// selector marca. Una que sólo tienen algunos sale apagada, y tocarla se
    /// la pone al resto.
    static func commonTags(_ chosen: [Expense]) -> [String] {
        guard let first = chosen.first else { return [] }
        return first.tags.filter { tag in
            let key = TagCatalog.normalized(tag)
            return chosen.allSatisfy { $0.hasTag(key) }
        }
    }

    /// Si todos la tienen, se quita a todos; si no, se pone a los que les
    /// falta (y tienen hueco: el tope por movimiento sigue valiendo).
    static func toggleTag(_ name: String, on chosen: [Expense], in context: ModelContext) {
        let key = TagCatalog.normalized(name)
        guard !key.isEmpty, !chosen.isEmpty else { return }
        let everyoneHasIt = chosen.allSatisfy { $0.hasTag(key) }
        withAnimation(.snappy(duration: 0.2)) {
            for expense in chosen where expense.hasTag(key) == everyoneHasIt {
                expense.toggleTag(name, in: context)
            }
        }
    }

    /// Una parte de una división no se borra suelta: se deshace la división.
    static func deletable(_ chosen: [Expense]) -> [Expense] {
        chosen.filter { $0.splitOf == nil }
    }

    static func deleteTitle(selected: Int, deletable: Int) -> String {
        if deletable == 0 {
            return selected == 1 ? "Esta parte no se borra sola" : "Estas partes no se borran solas"
        }
        return deletable == 1 ? "¿Eliminar 1 movimiento?" : "¿Eliminar \(deletable) movimientos?"
    }

    static func deleteMessage(selected: Int, deletable: Int) -> String {
        let skipped = selected - deletable
        if deletable == 0 {
            return "Es parte de un pago dividido. Para quitarla, abre el pago y usa «Deshacer división»."
        }
        var text = "Se borrarán de tus cuentas. Los que vinieron de un correo se pueden recuperar desde «Leer un rango pasado»."
        if skipped > 0 {
            text += skipped == 1 ? " Una parte de una división se queda: se quita deshaciendo la división."
                                 : " \(skipped) partes de divisiones se quedan: se quitan deshaciendo la división."
        }
        return text
    }

    static func delete(_ targets: [Expense], in context: ModelContext) {
        for expense in targets { expense.deleteRecordingRecovery(in: context) }
    }

    /// Categorizar desde una selección que no es de Pendientes: sin reglas
    /// (se mezclan comercios y gastos ya clasificados; una regla ahí sería
    /// una sorpresa).
    static func assign(_ category: String, to chosen: [Expense], in context: ModelContext) {
        Analytics.classified(chosen.map { ($0.id, $0.category) }, to: category, via: .selection)
        for expense in chosen {
            expense.category = category
            ExpenseEditStore.record(expense, category: category)
        }
        try? context.save()
    }

    /// El encabezado de la hoja de categoría para una selección suelta.
    static func context(for chosen: [Expense], rate: Double) -> AssignCategoryContext {
        let total = Money.sum(chosen) { Accounting.netCostInPEN($0, fallbackRate: rate) }
        let merchants = Set(chosen.map(\.merchant))
        let count = chosen.count == 1 ? "1 movimiento" : "\(chosen.count) movimientos"
        // Corto: el título comparte línea con el monto.
        let title = merchants.count == 1 ? Accounting.displayName(merchants.first ?? "") : count
        var context = AssignCategoryContext.selection(title: title, amount: total)
        context.subtitle = merchants.count == 1 ? count : "De \(merchants.count) comercios"
        // Si todos ya comparten categoría, llega marcada.
        let categories = Set(chosen.map(\.category))
        if categories.count == 1, let only = categories.first, only != Accounting.unclassified {
            context.current = only
        }
        return context
    }
}
