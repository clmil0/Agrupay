import SwiftUI
import SwiftData

/// Ajustes → Recurrentes y atajos.
struct RecurringManagementView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    @AppStorage(BudgetStore.monthlyBudgetKey) private var monthlyBudget: Double = 0
    @AppStorage(BudgetStore.enabledKey) private var budgetEnabled = true

    @Query(sort: \RecurringExpense.createdAt, order: .reverse) private var rules: [RecurringExpense]
    @Query(sort: \QuickExpense.sortIndex) private var quickExpenses: [QuickExpense]

    @StateObject private var exchangeRateService = ExchangeRateService.shared

    /// Qué abre el editor de atajos: uno nuevo o el que se tocó. Con
    /// `sheet(item:)` el atajo viaja con la presentación; con `isPresented`
    /// más un estado aparte, el primer toque podía abrir "Nuevo atajo".
    @State private var quickSheet: QuickSheet?
    /// Reordenar sólo en modo edición: con `onMove` siempre activo, mantener
    /// presionada una fila la levantaba para arrastrarla y se veía desfasada.
    @State private var isReorderingQuick = false
    @State private var ruleToDelete: RecurringExpense?
    /// El recurrente que se tocó: abre su editor, con pausar y eliminar
    /// dentro, igual que un atajo.
    @State private var editingRule: RecurringExpense?
    @State private var tab: Tab = .rules

    private enum Tab: Hashable { case rules, quick }

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        trackedBody.trackScreen("recurring", feature: .recurring)
    }

    /// El `body` de siempre; `body` lo envuelve para contarlo como pantalla.
    @ViewBuilder private var trackedBody: some View {
        Group {
            if tab == .quick && isReorderingQuick {
                // Reordenar necesita `List` y su `onMove`; fuera de ese modo,
                // la pantalla es la de tarjetas del rediseño.
                List { quickSection }
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        commitmentCard

                        ShellSegment(items: [Tab.rules, .quick], selection: $tab) {
                            $0 == .rules ? "Activos · \(activeCount)" : "Atajos · \(quickExpenses.count)"
                        }

                        if tab == .rules {
                            rulesCard
                            quickGrid
                        } else {
                            quickListCard
                        }
                    }
                    .padding(16)
                }
                .background(palette.background)
            }
        }
        .navigationTitle("Recurrentes y atajos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    quickSheet = .new
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Nuevo atajo")
            }
        }
        .environment(\.editMode, .constant(isReorderingQuick ? .active : .inactive))
        .sheet(item: $quickSheet) { sheet in
            QuickExpenseEditor(quick: sheet.quick)
        }
        .sheet(item: $editingRule) { rule in
            RecurringExpenseEditor(rule: rule)
        }
        // Alerta centrada: el `confirmationDialog` se anclaba a la lista
        // entera y aparecía desfasado, lejos de la fila.
        .alert("¿Eliminar esta programación?", isPresented: deleteDialogBinding) {
            Button("Eliminar", role: .destructive) {
                if let rule = ruleToDelete { modelContext.delete(rule) }
                try? modelContext.save()
                ruleToDelete = nil
            }
            Button("Cancelar", role: .cancel) { ruleToDelete = nil }
        } message: {
            Text("Se eliminará la programación. Los gastos ya registrados se conservan.")
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { ruleToDelete != nil }, set: { if !$0 { ruleToDelete = nil } })
    }


    // MARK: - Compromiso mensual

    private var committed: Double {
        RecurringEngine.monthlyCommitted(rules: rules, usdToPen: exchangeRateService.usdToPenRate)
    }

    private var activeCount: Int { rules.filter { !$0.isPaused }.count }

    @ViewBuilder
    private var commitmentCard: some View {
        if !Money.isZero(committed) {
            ShellCard(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("COMPROMETIDO CADA MES")
                        .font(.system(size: 11.5, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(palette.secondaryLabel)
                    Text(Money.format(committed))
                        .font(.system(size: 36, weight: .bold))
                        .tracking(-1)
                        .foregroundStyle(palette.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    categoryBar
                    if let share = budgetShare {
                        Text(share)
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Barra segmentada por categoría: de dónde sale ese compromiso.
    private var categoryBar: some View {
        let segments = commitmentByCategory
        let total = Money.cents(committed)

        return GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(segments, id: \.category) { segment in
                    let fraction = total > 0 ? Double(Money.cents(segment.amount)) / Double(total) : 0
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(CategoryStyle.color(for: segment.category, accent: accent.color))
                        .frame(width: max(2, geo.size.width * CGFloat(fraction)))
                }
            }
        }
        .frame(height: 8)
    }

    private var commitmentByCategory: [(category: String, amount: Double)] {
        var cents: [String: Int] = [:]
        for rule in rules where !rule.isPaused {
            cents[rule.category, default: 0] += Money.cents(rule.monthlyEquivalent)
        }
        return cents
            .map { (category: $0.key, amount: Money.value($0.value)) }
            .sorted { Money.cents($0.amount) > Money.cents($1.amount) }
    }

    /// Sin presupuesto no se inventa el porcentaje.
    private var budgetShare: String? {
        guard BudgetStore.hasBudget(monthlyBudget: monthlyBudget, enabled: budgetEnabled),
              let percent = Money.percent(committed, of: monthlyBudget) else { return nil }
        return "\(Int(percent.rounded()))% de tu presupuesto sale solo, antes de que decidas nada."
    }

    // MARK: - Reglas

    /// Las pausadas al final: siguen existiendo, pero no proponen nada.
    private var sortedRules: [RecurringExpense] {
        rules.sorted { lhs, rhs in
            if lhs.isPaused != rhs.isPaused { return !lhs.isPaused }
            return (lhs.nextOccurrence ?? .distantFuture) < (rhs.nextOccurrence ?? .distantFuture)
        }
    }

    @ViewBuilder
    private var rulesCard: some View {
        if rules.isEmpty {
            ShellEmptyState(icon: "arrow.triangle.2.circlepath",
                            title: "Nada programado todavía",
                            message: "Al registrar un gasto, usa «Repetir» y aparecerá aquí.")
        } else {
            MovementCard {
                ForEach(Array(sortedRules.enumerated()), id: \.element.id) { index, rule in
                    Button { editingRule = rule } label: {
                        cardRuleRow(rule)
                    }
                    .buttonStyle(.plain)
                    // Sin `List` no hay deslizar: pausar y eliminar viven en el
                    // menú contextual y dentro del editor.
                    .contextMenu {
                        Button { togglePause(rule) } label: {
                            Label(rule.isPaused ? "Reanudar" : "Pausar",
                                  systemImage: rule.isPaused ? "play.fill" : "pause.fill")
                        }
                        Button(role: .destructive) { ruleToDelete = rule } label: {
                            Label("Eliminar", systemImage: "trash")
                        }
                    }
                    if index < sortedRules.count - 1 { MovementSeparator() }
                }
            }
        }
    }

    /// Cada fila declara si se registra sola o pide confirmación (`5g`).
    private func cardRuleRow(_ rule: RecurringExpense) -> some View {
        HStack(spacing: 12) {
            MovementIcon(icon: rule.isPaused ? "pause.fill" : CategoryStyle.icon(for: rule.category),
                         color: rule.isPaused ? palette.tertiaryLabel
                                              : CategoryStyle.color(for: rule.category, accent: accent.color),
                         size: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(Accounting.displayName(rule.merchant))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(rule.isPaused ? palette.secondaryLabel : palette.label)
                    .lineLimit(1)
                Text(ruleSubtitle(rule))
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.format(rule.amount, currency: rule.currency))
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(rule.isPaused ? palette.secondaryLabel : palette.label)
                if !rule.isPaused {
                    Label(rule.autoConfirm ? "automático" : "confirmar",
                          systemImage: rule.autoConfirm ? "checkmark.circle" : "clock")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(rule.autoConfirm ? palette.positive : palette.warning)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    // MARK: - Atajos en rejilla

    /// Los tres que salen en el `+`, con cuántas veces se usaron: es lo que
    /// dice cuáles vale la pena tener arriba.
    @ViewBuilder
    private var quickGrid: some View {
        if !quickExpenses.isEmpty {
            VStack(spacing: 8) {
                ShellSectionHeader(title: "Atajos · un toque en el +")
                HStack(spacing: 8) {
                    ForEach(quickExpenses.prefix(3)) { quick in
                        Button { quickSheet = .edit(quick) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Image(systemName: quick.iconName)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(accent.color)
                                Text(quick.label)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(palette.label)
                                    .lineLimit(1)
                                Text(Money.format(quick.amount, currency: quick.currency))
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(palette.secondaryLabel)
                                Text("usado \(quick.useCount) " + (quick.useCount == 1 ? "vez" : "veces"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(palette.tertiaryLabel)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(palette.hairline, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var quickListCard: some View {
        if quickExpenses.isEmpty {
            ShellEmptyState(icon: "bolt",
                            title: "Ningún atajo todavía",
                            message: "Toca + arriba para crear uno: el pasaje o el café de siempre, en un toque.")
        } else {
            VStack(spacing: 8) {
                HStack {
                    Spacer()
                    if quickExpenses.count > 1 {
                        Button("Ordenar") { withAnimation { isReorderingQuick = true } }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent.onSurface(scheme))
                    }
                }
                MovementCard {
                    ForEach(Array(quickExpenses.enumerated()), id: \.element.id) { index, quick in
                        Button { quickSheet = .edit(quick) } label: {
                            quickRow(quick)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < quickExpenses.count - 1 { MovementSeparator() }
                    }
                }
                Text("Los tres primeros aparecen al registrar un gasto.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
        }
    }

    private func ruleSubtitle(_ rule: RecurringExpense) -> String {
        if rule.isPaused { return "En pausa" }
        var parts = [rule.scheduleLabel]
        if rule.autoConfirm {
            parts.append("automático")
        } else if let next = rule.nextOccurrence {
            let f = DateFormatter()
            f.locale = Locale(identifier: "es_ES")
            f.dateFormat = "d MMM"
            parts.append("próximo " + f.string(from: next))
        }
        return parts.joined(separator: " · ")
    }

    private func togglePause(_ rule: RecurringExpense) {
        withAnimation {
            rule.isPaused.toggle()
            try? modelContext.save()
        }
    }

    // MARK: - Atajos

    @ViewBuilder
    private var quickSection: some View {
        Section {
            if quickExpenses.isEmpty {
                Text("Ningún atajo todavía.")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryLabel)
            } else {
                ForEach(quickExpenses) { quick in
                    Button {
                        guard !isReorderingQuick else { return }
                        quickSheet = .edit(quick)
                    } label: {
                        quickRow(quick)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .onMove(perform: isReorderingQuick ? move : nil)
            }
        } header: {
            HStack {
                Text("Atajos")
                Spacer()
                if quickExpenses.count > 1 {
                    Button(isReorderingQuick ? "Listo" : "Ordenar") {
                        withAnimation { isReorderingQuick.toggle() }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(accent.onSurface(scheme))
                    .textCase(nil)
                }
            }
        } footer: {
            Text("Los tres primeros aparecen en el modal de gasto. Toca uno para editarlo o eliminarlo.")
        }
    }

    private func quickRow(_ quick: QuickExpense) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(CategoryStyle.color(for: quick.category, accent: accent.color).opacity(0.2))
                    .frame(width: 32, height: 32)
                Image(systemName: quick.iconName)
                    .font(.footnote)
                    .foregroundStyle(CategoryStyle.color(for: quick.category, accent: accent.color))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(quick.label)
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                // El contador está a la vista a propósito: es lo que dice cuáles
                // vale la pena tener arriba.
                Text(quick.category + " · usado \(quick.useCount) " + (quick.useCount == 1 ? "vez" : "veces"))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(Money.format(quick.amount, currency: quick.currency))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.label)
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = quickExpenses
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, quick) in ordered.enumerated() { quick.sortIndex = index }
        try? modelContext.save()
    }

}

private enum QuickSheet: Identifiable {
    case new
    case edit(QuickExpense)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let quick): return quick.id.uuidString
        }
    }

    var quick: QuickExpense? {
        if case .edit(let quick) = self { return quick }
        return nil
    }
}
