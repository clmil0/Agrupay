import SwiftUI
import SwiftData

/// El dashboard único (`1b`): la pantalla de entrada de la app.
///
/// Sustituye a las tres pestañas. Arriba, cuánto llevas gastado en el mes y
/// contra el anterior; debajo, el gráfico de la semana contra la pasada; las
/// tiras de stats; la cuadrícula de accesos —Historial, Categorías,
/// Pendientes, Amigos—, y lo comprometido del mes. La lista de días ya no vive
/// aquí: está en Historial (Movimientos), a un toque.
///
/// El chip «Todas las cuentas» filtra **todo** lo de esta pantalla, y el
/// mismo filtro llega a Movimientos (`AccountFilter`).
struct DashboardView: View {
    /// Meses hacia atrás desde el actual. Vive en `DashboardScreen`: cambiarlo
    /// tiene que volver a construir las consultas.
    @Binding var monthOffset: Int
    let progress: ScrollProgress
    let onOpen: (AppSection) -> Void
    let onSettings: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// El mes mostrado y el anterior, nada más.
    @Query private var expenses: [Expense]
    @Query private var incomes: [Income]
    /// Todo lo que falta clasificar, de cualquier fecha y cuenta: lo mismo
    /// que cuenta Pendientes, para que las cifras de la tarjeta y las de la
    /// pantalla coincidan. Son pocos (se van vaciando).
    @Query private var unclassified: [Expense]
    /// Las claves de todos los movimientos, para el globo de nuevos de
    /// «Historial». Antes eran dos `@Query` del historial entero: se
    /// cargaban al dibujar la cuadrícula —unos 190 ms en el hilo principal,
    /// justo en la entrada del gráfico—. Ahora salen de la lectura que ya
    /// hace `loadCatalog`.
    @State private var movementKeys: Set<String> = []

    @StateObject private var rates = ExchangeRateService.shared
    @StateObject private var accountBook = AccountBook.shared
    @AppStorage(BudgetStore.monthlyBudgetKey) private var monthlyBudget = 0.0
    @AppStorage(BudgetStore.enabledKey) private var budgetEnabled = false
    @AppStorage(DashboardStatsSettings.key) private var statsRaw = DashboardStatsSettings.defaultValue
    /// El ojito junto al monto grande: tapa todos los montos del resumen.
    @AppStorage(AmountPrivacy.storageKey) private var hidesAmounts = false
    /// La transición del ojito (`amountVeil`): sube, se cambian las cifras,
    /// baja.
    @State private var amountVeil = 0.0
    /// Lo que va a quedar mientras dura la transición (`nil` en reposo): el
    /// ícono cambia al tocar, los montos a mitad de camino.
    @State private var eyeTarget: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var categoryBudgets = CategoryBudgetStore.shared

    @State private var filter = AccountFilter.shared
    @State private var newMovements = NewMovements.shared
    @State private var catalog: AccountCatalog?
    /// Con qué datos se leyó el historial por última vez (`StoreRevision`).
    /// En una caja: anotarlo no debe volver a dibujar el dashboard.
    @State private var loaded = LoadedRevisions()
    /// Las categorías con límite y cómo van en el ciclo del mes mostrado. Un
    /// ciclo anual necesita el historial entero, así que se calcula junto al
    /// catálogo y no en cada dibujado.
    @State private var limitStatuses: [CategoryLimitStatus] = []
    /// Comercios sin categoría de antes del mes mostrado.
    @State private var chartMode: SpendBarChart.Mode = .week
    @State private var selectedColumn: Int?
    @State private var openStat: StatDetail?
    @State private var scrollToTop = false

    // Asistente (`1f`)
    @State private var assistant: AssistantPresentation?
    /// Lo que pidió un botón del asistente; se hace al cerrarse la hoja.
    @State private var pendingAction: AssistantAction?
    @State private var assistantCategory: CategoryRef?
    @State private var showsRecurring = false
    @State private var reminderDebt: Expense?

    private let month: Period

