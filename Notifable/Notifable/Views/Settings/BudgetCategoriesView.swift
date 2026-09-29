import SwiftUI
import SwiftData

/// Presupuesto y categorías (`4e`): la meta del mes, los límites por
/// categoría y las reglas en una sola pantalla. Antes eran dos filas de la
/// raíz, y el presupuesto era un `Form` con un campo suelto.
struct BudgetCategoriesView: View {

    @Environment(\.colorScheme) private var scheme
    @Environment(\.modelContext) private var modelContext
    @AppStorage(BudgetStore.enabledKey) private var budgetEnabled = true
    @AppStorage(BudgetStore.monthlyBudgetKey) private var monthlyBudget: Double = 0
    @AppStorage(BudgetStore.tracksIncomeKey) private var tracksIncome = true

    @Query private var expenses: [Expense]
    @StateObject private var rates = ExchangeRateService.shared
    @StateObject private var budgets = CategoryBudgetStore.shared
    @StateObject private var catalog = CategoryCatalog.shared

    @State private var stats = CategoryRulesStats()
    @State private var history: [Expense] = []
    @State private var editing: CategoryRef?
    @State private var editsAmount = false
    @State private var amountText = ""

    init() {
        let window = Period(granularity: .mes, reference: Date()).dataWindow()
        let start = window.start
        let end = window.end
        _expenses = Query(filter: #Predicate<Expense> { $0.date >= start && $0.date < end },
                          sort: \Expense.date, order: .reverse)
    }

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }
    private var hasBudget: Bool { BudgetStore.hasBudget(monthlyBudget: monthlyBudget, enabled: budgetEnabled) }

    private var totals: PeriodTotals {
        Accounting.totals(expenses: expenses, incomes: [],
                          period: Period(granularity: .mes, reference: Date()),
                          usdToPen: rates.usdToPenRate)
    }

    /// Las cuatro que más gastaron este mes; el resto, en «Ver las N».
    private var topCategories: [String] {
        let spent = totals.byCategory.map(\.category).filter { stats.active.contains($0) }
        let rest = stats.active.filter { !spent.contains($0) }
        return Array((spent + rest).prefix(4))
    }

    var body: some View {
        SettingsPage(title: "Presupuesto y categorías") {
            if hasBudget { progressCard }

            SettingsGroup(footer: tracksIncome
                          ? "El presupuesto se prorratea al periodo que estés viendo."
                          : "Sin ingresos, AgruPay usa sólo tu presupuesto.") {
                SettingsToggle(title: "Presupuesto mensual", isOn: $budgetEnabled)
                if budgetEnabled {
                    SettingsDivider(inset: 14)
                    SettingsButton(title: "Monto",
                                   value: Money.cents(monthlyBudget) > 0 ? Money.format(monthlyBudget) : "Sin definir") {
                        amountText = Money.cents(monthlyBudget) > 0 ? String(format: "%.2f", monthlyBudget) : ""
                        editsAmount = true
                    }
                }
                SettingsDivider(inset: 14)
                SettingsToggle(title: "Registrar ingresos", isOn: $tracksIncome)
            }

            SettingsGroup(title: "Categorías · \(stats.active.count)") {
                ForEach(topCategories, id: \.self) { name in
                    Button { editing = CategoryRef(name: name) } label: {
                        HStack(spacing: 0) {
                            MovementIcon(icon: CategoryStyle.icon(for: name),
                                         color: CategoryStyle.color(for: name, accent: accent.color),
                                         size: 30)
                                .padding(.leading, 14)
                            SettingsItem(title: name, subtitle: detail(for: name)) {
                                SettingsValueChevron()
                            }
                            .padding(.leading, -2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    SettingsDivider()
                }
                NavigationLink {
                    CategoryRulesScreen()
                } label: {
                    HStack {
                        Text("Ver las \(stats.active.count) categorías")
                            .foregroundStyle(accent.onSurface(scheme))
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            SettingsGroup(title: "Reglas") {
                SettingsLink(icon: "wand.and.stars", tint: accent.color,
                             title: stats.ruleCount == 1 ? "1 regla activa" : "\(stats.ruleCount) reglas activas",
                             subtitle: stats.ruleCount == 0
                                ? "Se crean al asignar una categoría a un comercio"
                                : "Clasifican solas el \(stats.coveragePercent)% de tus gastos") {
                    MerchantRulesList()
                }
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $editing, onDismiss: reload) { ref in
            NavigationStack {
                CategorySettingsView(category: ref.name, history: history)
            }
        }
        .alert("Presupuesto mensual", isPresented: $editsAmount) {
            TextField("S/ 0.00", text: $amountText)
                .keyboardType(.decimalPad)
            Button("Cancelar", role: .cancel) {}
            Button("Guardar") { commitAmount() }
        } message: {
            Text("Lo que quieres gastar como máximo cada mes.")
        }
    }

    // MARK: - Progreso

    /// «S/ 1,550 / 2.5k», la barra y la marca del ritmo esperado.
    private var progressCard: some View {
        let spent = totals.spent
        let fraction = min(max(spent / max(monthlyBudget, 0.01), 0), 1)
        let month = Period(granularity: .mes, reference: Date()).interval
        let elapsed = min(max(Date().timeIntervalSince(month.start) / month.end.timeIntervalSince(month.start), 0), 1)
        let percent = Int((spent / max(monthlyBudget, 0.01) * 100).rounded())
        let onTrack = Double(percent) / 100 <= elapsed

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Presupuesto del mes")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.label)
                Spacer()
                Text(Money.formatCompact(spent) + " / " + Money.formatCompact(monthlyBudget))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(palette.secondaryLabel)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.track)
                    Capsule().fill(percent > 100 ? palette.negative : accent.color)
                        .frame(width: proxy.size.width * fraction)
                    // Dónde deberías ir a estas alturas del mes.
                    Rectangle()
                        .fill(palette.label)
                        .frame(width: 2, height: 12)
                        .offset(x: proxy.size.width * elapsed - 1)
                }
            }
            .frame(height: 8)

            Label("Vas al \(percent)% del presupuesto con el \(Int((elapsed * 100).rounded()))% del mes transcurrido.",
                  systemImage: onTrack ? "checkmark.circle" : "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(onTrack ? palette.secondaryLabel : palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
        .padding(.horizontal, 16)
    }

    // MARK: - Filas

    /// «Límite S/ 900 · 4 comercios», «Sin límite · 2 comercios».
    private func detail(for name: String) -> String {
        let limit = budgets.budget(for: name).map { "Límite " + Money.formatCompact($0.amount) } ?? "Sin límite"
        let merchants = stats.merchantsByCategory[name] ?? 0
        let merchantLabel = merchants == 0 ? "sin comercios"
            : merchants == 1 ? "1 comercio" : "\(merchants) comercios"
        return limit + " · " + merchantLabel
    }

    private func commitAmount() {
        let cleaned = amountText.replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "S/", with: "")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { monthlyBudget = 0; return }
        guard let value = Double(cleaned) else { return }
        monthlyBudget = Money.normalized(max(0, value))
    }

    private func reload() {
        stats = CategoryRulesStats(context: modelContext, catalog: catalog)
        history = (try? modelContext.fetch(FetchDescriptor<Expense>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
    }
}
