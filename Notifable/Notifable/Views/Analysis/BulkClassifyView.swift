import SwiftUI
import SwiftData

/// Clasificación masiva de Pendientes (`5j`).
///
/// Se agrupa por comercio, no por movimiento: 23 pendientes se vuelven 5
/// decisiones. Cada grupo muestra su destino sugerido **antes** de aceptar, y
/// el pie dice cuántas reglas se van a crear — el efecto secundario que nadie
/// espera y que hace que el próximo Rappi llegue ya clasificado.
struct BulkClassifyView: View {
    /// El alcance con el que se abrió desde Pendientes.
    let onlyThisMonth: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @Query(sort: \Expense.date, order: .reverse) private var expenses: [Expense]
    @StateObject private var rates = ExchangeRateService.shared

    @State private var mode: Mode = .byMerchant
    @State private var selected: Set<String> = []
    @State private var choosing = false
    @State private var didPreselect = false

    enum Mode: Hashable { case byMerchant, byDate }

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    // MARK: - Datos

    private var unclassified: [Expense] {
        let all = expenses.filter { $0.category == Accounting.unclassified && $0.countsAsSpending }
        guard onlyThisMonth else { return all }
        let range = Period(granularity: .mes, reference: Date()).interval
        return all.filter { $0.date >= range.start && $0.date < range.end }
    }

    /// Una fila: un comercio (con todos sus movimientos) o un movimiento suelto.
    struct Row: Identifiable {
        let id: String
        let merchant: String
        let expenses: [Expense]
        let total: Double
        let suggestion: CategorySuggestion?
    }

    private var rows: [Row] {
        let rules = MerchantRules.all()
        let rate = rates.usdToPenRate
        let suggest = { (merchant: String) -> CategorySuggestion? in
            guard let hint = SuggestionEngine.suggest(for: merchant, rules: rules),
                  hint.confidence >= 0.45 else { return nil }
            return hint
        }

        switch mode {
        case .byMerchant:
            var grouped: [String: [Expense]] = [:]
            for expense in unclassified { grouped[expense.merchant, default: []].append(expense) }
            return grouped.map { merchant, items in
                Row(id: merchant, merchant: merchant, expenses: items,
                    total: Money.sum(items) { Accounting.netCostInPEN($0, fallbackRate: rate) },
                    suggestion: suggest(merchant))
            }
            .sorted { Money.cents($0.total) > Money.cents($1.total) }

        case .byDate:
            return unclassified.map { expense in
                Row(id: expense.id.uuidString, merchant: expense.merchant, expenses: [expense],
                    total: Accounting.netCostInPEN(expense, fallbackRate: rate),
                    suggestion: suggest(expense.merchant))
            }
        }
    }

    // MARK: - Cuerpo