    init(monthOffset: Binding<Int>,
         progress: ScrollProgress,
         onOpen: @escaping (AppSection) -> Void,
         onSettings: @escaping () -> Void) {
        self._monthOffset = monthOffset
        self.progress = progress
        self.onOpen = onOpen
        self.onSettings = onSettings

        let shown = Self.month(offset: monthOffset.wrappedValue)
        self.month = shown
        // Desde el mes anterior: el delta del titular, y los últimos 7 días
        // del gráfico cuando empiezan antes del 1.
        let start = shown.previous.interval.start
        let end = shown.interval.end

        _expenses = Query(filter: #Predicate<Expense> { $0.date >= start && $0.date < end },
                          sort: \Expense.date, order: .reverse)
        _incomes = Query(filter: #Predicate<Income> { $0.date >= start && $0.date < end },
                         sort: \Income.date, order: .reverse)

        let unclassifiedName = Accounting.unclassified
        _unclassified = Query(filter: #Predicate<Expense> {
            $0.category == unclassifiedName && !$0.isTransfer && !$0.isVoided && !$0.isReversal && !$0.isSplit
        })
    }

    static func month(offset: Int) -> Period {
        var period = Period(granularity: .mes, reference: Date())
        for _ in 0..<max(0, offset) { period = period.previous }
        return period
    }

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }
    private var rate: Double { rates.usdToPenRate }
    private var isCurrentMonth: Bool { monthOffset == 0 }

    // MARK: - Filtro de cuenta

    private var filteredExpenses: [Expense] {
        guard let account = filter.selection, let catalog else { return expenses }
        return expenses.filter { AccountFilter.matches($0, account: account, catalog: catalog) }
    }

    private var filteredIncomes: [Income] {
        guard let account = filter.selection, let catalog else { return incomes }
        return incomes.filter { AccountFilter.matches($0, account: account, catalog: catalog) }
    }

    /// Las cuentas marcadas como tuyas, en el orden del carrusel.
    private var accounts: [DetectedAccount] {
        guard let catalog else { return [] }
        return accountBook.preferences.carousel(from: catalog)
    }

    private var selectedAccountName: String {
        guard let key = filter.selection,
              let account = catalog?.accounts[key] else { return "Todas las cuentas" }
        return accountBook.preferences.name(for: account)
    }

    /// El catálogo necesita el historial entero —de él salen los alias de las
    /// tarjetas y a qué banco llega cada Plin—, así que se arma fuera del
    /// cuerpo y una sola vez por aparición, no en cada dibujado.
    private func loadCatalog() {
        loaded.catalog = StoreRevision.current
        let all = (try? modelContext.fetch(FetchDescriptor<Expense>())) ?? []
        let allIncomes = (try? modelContext.fetch(FetchDescriptor<Income>())) ?? []
        catalog = AccountCatalog(expenses: all, incomes: allIncomes)
        let keys = NewMovements.keys(expenses: all, incomes: allIncomes)
        newMovements.baselineIfNeeded(keys)
        if keys != movementKeys { movementKeys = keys }
        loadMonthExtras(all)
        if let key = filter.selection, !accounts.contains(where: { $0.key == key }) {
            filter.selection = nil
        }
    }

    /// Lo que depende del mes mostrado y necesita el historial entero: los
    /// límites (un ciclo anual va más allá del mes).
    private func loadMonthExtras(_ all: [Expense]? = nil) {
        let all = all ?? ((try? modelContext.fetch(FetchDescriptor<Expense>())) ?? [])
        let snapshots = all.map(\.accountingSnapshot)
        let day = referenceDay
        limitStatuses = categoryBudgets.budgets.values
            .filter { $0.hasLimit && $0.category != Accounting.unclassified }
            .map { CategoryLimits.status(category: $0.category, budget: $0,
                                         expenses: snapshots, on: day, usdToPen: rate) }
    }

    // MARK: - Cuerpo

    var body: some View {
        let expenses = filteredExpenses
        let incomes = filteredIncomes
        // Una sola conversión a snapshots por dibujado: cada `totals` sobre
        // los modelos volvía a convertirlos todos, y el gráfico de seis
        // semanas pedía seis.
        let snapshots = (expenses: expenses.map(\.accountingSnapshot),
                         incomes: incomes.map(\.accountingSnapshot))
        let totals = Accounting.totals(expenses: snapshots.expenses, incomes: snapshots.incomes,
                                       period: month, usdToPen: rate)
        let previous = Accounting.totals(expenses: snapshots.expenses, incomes: snapshots.incomes,
                                         period: month.previous, usdToPen: rate)
        let chart = chartColumns(snapshots.expenses, snapshots.incomes)

        ZStack(alignment: .top) {
            TrackableScrollView(scrollToTopTrigger: $scrollToTop) {
                VStack(alignment: .leading, spacing: 0) {
                    hero(totals: totals, previous: previous)
                        .padding(.bottom, 20)

                    chartBlock(chart)
                        .padding(.bottom, 30)

                    statsBlock(totals: totals, expenses: expenses, incomes: snapshots.incomes)

                    grid(totals: totals, expenses: expenses, incomes: incomes)
                        .padding(.bottom, 28)

                    if isCurrentMonth {
                        CommittedSection(rate: rate)
                    }
                }
                .padding(.horizontal, ShellMetrics.sideInset)
                .padding(.top, ShellMetrics.contentTopInset)
                .padding(.bottom, 140)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                progress.update(offset)
            }

            header
        }
        // Las tarjetas y las hojas que abre el resumen leen el ojito de aquí.
        .environment(\.hidesAmounts, hidesAmounts)
        .environment(\.amountVeil, amountVeil)
        .environment(\.amountSwapping, eyeTarget != nil)
        .task {
            // La primera vez el gráfico espera al catálogo (`isReady`). Al
            // volver de otra pantalla el gráfico repite su entrada en
            // seguida, así que releer el historial —y armar el resumen del
            // asistente— va después: hecho en medio, trababa la animación.
            let firstLoad = catalog == nil
            if firstLoad { loadCatalog() }
            try? await Task.sleep(for: .milliseconds(1500))
            // Leer el historial entero en el hilo principal: nunca a mitad de
            // un deslizamiento, que es justo lo que se hace al volver aquí.
            await ScrollActivity.idle()
            guard !Task.isCancelled else { return }
            // Al volver de otra pantalla sólo se relee si algo se guardó
            // mientras tanto: si no, el catálogo y el resumen siguen valiendo.
            if !firstLoad, loaded.catalog != StoreRevision.current { loadCatalog() }
            if loaded.brief != StoreRevision.current || Self.briefDay != AssistantBrief.dayKey(Date()) {
                refreshBrief()
            }
        }
        .onChange(of: self.expenses.count) { _, _ in
            loadCatalog()
            refreshBrief()
        }
        // Un día nuevo trae resumen nuevo aunque la app siguiera abierta. Con
        // la notificación y no con `scenePhase`: leer éste del entorno volvía
        // a evaluar todo el dashboard justo durante la entrada del gráfico.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            guard let day = Self.briefDay, day != AssistantBrief.dayKey(Date()) else { return }
            refreshBrief()
        }
        .onChange(of: chartMode) { _, _ in selectedColumn = nil }
        .onChange(of: monthOffset) { _, _ in
            selectedColumn = nil
            loadMonthExtras()
        }
        .onChange(of: categoryBudgets.budgets) { _, _ in
            loadMonthExtras()
            NotificationManager.shared.recount()
            // Los límites no pasan por SwiftData: el resumen del asistente
            // los usa, así que se vuelve a armar al regresar.
            loaded.brief = -1
        }
        .sheet(item: $openStat) { StatSheet(stat: $0).environment(\.hidesAmounts, hidesAmounts) }
        .sheet(item: $assistant, onDismiss: runPendingAction) { presentation in
            AssistantSheet(cards: presentation.cards, inputs: presentation.inputs,
                           categories: presentation.categories) { pendingAction = $0 }
                .appTextSize()
        }
        .sheet(item: $assistantCategory) { CategoryDetailView(category: $0.name) }
        .sheet(isPresented: $showsRecurring) {
            NavigationStack {
                RecurringManagementView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Listo") { showsRecurring = false }
                        }
                    }
            }
        }
        .sheet(item: $reminderDebt) { ReminderComposerSheet(initialDebt: $0) }
    }

    // MARK: - Asistente

    struct AssistantPresentation: Identifiable {
        let id = UUID()
        let cards: [BriefCard]
        let inputs: AssistantInputs
        let categories: [String]
    }

    struct CategoryRef: Identifiable {
        let name: String
        var id: String { name }
    }

    /// El día del último resumen calculado: al volver a la app sólo se
    /// recalcula si cambió.
    private static var briefDay: String?

    /// Las tarjetas del día, para saber si el ✦ lleva punto.
    private func refreshBrief() {
        loaded.brief = StoreRevision.current
        Self.briefDay = AssistantBrief.dayKey(Date())
        let inputs = AssistantData.inputs(context: modelContext, usdToPen: rate)
        // Configuración › Asistente › Resumen del día: sin él, el ✦ no lleva punto.
        let news = AssistantSettings.briefDot && AssistantSeenState().hasNews(AssistantBrief.cards(inputs))
        guard news != AssistantDot.shared.hasNews else { return }
        withAnimation(.easeInOut(duration: 0.2)) { AssistantDot.shared.hasNews = news }
    }

    private func openAssistant() {
        let inputs = AssistantData.inputs(context: modelContext, usdToPen: rate)
        let cards = AssistantBrief.cards(inputs)
        AssistantSeenState().markSeen(cards)
        withAnimation(.easeInOut(duration: 0.2)) { AssistantDot.shared.hasNews = false }
        assistant = AssistantPresentation(cards: cards, inputs: inputs,
                                          categories: AssistantData.categories(context: modelContext))
    }

    private func runPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        switch action {
        case .section(let raw):
            if let section = AppSection(rawValue: raw) { onOpen(section) }
        case .category(let name):
            assistantCategory = CategoryRef(name: name)
        case .recurring:
            showsRecurring = true
        case .reminder(let id):
            let descriptor = FetchDescriptor<Expense>(predicate: #Predicate { $0.id == id })
            reminderDebt = try? modelContext.fetch(descriptor).first
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            accountChip
            Spacer(minLength: 8)
            AssistantHeaderButton(action: openAssistant)
            ShellCircleButton(icon: "gearshape", label: "Configuración", action: onSettings)
        }
        .padding(.horizontal, ShellMetrics.sideInset)
        .frame(height: ShellMetrics.headerHeight)
        .background(ShellHeaderBackground(progress: progress))
    }

    private var accountChip: some View {
        Menu {
            Button {
                filter.selection = nil
            } label: {
                if filter.selection == nil {
                    Label("Todas las cuentas", systemImage: "checkmark")
                } else {
                    Text("Todas las cuentas")
                }
            }

            if !accounts.isEmpty {
                Divider()
                ForEach(accounts) { account in
                    let name = accountBook.preferences.name(for: account)
                    Button {
                        filter.selection = account.key
                    } label: {
                        if filter.selection == account.key {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(account.digits.map { name + " ••" + $0 } ?? name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: filter.selection == nil ? "building.columns.fill" : "creditcard.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent.onSurface(scheme))
                    .frame(width: 22, height: 22)
                    .background(accent.softFill(scheme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text(selectedAccountName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.secondaryLabel)
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: ShellMetrics.circleButton)
            .background(palette.surface, in: Capsule())
            .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
        }
        .accessibilityLabel("Cuenta: " + selectedAccountName)
    }

    // MARK: - Titular

    private var monthName: String {
        let name = Period.spanishMonthName(for: month.reference)
        let calendar = Period.calendar
        guard calendar.component(.year, from: month.reference) != calendar.component(.year, from: Date())
        else { return name }
        return name + " " + String(calendar.component(.year, from: month.reference))
    }

    /// «Septiembre 2026»: el titular siempre lleva el año.
    private var heroMonthTitle: String {
        Period.spanishMonthName(for: month.reference) + " "
            + String(Period.calendar.component(.year, from: month.reference))
    }

    private func hero(totals: PeriodTotals, previous: PeriodTotals) -> some View {
        let spent = totals.spent
        let isEmpty = Money.isZero(spent) && Money.isZero(totals.income)
        let formatted = Money.format(spent)
        // «S/ 2,612» grande y «.00» chico: los céntimos casi nunca importan y
        // a 46 pt se comían un tercio del ancho.
        let split = formatted.lastIndex(of: ".").map { (formatted[..<$0], formatted[$0...]) }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Gastos en " + heroMonthTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(palette.secondaryLabel)

                Spacer(minLength: 8)

                // El pasado se navega desde aquí, un mes por toque.
                monthArrow("chevron.left", label: "Mes anterior") { monthOffset += 1 }
                monthArrow("chevron.right", label: "Mes siguiente", disabled: isCurrentMonth) {
                    monthOffset = max(0, monthOffset - 1)
                }
            }

            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    // Tapado va sin céntimos: «S/ •••» y nada más.
                    Text(hidesAmounts ? AmountPrivacy.mask(formatted) : (split.map { String($0.0) } ?? formatted))
                        .font(.system(size: 46, weight: .bold))
                        .tracking(-1.8)
                        .monospacedDigit()
                        .foregroundStyle(isEmpty ? palette.tertiaryLabel : palette.label)
                        // Las cifras ruedan al cambiar de mes; con el ojito
                        // cambian en seco bajo el velo (rodar «533» hasta
                        // «•••» no tiene sentido).
                        .contentTransition(eyeTarget == nil ? .numericText() : .identity)
                    if !hidesAmounts, let cents = split?.1 {
                        Text(String(cents))
                            .font(.system(size: 18, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(palette.secondaryLabel)
                            .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .amountVeil()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Gasto de " + monthName + ": " + formatted.masked(hidesAmounts))

                eyeButton
            }

            HStack(spacing: 10) {
                deltaChip(spent: spent, previous: previous.spent)

                if !isCurrentMonth {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { monthOffset = 0 }
                    } label: {
                        Text("Volver a este mes")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(accent.onSurface(scheme))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
    }

    /// Abre y cierra el ojito: todos los montos del resumen a la vez.
    private var eyeButton: some View {
        Button(action: toggleAmounts) {
            // Los dos glifos siempre dibujados y sólo cambia la opacidad: al
            // cambiar el nombre del símbolo (con o sin `.symbolEffect`)
            // SwiftUI pintaba el glifo nuevo ya en su destino mientras el
            // círculo aún se deslizaba. Así viajan juntos.
            let closed = eyeTarget ?? hidesAmounts
            ZStack {
                Image(systemName: "eye")
                    .opacity(closed ? 0 : 1)
                    .scaleEffect(closed ? 0.7 : 1)
                Image(systemName: "eye.slash")
                    .opacity(closed ? 1 : 0)
                    .scaleEffect(closed ? 1 : 0.7)
            }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.secondaryLabel)
                .frame(width: 32, height: 32)
                .background(palette.surface, in: Circle())
                .overlay(Circle().stroke(palette.hairline, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: hidesAmounts)
        .accessibilityLabel((eyeTarget ?? hidesAmounts) ? "Mostrar montos" : "Ocultar montos")
    }

    /// En dos tiempos: los montos se desenfocan (130 ms), en el pico se
    /// cambian —cifras ↔ «•••», con o sin céntimos— y vuelven a enfocarse
    /// con un resorte corto. Antes `numericText` intentaba rodar
    /// «2,612» hasta «•••» carácter por carácter y los céntimos saltaban.
    ///
    /// Con «Reducir movimiento», un fundido simple sin desenfoque ni escala.
    private func toggleAmounts() {
        guard !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.2)) { hidesAmounts.toggle() }
            return
        }
        // Un segundo toque a mitad de camino esperaría a que termine el
        // primero; más simple ignorarlo, dura medio segundo.
        guard eyeTarget == nil else { return }
        let target = !hidesAmounts
        // El ícono responde al toque; los montos, a mitad de camino.
        withAnimation(.snappy(duration: 0.22)) { eyeTarget = target }
        withAnimation(.easeIn(duration: 0.13)) {
            amountVeil = 1
        } completion: {
            // Con el mismo resorte: el ojito se desliza al nuevo ancho del
            // monto en vez de saltar.
            withAnimation(.spring(duration: 0.38, bounce: 0.2)) {
                hidesAmounts = target
                amountVeil = 0
            } completion: {
                eyeTarget = nil
            }
        }
    }

    private func monthArrow(_ icon: String, label: String, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(disabled ? palette.tertiaryLabel.opacity(0.5) : palette.secondaryLabel)
                .frame(width: 28, height: 28)
                .background(palette.surface, in: Circle())
                .overlay(Circle().stroke(palette.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    /// «↑ S/ 318 vs. agosto». Sin mes anterior con datos no hay comparación,
    /// y el chip no se dibuja en vez de inventar un «↑ 100 %».
    @ViewBuilder
    private func deltaChip(spent: Double, previous: Double) -> some View {
        let delta = Money.subtract(spent, previous)
        if !Money.isZero(previous), !Money.isZero(delta) {
            let isUp = Money.cents(delta) > 0
            HStack(spacing: 4) {
                Image(systemName: isUp ? "arrow.up" : "arrow.down")
                    .font(.system(size: 11, weight: .bold))
                Text((Money.formatCompact(abs(delta)) + " vs. "
                      + Period.spanishMonthName(for: month.previous.reference).lowercased()).masked(hidesAmounts))
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .amountVeil()
            }
            // En dos colores, el chip va en el acento 2 suba o baje: la
            // flecha ya dice hacia dónde.
            .foregroundStyle(palette.duoText ?? (isUp ? palette.expenseText : palette.income))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(accent.isDuotone ? accent.secondarySoftFill(scheme)
                                         : (isUp ? palette.expenseSoft : palette.incomeSoft),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: - Gráfico

    private struct ChartData {
        let columns: [SpendBarChart.Column]
        let title: String
        let subtitle: String
        let defaultSelection: Int?
    }

    /// Hasta dónde llega el gráfico: hoy en el mes en curso; en un mes pasado,
    /// su último día.
    private var referenceDay: Date {
        Self.referenceDay(for: month, isCurrent: isCurrentMonth)
    }

    private static func referenceDay(for month: Period, isCurrent: Bool) -> Date {
        if isCurrent { return Date() }
        let end = month.interval.end
        return Period.calendar.date(byAdding: .day, value: -1, to: end) ?? end
    }

    private func chartColumns(_ expenses: [ExpenseSnapshot], _ incomes: [IncomeSnapshot]) -> ChartData {
        let calendar = Period.calendar
        let end = calendar.startOfDay(for: referenceDay)
        let spanish = Locale(identifier: "es_ES")

        switch chartMode {
        case .week:
            // Los últimos siete días, terminando en `end`: no la semana de
            // lunes a domingo, que el lunes sería una sola barra.
            let start = calendar.date(byAdding: .day, value: -6, to: end) ?? end
            let range = Period(granularity: .rango, reference: end, customStart: start, customEnd: end)
            let totals = Accounting.totals(expenses: expenses, incomes: incomes, period: range, usdToPen: rate)
            // Miércoles es «X»: con dos «M» seguidas no se sabía cuál era cuál.
            let letters = [1: "D", 2: "L", 3: "M", 4: "X", 5: "J", 6: "V", 7: "S"]
            let columns = range.days.enumerated().map { index, day in
                SpendBarChart.Column(
                    id: index,
                    label: letters[calendar.component(.weekday, from: day)] ?? "",
                    accessibilityLabel: day.formatted(.dateTime.weekday(.wide).day().locale(spanish)),
                    total: totals.dailySpent.first { calendar.isDate($0.date, inSameDayAs: day) }?.total ?? 0)
            }
            let count = totals.expenseCount
            return ChartData(columns: columns,
                             title: isCurrentMonth ? "Últimos 7 días" : "Últimos 7 días de " + monthName.lowercased(),
                             subtitle: Money.formatCompact(totals.spent) + " · "
                                + (count == 1 ? "1 movimiento" : "\(count) movimientos"),
                             defaultSelection: Self.defaultSelection(columns))

        case .month:
            // Sólo las semanas del mes, recortadas a él: la primera va del 1
            // al domingo siguiente y la última, del lunes al fin de mes.
            var spent = 0.0
            var count = 0
            let columns = Self.monthWeeks(month).enumerated().map { index, week in
                let range = Period(granularity: .rango, reference: week.start,
                                   customStart: week.start, customEnd: week.end)
                let totals = Accounting.totals(expenses: expenses, incomes: incomes, period: range, usdToPen: rate)
                spent = Money.add(spent, totals.spent)
                count += totals.expenseCount
                let isThisWeek = isCurrentMonth && range.contains(Date())
                return SpendBarChart.Column(
                    id: index,
                    label: isThisWeek ? "Esta" : dayMonth(week.start),
                    accessibilityLabel: "Del " + dayMonth(week.start) + " al " + dayMonth(week.end),
                    total: totals.spent)
            }
            return ChartData(columns: columns,
                             title: isCurrentMonth ? "Este mes" : "Semanas de " + monthName.lowercased(),
                             subtitle: Money.formatCompact(spent) + " · "
                                + (count == 1 ? "1 movimiento" : "\(count) movimientos"),
                             defaultSelection: Self.defaultSelection(columns))
        }
    }

    /// Las semanas (lunes a domingo) del mes, recortadas a él: primer y
    /// último día de cada una. La primera empieza el 1 y dura al menos dos
    /// días: si el 1 cae en domingo, se junta con la semana siguiente.
    static func monthWeeks(_ month: Period) -> [(start: Date, end: Date)] {
        let calendar = Period.calendar
        let days = month.days
        guard let first = days.first, let last = days.last else { return [] }

        var weeks: [(start: Date, end: Date)] = []
        var start = first
        while start <= last {
            // El domingo de la semana de `start` (o del día siguiente, si
            // `start` es el 1 y cae en domingo).
            let anchor = weeks.isEmpty ? (calendar.date(byAdding: .day, value: 1, to: start) ?? start) : start
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
            let sunday = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? anchor
            let end = min(sunday, last)
            weeks.append((start, end))
            guard let next = calendar.date(byAdding: .day, value: 1, to: end) else { break }
            start = next
        }
        return weeks
    }

    /// La última barra con gasto; si no hubo ninguna, la última. Un «S/ 0»
    /// encima de la barra de hoy, a primera hora, no dice nada.
    private static func defaultSelection(_ columns: [SpendBarChart.Column]) -> Int? {
        columns.lastIndex { Money.cents($0.total) > 0 } ?? columns.indices.last
    }

    /// «15 set».
    private func dayMonth(_ date: Date) -> String {
        date.formatted(Self.dayMonthStyle).replacingOccurrences(of: ".", with: "")
    }

    /// Una vez y no por llamada: cada stat pide una etiqueta por día del mes.
    private static let dayMonthStyle = Date.FormatStyle.dateTime.day().month(.abbreviated)
        .locale(Locale(identifier: "es_ES"))

    private func chartBlock(_ chart: ChartData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(chart.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.label)
                    Text(chart.subtitle.masked(hidesAmounts))
                        .amountVeil()
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(palette.secondaryLabel)
                }

                Spacer(minLength: 8)

                CompactSegment(items: SpendBarChart.Mode.allCases, selection: $chartMode) { $0.rawValue }
            }

            SpendBarChart(columns: chart.columns,
                          selected: Binding(get: { selectedColumn ?? chart.defaultSelection },
                                            set: { selectedColumn = $0 }),
                          isReady: catalog != nil)
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Stats

    /// Las tiras elegidas en Ajustes › Estadísticas, en su orden.
    ///
    /// Cuántas quedan decide el dibujo: una sola va en grande con su gráfico
    /// y su frase; dos se reparten la fila y enseñan una segunda línea; tres
    /// llenan la fila, y con más la fila se desliza como carrusel.
    @ViewBuilder
    private func statsBlock(totals: PeriodTotals, expenses: [Expense], incomes: [IncomeSnapshot]) -> some View {
        let stats = self.stats(totals: totals, expenses: expenses, incomes: incomes)

        if !stats.isEmpty {
            ShellSectionHeader(title: monthName + " · Estadísticas")

            switch stats.count {
            case 1:
                StatExpandedCard(stat: stats[0]) { openStat = stats[0] }
                    .padding(.bottom, 30)

            case 2:
                HStack(spacing: Self.gridSpacing) {
                    ForEach(stats) { stat in
                        strip(stat, roomy: true)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 30)

            default:
                // Tres tiras del mismo ancho que llenan la fila, alineadas con
                // Historial y Categorías de abajo (mismo espacio entre ellas).
                // Si hay más de tres, las demás siguen al deslizar.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.gridSpacing) {
                        ForEach(stats) { stat in
                            strip(stat, roomy: false)
                                .containerRelativeFrame(.horizontal, count: 3, spacing: Self.gridSpacing)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.bottom, 4)
                }
                .contentMargins(.horizontal, ShellMetrics.sideInset, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollDisabled(stats.count <= 3)
                .padding(.horizontal, -ShellMetrics.sideInset)
                .padding(.bottom, 30)
            }
        }
    }

    /// Una tira: etiqueta y cifra; con sitio (dos tiras), también su segunda
    /// línea.
    private func strip(_ stat: StatDetail, roomy: Bool) -> some View {
        Button { openStat = stat } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(stat.title)
                    .font(.system(size: roomy ? 12.5 : 11.5, weight: palette.duoText == nil ? .regular : .semibold))
                    .foregroundStyle(palette.duoText ?? palette.secondaryLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(stat.strip.masked(hidesAmounts))
                    .amountVeil()
                    .font(.system(size: roomy ? 23 : 19, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(stat.amountColor ?? palette.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if roomy, let caption = stat.caption {
                    Text(caption.masked(hidesAmounts))
                        .amountVeil()
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(palette.tertiaryLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, roomy ? 15 : 13)
            .padding(.vertical, roomy ? 13 : 10)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stat.title + ": " + stat.strip.masked(hidesAmounts))
    }

    /// Lo que comparten los gráficos: los días del mes, hasta dónde hay datos
    /// y el gasto de cada uno.
    private struct MonthSeries {
        let days: [Date]
        let labels: [String]
        /// Días con datos: hasta hoy en el mes en curso, todos en uno pasado.
        let elapsed: Int
        /// Gasto de cada día con datos.
        let daily: [Double]
        let cumulative: [Double]

        var lastIndex: Int { max(0, elapsed - 1) }
    }

    private func monthSeries(_ totals: PeriodTotals) -> MonthSeries {
        let days = month.days
        let elapsed = min(days.count, max(1, month.elapsedDays))
        let daily = Array(totals.dailySpent.prefix(elapsed).map(\.total))
        return MonthSeries(days: days,
                           labels: days.map(dayMonth),
                           elapsed: elapsed,
                           daily: daily,
                           cumulative: Self.running(daily))
    }

    private static func running(_ values: [Double]) -> [Double] {
        var sum = 0.0
        return values.map { sum = Money.add(sum, $0); return sum }
    }

    private func stats(totals: PeriodTotals, expenses: [Expense], incomes: [IncomeSnapshot]) -> [StatDetail] {
        let chosen = DashboardStatsSettings.decode(statsRaw)
        guard !chosen.isEmpty else { return [] }
        let series = monthSeries(totals)

        return chosen.compactMap { kind in
            switch kind {
            case .net:           return netStat(totals, series, incomes: incomes)
            case .pace:          return paceStat(totals, series)
            case .perDay:        return perDayStat(totals, series)
            case .biggest:       return biggestStat(totals, series, expenses: expenses)
            case .topDay:        return topDayStat(series, expenses: expenses)
            case .noSpendStreak: return streakStat(series)
            case .limitsOver:    return limitsStat()
            }
        }
    }

    // MARK: Cada stat

    /// Sólo con ingresos: sin ellos sería el gasto con el signo cambiado.
    private func netStat(_ totals: PeriodTotals, _ s: MonthSeries, incomes: [IncomeSnapshot]) -> StatDetail? {
        guard let balance = totals.balance else { return nil }
        let positive = Money.cents(balance) >= 0
        let sign = positive ? "+" : "–"

        // Ingresos por día, con el mismo criterio que el total: sin traslados
        // ni abonos a deudas.
        let calendar = Period.calendar
        let range = month.interval
        var incomeCents: [Date: Int] = [:]
        for income in incomes where !income.isTransfer && !income.isDebtPayment
            && income.date >= range.start && income.date < range.end {
            incomeCents[calendar.startOfDay(for: income.date), default: 0]
                += Accounting.penCents(income, fallbackRate: rate)
        }
        let incomeDaily = s.days.prefix(s.elapsed).map { Money.value(incomeCents[$0] ?? 0) }
        let incomeCumulative = Self.running(incomeDaily)

        let tips = s.labels.indices.map { k -> String in
            guard k < s.elapsed else { return s.labels[k] }
            let net = Money.subtract(incomeCumulative[k], s.cumulative[k])
            return s.labels[k] + " · " + (Money.cents(net) >= 0 ? "" : "–") + Money.formatCompact(abs(net))
        }

        return StatDetail(
            kind: .net,
            amount: sign + Money.format(abs(balance)),
            amountColor: positive ? palette.income : palette.expenseText,
            detail: "La diferencia entre tus ingresos y tus gastos de " + monthName.lowercased() + ".",
            tiles: [StatFigure(label: "Ingresos", value: Money.formatCompact(totals.income), color: palette.income),
                    StatFigure(label: "Gastos", value: Money.formatCompact(totals.spent))],
            strip: sign + Money.formatCompact(abs(balance)),
            caption: "Ingresos " + Money.formatCompact(totals.income),
            visual: .chart(StatChart(
                series: [.init(values: incomeCumulative, role: .income, name: "Ingresos", step: true),
                         .init(values: s.cumulative, role: .spend, name: "Gastos", area: true)],
                labels: s.labels,
                tips: tips,
                defaultIndex: s.lastIndex,
                yMax: max(totals.income, totals.spent) * 1.08)))
    }

    /// Sólo con presupuesto, y sin una cuenta elegida: el presupuesto es del
    /// mes entero, no de una tarjeta.
    private func paceStat(_ totals: PeriodTotals, _ s: MonthSeries) -> StatDetail? {
        guard filter.selection == nil,
              let pace = BudgetStore.pace(monthlyBudget: monthlyBudget, enabled: budgetEnabled,
                                          for: month, spent: totals.spent) else { return nil }
        let n = s.days.count
        let ideal = (0..<n).map { Money.multiply(pace.target, by: Double($0 + 1) / Double(n)) }

        return StatDetail(
            kind: .pace,
            amount: "\(pace.usedPercent)%",
            amountColor: pace.status == .over ? palette.expenseText : nil,
            detail: pace.message,
            tiles: [StatFigure(label: "Gastado", value: Money.formatCompact(pace.spent)),
                    StatFigure(label: "Presupuesto", value: Money.formatCompact(pace.target))],
            strip: "\(pace.usedPercent)%",
            caption: "Lo esperado: \(pace.expectedPercent)%",
            visual: .chart(StatChart(
                series: [.init(values: s.cumulative, role: .spend, name: "Gastado", area: true),
                         .init(values: ideal, role: .ideal, name: "Ideal", dashed: true)],
                labels: s.labels,
                tips: s.labels.indices.map { k in
                    s.labels[k] + " · " + Money.formatCompact(k < s.elapsed ? s.cumulative[k] : ideal[k])
                },
                defaultIndex: s.lastIndex,
                yMax: max(pace.target, totals.spent) * 1.04)))
    }

    private func perDayStat(_ totals: PeriodTotals, _ s: MonthSeries) -> StatDetail? {
        guard Money.cents(totals.spent) > 0 else { return nil }
        let pace = BudgetStore.pace(monthlyBudget: monthlyBudget, enabled: budgetEnabled,
                                    for: month, spent: totals.spent)
        let available = filter.selection == nil ? pace?.availablePerDay : nil
        let remainingDays = month.remainingDays
        let average = s.cumulative.enumerated().map { Money.divide($1, by: $0 + 1) }

        var series: [StatChart.Series] = [.init(values: average, role: .spend, name: "Promedio", area: true)]
        if let available {
            series.append(.init(values: Array(repeating: available, count: s.days.count),
                                role: .income, name: "Disponible", dashed: true))
        }

        return StatDetail(
            kind: .perDay,
            amount: Money.format(totals.averagePerDay),
            detail: "Tu gasto promedio diario en lo que va de " + monthName.lowercased() + ".",
            tiles: [StatFigure(label: "Promedio", value: Money.formatCompact(totals.averagePerDay)),
                    available.map { StatFigure(label: "Disponible/día", value: Money.formatCompact($0), color: palette.income) }
                        ?? StatFigure(label: "Quedan", value: remainingDays == 1 ? "1 día" : "\(remainingDays) días")],
            strip: Money.formatCompact(totals.averagePerDay),
            caption: available.map { "Disponible " + Money.formatCompact($0) + "/día" }
                ?? (remainingDays == 0 ? "Mes cerrado" : remainingDays == 1 ? "Queda 1 día" : "Quedan \(remainingDays) días"),
            visual: .chart(StatChart(
                series: series,
                labels: s.labels,
                tips: s.labels.indices.map { k in
                    s.labels[k] + (k < average.count ? " · " + Money.formatCompact(average[k]) : "")
                },
                defaultIndex: s.lastIndex,
                yMax: max(average.max() ?? 0, available ?? 0) * 1.1)))
    }

    private func biggestStat(_ totals: PeriodTotals, _ s: MonthSeries, expenses: [Expense]) -> StatDetail? {
        guard let biggest = biggestExpense(in: expenses) else { return nil }
        let cost = Accounting.netCostInPEN(biggest, fallbackRate: rate)
        let name = Accounting.displayName(biggest.merchant)
        let index = s.days.firstIndex { Period.calendar.isDate($0, inSameDayAs: biggest.date) } ?? s.lastIndex

        return StatDetail(
            kind: .biggest,
            amount: Money.format(cost),
            detail: "Tu gasto más grande de " + monthName.lowercased() + ": "
                + name + ", el " + longDay(biggest.date) + ".",
            tiles: [StatFigure(label: "Comercio", value: name),
                    StatFigure(label: "Del mes", value: Money.formatPercent(cost, of: totals.spent))],
            strip: Money.formatCompact(cost),
            caption: name,
            visual: dailyChart(s, defaultIndex: index))
    }

    /// El día del mes con más gasto. La tira dice sólo la fecha; el monto y
    /// qué lo hizo, al abrirla.
    private func topDayStat(_ s: MonthSeries, expenses: [Expense]) -> StatDetail? {
        guard let index = s.daily.indices.max(by: { Money.cents(s.daily[$0]) < Money.cents(s.daily[$1]) }),
              Money.cents(s.daily[index]) > 0 else { return nil }
        let day = s.days[index]
        let total = s.daily[index]
        let ofDay = expenses.filter { $0.countsAsSpending && Period.calendar.isDate($0.date, inSameDayAs: day) }
        let main = ofDay.max { Accounting.netCostInPEN($0, fallbackRate: rate) < Accounting.netCostInPEN($1, fallbackRate: rate) }
        let weekday = day.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "es_ES")))
        let count = ofDay.count == 1 ? "1 movimiento" : "\(ofDay.count) movimientos"

        return StatDetail(
            kind: .topDay,
            amount: longDay(day),
            detail: "El " + weekday + " fue tu día de más gasto en " + monthName.lowercased() + ": "
                + Money.format(total) + " en " + count + ".",
            tiles: [StatFigure(label: "Gastado", value: Money.formatCompact(total)),
                    StatFigure(label: "Lo principal", value: main.map { Accounting.displayName($0.merchant) } ?? "—")],
            strip: s.labels[index],
            caption: Money.formatCompact(total) + " · " + count,
            visual: dailyChart(s, defaultIndex: index))
    }

    /// Días del mes sin gastar: hasta hoy en el mes en curso, el mes entero en
    /// uno pasado. Las rachas quedan como detalle. Hace falta algún
    /// movimiento: sin datos, todo el mes sería «sin gastar».
    private func streakStat(_ s: MonthSeries) -> StatDetail? {
        guard !self.expenses.isEmpty else { return nil }
        let free = s.daily.prefix(s.elapsed).map { Money.cents($0) <= 0 }

        var current = 0
        for isFree in free.reversed() {
            guard isFree else { break }
            current += 1
        }
        var best = 0, run = 0
        for isFree in free {
            run = isFree ? run + 1 : 0
            best = max(best, run)
        }
        let freeCount = free.filter { $0 }.count
        let days: (Int) -> String = { $0 == 1 ? "1 día" : "\($0) días" }

        let detail = isCurrentMonth
            ? "Días de " + monthName.lowercased() + " sin registrar un gasto, contando hoy."
            : "Días de " + monthName.lowercased() + " sin registrar un gasto."

        return StatDetail(
            kind: .noSpendStreak,
            amount: days(freeCount),
            amountColor: freeCount > 0 ? palette.income : nil,
            detail: detail,
            tiles: [StatFigure(label: isCurrentMonth ? "Racha actual" : "Con gasto",
                             value: isCurrentMonth ? days(current) : "\(free.count - freeCount)"),
                    StatFigure(label: "Racha más larga", value: days(best))],
            strip: days(freeCount),
            caption: "\(freeCount) de \(free.count) días",
            visual: .days(s.days.indices.map { k in
                                k >= s.elapsed ? .future : free[k] ? .free : .spent
                            },
                          start: s.labels.first ?? "", end: s.labels.last ?? ""))
    }

    /// Las categorías que pasaron su límite en el ciclo del mes mostrado. Como
    /// Ritmo, sin una cuenta elegida: el límite es de la categoría entera.
    private func limitsStat() -> StatDetail? {
        guard filter.selection == nil, !limitStatuses.isEmpty else { return nil }
        let over = limitStatuses.filter(\.isOver).sorted { Money.cents($0.overBy) > Money.cents($1.overBy) }
        let near = limitStatuses.filter { $0.level == .cerca }.count
        let total = limitStatuses.count

        return StatDetail(
            kind: .limitsOver,
            amount: "\(over.count) de \(total)",
            amountColor: over.isEmpty ? nil : palette.negative,
            detail: over.isEmpty
                ? "Ninguna categoría con límite se pasó en su ciclo actual."
                : "Categorías que ya gastaron más que su límite en su ciclo actual.",
            tiles: [StatFigure(label: "Con límite", value: "\(total)"),
                    StatFigure(label: "Cerca del límite", value: "\(near)",
                             color: near > 0 ? palette.warning : nil)],
            strip: "\(over.count) de \(total)",
            caption: near == 0 ? "Ninguna cerca" : near == 1 ? "1 cerca del límite" : "\(near) cerca del límite",
            visual: .list(over.prefix(4).map {
                              StatListItem(name: $0.category, value: Money.formatCompact($0.overBy) + " arriba")
                          },
                          more: max(0, over.count - 4)))
    }

    /// El gasto de cada día, con la marca en `defaultIndex`.
    private func dailyChart(_ s: MonthSeries, defaultIndex: Int) -> StatVisual {
        .chart(StatChart(
            series: [.init(values: s.daily, role: .spend, name: "Gasto diario", area: true)],
            labels: s.labels,
            tips: s.labels.indices.map { k in
                s.labels[k] + (k < s.daily.count ? " · " + Money.formatCompact(s.daily[k]) : "")
            },
            defaultIndex: defaultIndex,
            yMax: (s.daily.max() ?? 0) * 1.08))
    }

    /// «12 de setiembre», con el nombre de mes de la app.
    private func longDay(_ date: Date) -> String {
        "\(Period.calendar.component(.day, from: date)) de " + Period.spanishMonthName(for: date).lowercased()
    }

    /// El gasto que más te costó en el mes mostrado. Lo mismo que cuenta en el
    /// total: sin traslados, anulaciones ni lo que ya te devolvieron.
    private func biggestExpense(in expenses: [Expense]) -> Expense? {
        let range = month.interval
        return expenses
            .filter { $0.countsAsSpending && $0.date >= range.start && $0.date < range.end }
            .max { Accounting.netCostInPEN($0, fallbackRate: rate) < Accounting.netCostInPEN($1, fallbackRate: rate) }
            .flatMap { Money.cents(Accounting.netCostInPEN($0, fallbackRate: rate)) > 0 ? $0 : nil }
    }

    // MARK: - Cuadrícula

    private func grid(totals: PeriodTotals, expenses: [Expense], incomes: [Income]) -> some View {
        let range = month.interval
        let movementCount = expenses.filter { !$0.isTransfer && !$0.isSplit && $0.date >= range.start && $0.date < range.end }.count
            + incomes.filter { !$0.isTransfer && $0.date >= range.start && $0.date < range.end }.count
        let hasPending = !unclassified.isEmpty

        // El globo se cuenta dentro de la tarjeta, no aquí: marcar algo como
        // visto sólo vuelve a dibujar esa tarjeta, no el dashboard entero.
        let keys = movementKeys
        let historial = tile(title: "Historial", badge: { NewMovements.shared.unseen(in: keys).count },
                             action: { onOpen(.movements) }) {
            bigNumber("\(movementCount)", caption: movementCount == 1 ? "movimiento este mes" : "movimientos este mes")
        }
        // Las categorías que pasaron su límite, con el mismo globo que
        // Historial.
        let overLimits = limitStatuses.filter(\.isOver).count
        let categorias = tile(title: "Categorías", badge: { overLimits },
                              badgeLabel: { $0 == 1 ? "1 categoría pasó su límite" : "\($0) categorías pasaron su límite" },
                              action: { onOpen(.categories) }) {
            topCategories(totals)
        }
        let amigos = tile(title: "Amigos", action: { onOpen(.social) }) {
            FriendsSummary()
        }

        // Dos columnas en vertical; en horizontal (o en iPad) caben las
        // cuatro en una fila.
        return Grid(horizontalSpacing: Self.gridSpacing, verticalSpacing: Self.gridSpacing) {
            if isWide {
                GridRow {
                    thirdTile(totals: totals, expenses: expenses, hasPending: hasPending)
                    historial
                    categorias
                    amigos
                }
            } else {
                GridRow {
                    thirdTile(totals: totals, expenses: expenses, hasPending: hasPending)
                    historial
                }
                GridRow {
                    categorias
                    amigos
                }
            }
        }
    }

    private var isWide: Bool {
        verticalSizeClass == .compact || horizontalSizeClass == .regular
    }

    /// Pendientes mientras haya algo por clasificar; si no, Etiquetas.
    @ViewBuilder
    private func thirdTile(totals: PeriodTotals, expenses: [Expense], hasPending: Bool) -> some View {
        let range = month.interval
        if hasPending {
            tile(title: "Pendientes", action: { onOpen(.pending) }) {
                // Movimientos, no comercios: es lo que cuenta Pendientes
                // («Todo el historial (N)»), y las dos cifras suman eso.
                let count = unclassified.filter { $0.date >= range.start && $0.date < range.end }.count
                let earlierPending = unclassified.filter { $0.date < range.start }.count
                VStack(alignment: .leading, spacing: 4) {
                    bigNumber("\(count)",
                              caption: isCurrentMonth ? "de este mes" : "de " + monthName.lowercased(),
                              tint: count > 0 ? accent.secondaryOnSurface(scheme) : nil)
                    if earlierPending > 0 {
                        Text("\(earlierPending) de meses anteriores")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.tertiaryLabel)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
        } else {
            tile(title: "Etiquetas", action: { onOpen(.tags) }) {
                let used = Set(expenses.filter { $0.date >= range.start && $0.date < range.end }
                    .flatMap(\.tags)).count
                bigNumber("\(used)", caption: used == 1 ? "usada este mes" : "usadas este mes")
            }
        }
    }

    /// Entre las tiras de stats y entre las tarjetas de la cuadrícula: el
    /// mismo, para que las columnas de arriba y abajo cuadren.
    private static let gridSpacing: CGFloat = 14

    private func tile<Content: View>(title: String, badge: @escaping () -> Int = { 0 },
                                     badgeLabel: @escaping (Int) -> String = {
                                         $0 == 1 ? "1 movimiento nuevo" : "\($0) movimientos nuevos"
                                     },
                                     action: @escaping () -> Void,
                                     @ViewBuilder content: @escaping () -> Content) -> some View {
        DashboardTile(title: title, badge: badge, badgeLabel: badgeLabel, action: action, content: content)
    }

    private func bigNumber(_ value: String, caption: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 30, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(tint ?? palette.label)
            Text(caption)
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryLabel)
        }
    }

    @ViewBuilder
    private func topCategories(_ totals: PeriodTotals) -> some View {
        let top = totals.byCategory.filter { $0.category != Accounting.unclassified }.prefix(2)

        if top.isEmpty {
            Text(Money.cents(totals.spent) > 0 ? "Todo sin categoría" : "Sin gastos aún")
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryLabel)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(top)) { category in
                    HStack(spacing: 9) {
                        MovementIcon(icon: CategoryStyle.icon(for: category.category),
                                     color: CategoryStyle.color(for: category.category, accent: accent.color),
                                     size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(category.category)
                                .font(.system(size: 13.5))
                                .foregroundStyle(palette.label)
                                .lineLimit(1)
                            Text(Money.format(category.total).masked(hidesAmounts))
                                .amountVeil()
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(palette.secondaryLabel)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

}


/// El dashboard con su mes. Guarda cuántos meses se retrocedió para que
/// `DashboardView` se reconstruya —con consultas del mes nuevo— al cambiarlo.
struct DashboardScreen: View {
    let progress: ScrollProgress
    let onOpen: (AppSection) -> Void
    let onSettings: () -> Void

    @State private var monthOffset = 0

    var body: some View {
        DashboardView(monthOffset: $monthOffset,
                      progress: progress,
                      onOpen: onOpen,
                      onSettings: onSettings)
    }
}

/// Con qué `StoreRevision` se armó cada lectura del historial del dashboard.
private final class LoadedRevisions {
    var catalog = -1
    var brief = -1
}

// MARK: - Tarjetas de la cuadrícula

/// Una tarjeta de la cuadrícula del dashboard.
///
/// El globo y el contenido se piden **dentro** de su cuerpo: lo que lean
/// (movimientos vistos, amigos, cobros) queda ligado a esta tarjeta, y un
/// cambio ahí la vuelve a dibujar sólo a ella, no al dashboard con sus totales,
/// gráfico y stats.
private struct DashboardTile<Content: View>: View {
    let title: String
    let badge: () -> Int
    let badgeLabel: (Int) -> String
    let action: () -> Void
    let content: () -> Content

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        let badge = self.badge()

        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.label)
                    // Movimientos que aún no viste en Historial: el mismo
                    // globo que las solicitudes de Social.
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 11, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(palette.expense, in: Capsule())
                            .transition(.scale.combined(with: .opacity))
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.duoText ?? palette.secondaryLabel)
                }
                content()
                // Sin `Spacer` al final: el `VStack` le sumaba sus 12 pt de
                // separación y cada tarjeta quedaba con ese hueco de más
                // abajo. El marco de abajo ya la alinea arriba.
            }
            .padding(15)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: 128)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            // Lo que asoma por el borde (el personaje de Amigos) se corta ahí.
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(badge > 0 ? badgeLabel(badge) : "")
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: badge)
    }
}

/// El pingüino del perfil y lo que te deben: los gastos por cobrar que aún no
/// te pagan del todo. Sin nada por cobrar, cuántos amigos tienes.
///
/// El personaje va grande, asomando por la esquina de abajo y cortado por el
/// borde de la tarjeta: con el avatar chico de antes la tarjeta se veía vacía
/// al lado de Categorías. Con el ojito del resumen cerrado, lo que te deben
/// también se tapa.
///
/// Vista propia, con su consulta: amigos, solicitudes y cobros cambian con el
/// tiempo real de Supabase, y leídos desde el dashboard lo recalculaban todo
/// en cada aviso —también a mitad de un deslizamiento—.
private struct FriendsSummary: View {
    /// Lo marcado por cobrar: poco.
    @Query(filter: #Predicate<Expense> { $0.isDebt && !$0.isTransfer })
    private var debtExpenses: [Expense]

    @Environment(\.hidesAmounts) private var hidesAmounts
    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    /// Lo que asoma el personaje por debajo del borde de la tarjeta.
    static let characterHeight: CGFloat = 82

    var body: some View {
        let open = debtExpenses.filter { Money.cents(Accounting.outstanding(of: $0)) > 0 }
        let owed = Money.sum(open.map { Accounting.outstanding(of: $0) })
        let requests = FriendsManager.shared.incomingRequests.count + PaymentReminders.shared.inbox.count
        let friends = FriendsManager.shared.friends.count

        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                if open.isEmpty {
                    Text(friends == 0 ? "Invita" : "\(friends)")
                        .font(.system(size: 22, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(palette.label)
                    Text(friends == 1 ? "amigo" : (friends == 0 ? "a un amigo" : "amigos"))
                        .font(.system(size: 13))
                        .foregroundStyle(palette.secondaryLabel)
                } else {
                    Text(Money.formatCompact(owed).masked(hidesAmounts))
                        .amountVeil()
                        .font(.system(size: 22, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(palette.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                    Text("te deben")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.secondaryLabel)
                    Text(open.count == 1 ? "1 cobro" : "\(open.count) cobros")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.secondaryLabel)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // El personaje no ocupa sitio en el diseño de la tarjeta: se pinta en
        // la esquina y el alto lo siguen poniendo las cifras (y Categorías).
        .background(alignment: .bottomTrailing) {
            PenguinView(look: SocialProfileStore.shared.penguin)
                .frame(height: Self.characterHeight)
                .overlay(alignment: .topTrailing) {
                    if requests > 0 {
                        Text(requests > 99 ? "99+" : "\(requests)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(palette.expense, in: Capsule())
                            .offset(x: -4, y: 4)
                    }
                }
                // Hasta el borde de la tarjeta (su relleno es de 15): la
                // panza queda cortada, como asomándose.
                .offset(x: 6, y: 15 + 16)
                .accessibilityHidden(true)
        }
    }
}
