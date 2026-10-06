import SwiftUI
import SwiftData

/// El detalle de una categoría (`5d`).
///
/// Cuatro capas en el orden en que se hacen las preguntas: cuánto llevo, cómo
/// voy contra el límite, en qué comercios se fue, y el detalle. «Dónde se fue»
/// agrupa por comercio porque es lo que permite actuar —«dejo Rappi»—; la
/// lista cronológica sola no lo hace.
struct CategoryDetailView: View {
    let category: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Query(sort: \Expense.date, order: .reverse) private var expenses: [Expense]
    @StateObject private var rates = ExchangeRateService.shared
    @StateObject private var budgets = CategoryBudgetStore.shared

    /// Local: el mes que se mira aquí no mueve el de ninguna otra pantalla.
    @State private var month = Period(granularity: .mes, reference: Date())
    @State private var showsYear = false
    @State private var showsAllMovements = false
    @State private var selectedExpense: Expense?
    @State private var editing = false
    @State private var editingLimit = false
    @State private var merging = false
    @State private var confirmingDelete = false
    @State private var isWorking = false

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }
    private var rate: Double { rates.usdToPenRate }
    private var tint: Color { CategoryStyle.color(for: category, accent: accent.color) }

    /// El mes, o el año entero si se tocó «Año».
    private var period: Period {
        showsYear ? Period(granularity: .anio, reference: month.reference) : month
    }

    // MARK: - Datos

    private func movements(in period: Period) -> [Expense] {
        let range = period.interval
        return expenses.filter {
            // Un pago dividido no es de ninguna categoría: lo son sus partes.
            $0.category == category && !$0.isSplit && $0.date >= range.start && $0.date < range.end
        }
    }

    private func total(_ items: [Expense]) -> Double {
        Money.sum(items) { Accounting.netCostInPEN($0, fallbackRate: rate) }
    }

    private func byMerchant(_ items: [Expense]) -> [(merchant: String, total: Double)] {
        var totals: [String: Int] = [:]
        for item in items {
            totals[item.merchant, default: 0] += Money.cents(Accounting.netCostInPEN(item, fallbackRate: rate))
        }
        return totals.map { ($0.key, Money.value($0.value)) }
            .sorted { Money.cents($0.total) > Money.cents($1.total) }
    }

    private var limit: CategoryLimitStatus {
        CategoryLimits.status(category: category,
                              budget: budgets.budget(for: category),
                              expenses: expenses.map(\.accountingSnapshot),
                              on: CategoryLimits.referenceDate(for: month),
                              usdToPen: rate)
    }

    var body: some View {
        trackedBody.trackScreen("category_detail", feature: .categoryDetail)
    }

    /// El `body` de siempre; `body` lo envuelve para contarlo como pantalla.
    @ViewBuilder private var trackedBody: some View {
        let items = movements(in: period)
        let spent = total(items)
        let previous = total(movements(in: period.previous))

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    periodBar

                    heroBlock(spent: spent)

                    statTiles(items: items, spent: spent, previous: previous)

                    if items.isEmpty {
                        ShellEmptyState(icon: "tray",
                                        title: "Sin movimientos",
                                        message: "Esta categoría no tiene gastos en " + periodName.lowercased() + ".")
                    } else {
                        whereItWent(items: items)
                        latestMovements(items)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(palette.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: CategoryStyle.icon(for: category))
                            .foregroundStyle(tint)
                        Text(category).font(.headline)
                    }
                }
                ToolbarItem(placement: .primaryAction) { menu }
            }
            .overlay {
                if isWorking {
                    ProgressView().controlSize(.large)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .sheet(item: $selectedExpense) { ExpenseDetailsView(expense: $0) }
            .sheet(isPresented: $editing) {
                NavigationStack {
                    CategorySettingsView(category: category, history: expenses)
                }
            }
            .sheet(isPresented: $editingLimit) {
                CategoryLimitEditorView(
                    category: category,
                    color: tint,
                    budget: budgets.record(for: category) ?? CategoryBudget(category: category, amount: 0),
                    history: expenses
                ) { budgets.save($0) }
            }
            .sheet(isPresented: $merging) {
                CategoryMergeSheet(source: category) { dismiss() }
            }
            .confirmationDialog("¿Eliminar «\(category)»?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Eliminar categoría", role: .destructive) { deleteCategory() }
            } message: {
                let count = CategoryEditor.expenseCount(of: category, in: expenses)
                Text("\(count) movimientos pasarán a Sin clasificar y sus reglas se borrarán.")
            }
        }
    }

    // MARK: - Periodo

    private var periodName: String {
        showsYear ? month.reference.formatted(.dateTime.year())
                  : Period.spanishMonthName(for: month.reference)
    }

    /// Mes anterior · este · siguiente, más «Año». El siguiente se apaga si
    /// todavía no llega: no hay nada que ver en el futuro.
    private var periodBar: some View {
        HStack(spacing: 6) {
            monthChip(month.previous, isCurrent: false)
            monthChip(month, isCurrent: true)
            monthChip(month.next, isCurrent: false)
                .disabled(!month.canGoForward)
                .opacity(month.canGoForward ? 1 : 0.4)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showsYear.toggle() }
            } label: {
                Label("Año", systemImage: "calendar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(showsYear ? palette.background : palette.label)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(showsYear ? AnyShapeStyle(palette.label) : AnyShapeStyle(palette.surface),
                                in: Capsule())
                    .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    private func monthChip(_ target: Period, isCurrent: Bool) -> some View {
        let selected = isCurrent && !showsYear
        return Button {
            if target != month || showsYear {
                Analytics.periodChanged(screen: "category_detail", period: target)
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                month = target
                showsYear = false
            }
        } label: {
            Text(isCurrent ? Period.spanishMonthName(for: target.reference)
                           : Period.spanishMonthName(for: target.reference, abbreviated: true)
                                .replacingOccurrences(of: ".", with: ""))
                .font(.system(size: 13, weight: selected ? .bold : .regular))
                .foregroundStyle(selected ? palette.background : palette.secondaryLabel)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(selected ? palette.label : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Cuánto y contra el límite

    private func heroBlock(spent: Double) -> some View {
        let limit = self.limit
        let hasLimit = limit.hasLimit && !showsYear

        return VStack(alignment: .leading, spacing: 8) {
            Text(("Gastado en " + category).uppercased())
                .font(.system(size: 11.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(palette.secondaryLabel)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Money.format(spent))
                    .font(.system(size: 40, weight: .bold))
                    .tracking(-1.2)
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if hasLimit {
                    Text("de " + Money.formatCompact(limit.limit))
                        .font(.system(size: 14))
                        .foregroundStyle(palette.secondaryLabel)
                }
            }

            if hasLimit {
                PaceBar(fraction: limit.fraction, expected: nil,
                        status: limit.isOver ? .over : .ok, height: 8)

                HStack {
                    Text(limit.isOver
                         ? "Pasaste el límite por " + Money.format(limit.overBy)
                         : "Quedan " + Money.format(limit.remaining) + " · \(limit.daysLeft) días")
                        .font(.system(size: 12.5))
                        .foregroundStyle(limit.isOver ? palette.negative : palette.secondaryLabel)
                    Spacer()
                    Button("Editar límite") { editingLimit = true }
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(accent.onSurface(scheme))
                }

                // Lo único que `Presupuestos` tenía y la fila de la lista no
                // puede dar: la barra dice dónde estás, la proyección dice
                // dónde vas a acabar. «S/ 888 de 900» no avisa de nada; «a este
                // ritmo terminas en S/ 1,268», sí.
                if !limit.isOver, let projection = projection(of: limit) {
                    ShellNote(icon: "chart.line.uptrend.xyaxis",
                              text: "A este ritmo terminas el ciclo en " + Money.format(projection),
                              tint: Money.cents(projection) > Money.cents(limit.limit)
                                  ? palette.warning : palette.secondaryLabel)
                }
            } else if !showsYear {
                Button("Poner límite") { editingLimit = true }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent.onSurface(scheme))
            }
        }
    }

    /// Cierre estimado del ciclo si se mantiene el ritmo. `nil` al principio,
    /// donde dividir por una fracción casi cero da cifras absurdas.
    private func projection(of status: CategoryLimitStatus) -> Double? {
        let elapsed = status.elapsedFraction
        guard elapsed > 0.08, Money.cents(status.spent) > 0 else { return nil }
        return Money.multiply(status.spent, by: 1 / elapsed)
    }

    private func statTiles(items: [Expense], spent: Double, previous: Double) -> some View {
        let days = max(1, showsYear ? period.elapsedDays : month.elapsedDays)
        let delta = Money.ratio(Money.subtract(spent, previous), to: previous)

        return HStack(spacing: 8) {
            smallTile(label: "Promedio/día", value: Money.formatCompact(Money.divide(spent, by: days)))
            smallTile(label: "Vs. " + (showsYear ? "año pasado"
                                                 : Period.spanishMonthName(for: month.previous.reference).lowercased()),
                      value: delta.map { ($0 > 0 ? "+" : "") + String(format: "%.0f%%", $0 * 100) } ?? "—",
                      tint: delta.map { $0 > 0 ? palette.negative : palette.positive })
            smallTile(label: "Movimientos", value: "\(items.count)")
        }
    }

    private func smallTile(label: String, value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.secondaryLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(tint ?? palette.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(palette.hairline, lineWidth: 0.5))
    }

    // MARK: - Dónde se fue

    /// Los tres comercios más fuertes con su barra, y el resto sumado. Más de
    /// tres barras y la comparación se convierte en un gráfico que hay que leer.
    private func whereItWent(items: [Expense]) -> some View {
        let rows = byMerchant(items)
        let top = Array(rows.prefix(3))
        let rest = rows.dropFirst(3)
        let restTotal = Money.sum(Array(rest)) { $0.total }
        let maximum = rows.first?.total ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            ShellSectionHeader(title: "Dónde se fue")
                .padding(.horizontal, -6)

            ForEach(Array(top.enumerated()), id: \.offset) { index, row in
                merchantBar(name: Accounting.displayName(row.merchant), total: row.total,
                            fraction: maximum > 0 ? row.total / maximum : 0,
                            color: tint.opacity(1 - Double(index) * 0.22))
            }

            if !rest.isEmpty {
                merchantBar(name: "Otros \(rest.count)", total: restTotal,
                            fraction: maximum > 0 ? restTotal / maximum : 0,
                            color: palette.tertiaryLabel.opacity(0.5))
            }
        }
    }

    private func merchantBar(name: String, total: Double, fraction: Double, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 13.5))
                .foregroundStyle(palette.label)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.track)
                    Capsule().fill(color).frame(width: max(4, geo.size.width * min(1, fraction)))
                }
            }
            .frame(height: 12)

            Text(Money.formatCompact(total))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.label)
                .frame(width: 70, alignment: .trailing)
        }
    }

    // MARK: - Últimos movimientos

    private func latestMovements(_ items: [Expense]) -> some View {
        let shown = showsAllMovements ? items : Array(items.prefix(3))

        return VStack(spacing: 8) {
            HStack {
                Text("ÚLTIMOS MOVIMIENTOS")
                    .font(.system(size: 11.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(palette.secondaryLabel)
                Spacer()
                if items.count > 3 {
                    Button(showsAllMovements ? "Ver menos" : "Ver los \(items.count)") {
                        withAnimation(.easeInOut(duration: 0.2)) { showsAllMovements.toggle() }
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(accent.onSurface(scheme))
                }
            }

            MovementCard {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, expense in
                    MovementRow(expense: expense, onTap: { selectedExpense = expense })
                    if index < shown.count - 1 { MovementSeparator() }
                }
            }
        }
    }

    // MARK: - Editar, fusionar, eliminar

    private var menu: some View {
        Menu {
            Button { editing = true } label: { Label("Editar", systemImage: "pencil") }
            Button { editingLimit = true } label: { Label("Límite", systemImage: "target") }
            if !CategoryCatalog.isSystem(category) {
                Button { merging = true } label: {
                    Label("Fusionar con otra", systemImage: "arrow.triangle.merge")
                }
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Eliminar", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
        }
    }

    private func deleteCategory() {
        isWorking = true
        Task {
            await CategoryEditor.delete(category, in: expenses)
            isWorking = false
            dismiss()
        }
    }
}