    var body: some View {
        let rows = self.rows
        let chosen = rows.filter { selected.contains($0.id) }

        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    modeChip("Por comercio", icon: "storefront", mode: .byMerchant)
                    modeChip("Por fecha", icon: nil, mode: .byDate)
                    Spacer()
                    Text("\(unclassified.count) sin clasificar")
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryLabel)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if rows.isEmpty {
                    ShellEmptyState(icon: "checkmark.circle",
                                    title: "Pendientes vacío",
                                    message: "Todos tus gastos están clasificados.")
                    Spacer()
                } else {
                    ScrollView {
                        MovementCard {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                rowView(row)
                                if index < rows.count - 1 { MovementSeparator() }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }

                    footer(chosen)
                }
            }
            .background(palette.background.ignoresSafeArea())
            .navigationTitle(selected.isEmpty ? "Clasificar" : "\(selected.count) seleccionados")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Listo") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(selected.isEmpty ? "Todos" : "Ninguno") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selected = selected.isEmpty ? Set(rows.map(\.id)) : []
                        }
                    }
                }
            }
            .onChange(of: mode) { _, _ in selected.removeAll() }
            .onAppear {
                // Al abrir, preseleccionados los que tienen sugerencia: son los
                // que se resuelven con un toque.
                guard !didPreselect else { return }
                didPreselect = true
                selected = Set(rows.filter { $0.suggestion != nil }.map(\.id))
            }
            .sheet(isPresented: $choosing) {
                AssignCategorySheet(context: context(for: chosen), history: expenses) { category, alsoPast in
                    apply(category, to: chosen, createRules: alsoPast)
                }
                .presentationDetents([.large])
                .presentationCornerRadius(28)
            }
        }
    }

    private func modeChip(_ title: String, icon: String?, mode target: Mode) -> some View {
        let isOn = mode == target
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { mode = target }
        } label: {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isOn ? palette.background : palette.label)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(isOn ? AnyShapeStyle(palette.label) : AnyShapeStyle(palette.surface), in: Capsule())
            .overlay(Capsule().stroke(isOn ? Color.clear : palette.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Fila

    private func rowView(_ row: Row) -> some View {
        let isOn = selected.contains(row.id)

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isOn { selected.remove(row.id) } else { selected.insert(row.id) }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundStyle(isOn ? accent.color : palette.tertiaryLabel)

                MovementIcon(icon: row.expenses.first.map(MovementStyle.icon(for:)) ?? "tray",
                             color: row.expenses.first.map { MovementStyle.color(for: $0, accent: accent.color, scheme: scheme) }
                                 ?? palette.tertiaryLabel,
                             size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(Accounting.displayName(row.merchant))
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(palette.label)
                        .lineLimit(1)
                    Text(detail(row))
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryLabel)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("–" + Money.format(row.total))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.label)
                    if let hint = row.suggestion {
                        Text("→ " + hint.category)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(accent.onSurface(scheme))
                    } else {
                        Text("sin sugerencia")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.tertiaryLabel)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isOn ? accent.color.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// «4 movimientos · 12–17 set», o la fecha en «Por fecha».
    private func detail(_ row: Row) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "d MMM"
        let dates = row.expenses.map(\.date).sorted()
        guard let first = dates.first, let last = dates.last else { return "" }
        let clean = { (d: Date) in f.string(from: d).replacingOccurrences(of: ".", with: "") }
        if row.expenses.count == 1 { return "1 movimiento · " + clean(first) }
        let range = Period.calendar.isDate(first, inSameDayAs: last) ? clean(first) : clean(first) + "–" + clean(last)
        return "\(row.expenses.count) movimientos · " + range
    }

    // MARK: - Pie

    private func footer(_ chosen: [Row]) -> some View {
        let withHint = chosen.filter { $0.suggestion != nil }
        let rules = MerchantRules.all()
        let newRules = Set(withHint.map(\.merchant)).filter { rules[$0] == nil }.count

        return VStack(spacing: 10) {
            if !chosen.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent.color)
                    Text(footerText(chosen: chosen.count, withHint: withHint.count, newRules: newRules))
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 8) {
                Button {
                    applySuggestions(withHint)
                } label: {
                    Text("Aplicar sugerencias")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accent.buttonText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(accent.buttonFill.opacity(withHint.isEmpty ? 0.4 : 1),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(withHint.isEmpty)

                Button { choosing = true } label: {
                    Text("Elegir una")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.label)
                        .padding(.horizontal, 18)
                        .frame(height: 50)
                        .background(palette.neutralSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(palette.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(chosen.isEmpty)
                .opacity(chosen.isEmpty ? 0.5 : 1)
            }
        }
        .padding(16)
        .background(palette.background)
        .overlay(alignment: .top) { Rectangle().fill(palette.hairline).frame(height: 0.5) }
    }

    private func footerText(chosen: Int, withHint: Int, newRules: Int) -> String {
        let rulesText = newRules == 0 ? "No crea reglas nuevas."
            : newRules == 1 ? "Aceptarlas crea 1 regla nueva." : "Aceptarlas crea \(newRules) reglas nuevas."
        if withHint == chosen {
            return (chosen == 1 ? "El seleccionado tiene sugerencia. " : "Los \(chosen) seleccionados tienen sugerencia. ") + rulesText
        }
        if withHint == 0 { return "Ninguno de los seleccionados tiene sugerencia: usa «Elegir una»." }
        return "\(withHint) de \(chosen) tienen sugerencia; el resto se queda pendiente. " + rulesText
    }

    // MARK: - Aplicar

    private func applySuggestions(_ rows: [Row]) {
        for row in rows {
            guard let category = row.suggestion?.category else { continue }
            assign(category, to: row, createRule: true)
        }
        finish(rows)
    }

    private func apply(_ category: String, to rows: [Row], createRules: Bool) {
        for row in rows { assign(category, to: row, createRule: createRules) }
        finish(rows)
    }

    /// Una regla por comercio, para que lo que llegue después ya venga
    /// clasificado. En «Por comercio» se arrastra además todo su historial sin
    /// clasificar; en «Por fecha», sólo el movimiento elegido.
    private func assign(_ category: String, to row: Row, createRule: Bool) {
        if createRule { MerchantRules.set(category, for: row.merchant) }
        let targets = mode == .byMerchant
            ? expenses.filter { $0.merchant == row.merchant && $0.category == Accounting.unclassified }
            : row.expenses
        for expense in targets {
            expense.category = category
            ExpenseEditStore.record(expense, category: category)
        }
    }

    private func finish(_ rows: [Row]) {
        try? modelContext.save()
        withAnimation(.easeInOut(duration: 0.25)) {
            for row in rows { selected.remove(row.id) }
        }
    }

    private func context(for rows: [Row]) -> AssignCategoryContext {
        let movements = rows.reduce(0) { $0 + $1.expenses.count }
        let total = Money.sum(rows) { $0.total }
        if rows.count == 1, let only = rows.first {
            return .merchant(only.merchant, movements: movements, total: total)
        }
        return AssignCategoryContext(merchant: nil,
                                     title: "\(rows.count) seleccionados",
                                     subtitle: "\(movements) movimientos · " + Money.format(total),
                                     amount: total,
                                     ruleScope: .past)
    }
}
