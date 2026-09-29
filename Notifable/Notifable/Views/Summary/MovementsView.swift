import SwiftUI
import SwiftData

/// Historial › Movimientos (`1b`): la lista completa, agrupada por día.
///
/// Se entra desde la tarjeta «Historial» del dashboard. Aquí vive **el único
/// buscador de la app**: antes había uno en el inicio y otro en Pendientes,
/// cada uno buscando sobre un conjunto distinto.
///
/// Arriba, **tus cuentas**: filtran la lista por la tarjeta o billetera de la
/// que salió —o a la que llegó— cada movimiento. Es el mismo filtro que el
/// chip del dashboard (`AccountFilter`): elegir BBVA aquí lo elige allá.
/// «Editar» abre «Tus cuentas» (`1c`), donde se marca qué es tuyo; lo que va
/// de una cuenta tuya a otra no es gasto ni ingreso y no sale en la lista.
///
/// Lo programado que espera confirmación ya no vive aquí: está en
/// «Comprometido este mes», en el dashboard.
struct MovementsView: View {
    @Binding var scrollToTopTrigger: Bool
    let progress: ScrollProgress

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @Query(sort: \Expense.date, order: .reverse) private var expenses: [Expense]
    @Query(sort: \Income.date, order: .reverse) private var incomes: [Income]
    @StateObject private var rates = ExchangeRateService.shared
    @StateObject private var accountBook = AccountBook.shared

    @State private var filter = AccountFilter.shared
    @State private var searchText = ""
    @State private var kind: Kind = .gastos
    @State private var visibleCount = pageSize
    @State private var selectedExpense: Expense?
    @State private var selectedIncome: Income?
    @State private var splitting: Expense?
    /// Pagos divididos que el usuario plegó. Abiertos por defecto: la división
    /// es lo que se quiere ver.
    @State private var collapsedSplits: Set<UUID> = []
    @State private var showsAccounts = false
    /// Las tarjetas ocupan casi una pantalla chica: se pliegan con la
    /// flechita y se quedan como las dejaste.
    @AppStorage("movements.accountsCollapsed") private var accountsCollapsed = false
    /// Los movimientos del correo que no habías visto: se resaltan dos
    /// segundos al entrar y quedan como vistos.
    @State private var highlighted: Set<String> = []
    /// Armado fuera del cuerpo: necesita el historial entero, y antes se
    /// volvía a armar en cada dibujado —al abrir una hoja, al escribir en el
    /// buscador—.
    @State private var catalog = AccountCatalog(expenses: [], incomes: [])
    @FocusState private var searchFocused: Bool

    /// «Seleccionar», como en Fotos: la misma barra que Pendientes
    /// (Categorizar · Etiquetas · Eliminar) para corregir en bloque sin
    /// tener que ir allá. Sólo en Gastos.
    @State private var isSelecting = false
    @State private var selected: Set<UUID> = []
    @State private var assigningSelection = false
    @State private var showsTagPicker = false
    @State private var confirmingDelete = false

    /// Gastos, ingresos y —sólo si hay— lo que está por cobrar. Lo sin
    /// categoría ya no se filtra aquí: vive en Pendientes, que es donde se
    /// clasifica.
    enum Kind: Hashable { case gastos, ingresos, porCobrar }

    /// Si hay algo por cobrar. Se lee una
    /// vez por dibujado (`body`), no en cada sitio que lo necesita.
    private var hasDebts: Bool {
        expenses.contains { $0.isDebt && !$0.isTransfer && Money.cents(Accounting.outstanding(of: $0)) > 0 }
    }

    /// Se cargan de 20 en 20, y con botón: la carga automática al llegar al
    /// final deja la lista creciendo bajo el dedo mientras se clasifica, y se
    /// pierde el sitio en el que se iba.
    private static let pageSize = 20

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }
    private var rate: Double { rates.usdToPenRate }

    /// «Tus cuentas» con su flechita. Plegado, dice qué cuenta filtra: el
    /// filtro sigue puesto aunque no se vean las tarjetas.
    private func accountsHeader(_ carousel: [DetectedAccount]) -> some View {
        let chosen = filter.selection.flatMap { key in carousel.first { $0.key == key } }
        return Button {
            withAnimation(.easeInOut(duration: 0.25)) { accountsCollapsed.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text("TUS CUENTAS")
                    .font(.system(size: 11.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(palette.secondaryLabel)
                if accountsCollapsed {
                    Text(chosen.map { accountBook.preferences.name(for: $0) } ?? "Todas")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(chosen == nil ? palette.secondaryLabel : accent.onSurface(scheme))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.secondaryLabel)
                    .rotationEffect(.degrees(accountsCollapsed ? -90 : 0))
            }
            .padding(.horizontal, 2)
            .padding(.bottom, accountsCollapsed ? 12 : 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accountsCollapsed ? "Mostrar tus cuentas" : "Ocultar tus cuentas")
    }

    // MARK: - Datos

    /// - Note: **sin `sorted`**. Las dos consultas ya llegan ordenadas por
    ///   fecha descendente y `filter` conserva el orden, así que ordenar aquí
    ///   era volver a ordenar el historial entero en cada pasada del cuerpo.
    ///
    /// Los traslados entre tus cuentas no están: no son gasto ni ingreso.
    ///
    /// Las partes de un pago dividido tampoco: se dibujan bajo su pago
    /// (`SplitGroupRows`). Sólo si el pago está en la lista —si aún no se
    /// releyó del correo, la parte se ve suelta en vez de desaparecer—.
    private func getSource() -> [TransactionItem] {
        switch kind {
        case .ingresos:
            return incomes.compactMap { $0.isTransfer ? nil : .income($0) }
        case .porCobrar:
            return expenses.compactMap { e in
                (e.isDebt && !e.isTransfer && Money.cents(Accounting.outstanding(of: e)) > 0) ? .expense(e) : nil
            }
        case .gastos:
            let grouped = Set(expenses.lazy.filter(\.isSplit).flatMap(TransactionKey.lookupKeys))
            return expenses.compactMap { e in
                if e.isTransfer { return nil }
                if let key = e.splitOf, grouped.contains(key) { return nil }
                return .expense(e)
            }
        }
    }

    private func filterItems(_ source: [TransactionItem], catalog: AccountCatalog) -> [TransactionItem] {
        let isSearchEmpty = searchText.isEmpty
        let selection = filter.selection
        if selection == nil && isSearchEmpty { return source }
        
        return source.filter { item in
            if let sel = selection, !AccountFilter.keys(of: item, catalog: catalog).contains(sel) { return false }
            if !isSearchEmpty && !item.matches(searchText) { return false }
            return true
        }
    }

    /// Movimientos de la lista actual por cuenta, para las tarjetas del
    /// carrusel.
    private func counts(in source: [TransactionItem], catalog: AccountCatalog) -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in source {
            for key in Set(AccountFilter.keys(of: item, catalog: catalog)) { counts[key, default: 0] += 1 }
        }
        return counts
    }

    /// Agrupados por día: la lista no cambia de gramática entre pantallas.
    private func groups(from items: [TransactionItem]) -> [DayBucket] {
        let calendar = Calendar.current
        var buckets: [Date: [TransactionItem]] = [:]
        for item in items {
            buckets[calendar.startOfDay(for: item.date), default: []].append(item)
        }
        return buckets.keys.sorted(by: >).map { day in
            DayBucket(day: day, items: buckets[day] ?? [])
        }
    }

    var body: some View {
        let catalog = self.catalog
        let carousel = accountBook.preferences.carousel(from: catalog)
        let hasDebts = self.hasDebts
        let source = self.getSource()
        let items = self.filterItems(source, catalog: catalog)
        let visible = Array(items.prefix(visibleCount))
        let buckets = groups(from: visible)
        let splitParts = ExpenseSplit.partsByParent(expenses)

        TrackableScrollView(scrollToTopTrigger: $scrollToTopTrigger) {
            VStack(spacing: 0) {
                ShellTitle(title: "Movimientos", subtitle: subtitle(count: items.count))

                // Con alguna cuenta detectada, aunque ninguna esté marcada
                // como tuya: «Editar» es la puerta para marcarlas.
                if !catalog.accounts.isEmpty {
                    VStack(spacing: 0) {
                        accountsHeader(carousel)

                        if !accountsCollapsed {
                            AccountCarousel(accounts: carousel,
                                            name: { accountBook.preferences.name(for: $0) },
                                            counts: counts(in: source, catalog: catalog),
                                            total: source.count,
                                            selection: $filter.selection,
                                            onEdit: { showsAccounts = true })
                                .padding(.horizontal, -ShellMetrics.sideInset)
                                .padding(.bottom, 12)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    // Una cuenta que dejó de ser tuya ya no está en el
                    // carrusel: el filtro vuelve a «Todas». Fuera del
                    // carrusel, para que valga también plegado.
                    .onChange(of: carousel.map(\.key), initial: true) { _, keys in
                        if let key = filter.selection, !keys.contains(key) { filter.selection = nil }
                    }
                }

                HStack(spacing: 8) {
                    searchField
                    if kind == .gastos { selectButton }
                }
                .padding(.bottom, 12)

                // La tercera opción sólo existe mientras haya algo por
                // cobrar: un filtro que siempre dice «nada» es ruido.
                ShellSegment(items: hasDebts ? [Kind.gastos, .ingresos, .porCobrar]
                                             : [Kind.gastos, .ingresos],
                             selection: $kind,
                             tint: Palette(scheme).expense) { kind in
                    switch kind {
                    case .gastos:    return "Gastos"
                    case .ingresos:  return "Ingresos"
                    case .porCobrar: return "Por cobrar"
                    }
                }
                .padding(.bottom, 18)

                if buckets.isEmpty {
                    emptyState
                } else {
                    // Perezosa: con «Cargar más» la lista crece, y montar
                    // todas las filas de golpe se notaba al deslizar.
                    LazyVStack(spacing: 20) {
                        ForEach(buckets) { bucket in
                            dayBlock(bucket, splitParts: splitParts)
                        }
                    }
                    .padding(.bottom, 20)

                    if visibleCount < items.count {
                        loadMoreButton(remaining: items.count - visibleCount)
                    }
                }
            }
            .padding(.horizontal, ShellMetrics.sideInset)
            .padding(.top, ShellMetrics.contentTopInset)
            .padding(.bottom, selected.isEmpty ? 40 : 110)
        }
        .overlay(alignment: .bottom) {
            if isSelecting && !selected.isEmpty {
                BulkActionBar(count: selected.count,
                              onCategorize: { assigningSelection = true },
                              onTags: { showsTagPicker = true },
                              onDelete: { confirmingDelete = true })
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            progress.update(offset)
        }
        .sheet(isPresented: $showsAccounts) {
            AccountsSheet(catalog: catalog, preferences: accountBook.preferences)
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
        .onChange(of: searchText) { _, _ in visibleCount = Self.pageSize }
        .onChange(of: kind) { _, newKind in
            visibleCount = Self.pageSize
            if newKind != .gastos { endSelection() }
        }
        .onChange(of: filter.selection) { _, _ in visibleCount = Self.pageSize }
        // Al cobrar el último pendiente la opción desaparece: sin esto la
        // lista se quedaba vacía y sin forma de salir.
        .onAppear(perform: rebuildCatalog)
        .task { await showNewMovements() }
        .onChange(of: expenses.count) { _, _ in rebuildCatalog() }
        .onChange(of: incomes.count) { _, _ in rebuildCatalog() }
        .onChange(of: hasDebts) { _, has in
            if !has, kind == .porCobrar { kind = .gastos }
        }
        // Ir a un movimiento desde una hoja: se cierra lo que haya encima y
        // la app abre su detalle.
        .onReceive(NotificationCenter.default.publisher(for: ActivityFocus.notification)) { _ in
            selectedExpense = nil
            selectedIncome = nil
        }
        .sheet(isPresented: $assigningSelection) {
            AssignCategorySheet(context: BulkExpenseEdit.context(for: selectedExpenses, rate: rate),
                                history: expenses) { category, _ in
                BulkExpenseEdit.assign(category, to: selectedExpenses, in: modelContext)
                withAnimation(.easeInOut(duration: 0.25)) { selected.removeAll() }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
        .sheet(isPresented: $showsTagPicker) {
            TagPickerSheet(selected: BulkExpenseEdit.commonTags(selectedExpenses)) {
                BulkExpenseEdit.toggleTag($0, on: selectedExpenses, in: modelContext)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
        .alert(BulkExpenseEdit.deleteTitle(selected: selected.count, deletable: deletableSelection.count),
               isPresented: $confirmingDelete) {
            if deletableSelection.isEmpty {
                Button("Entendido", role: .cancel) {}
            } else {
                Button("Cancelar", role: .cancel) {}
                Button("Eliminar", role: .destructive) {
                    let targets = deletableSelection
                    withAnimation(.easeInOut(duration: 0.25)) {
                        BulkExpenseEdit.delete(targets, in: modelContext)
                        selected.removeAll()
                    }
                }
            }
        } message: {
            Text(BulkExpenseEdit.deleteMessage(selected: selected.count, deletable: deletableSelection.count))
        }
        .sheet(item: $selectedExpense) { ExpenseDetailsView(expense: $0) }
        .sheet(item: $selectedIncome) { IncomeDetailsView(income: $0) }
        .sheet(item: $splitting) { SplitExpenseSheet(parent: $0) }
    }

    /// Resalta lo nuevo y lo da por visto. Si todo lo nuevo son ingresos, abre
    /// en Ingresos para que se vea.
    private func showNewMovements() async {
        let store = NewMovements.shared
        let keys = NewMovements.keys(expenses: expenses, incomes: incomes)
        store.baselineIfNeeded(keys)
        let fresh = store.unseen(in: keys)
        guard !fresh.isEmpty else { return }
        store.markSeen(fresh)

        let hasNewExpense = expenses.contains { NewMovements.key($0).map(fresh.contains) == true }
        if !hasNewExpense, kind == .gastos { kind = .ingresos }
        highlighted = fresh

        try? await Task.sleep(for: .seconds(2))
        withAnimation(.easeOut(duration: 0.6)) { highlighted = [] }
    }

    private func rebuildCatalog() {
        catalog = AccountCatalog(expenses: expenses, incomes: incomes)
    }

    private func subtitle(count: Int) -> String {
        let noun: String
        switch kind {
        case .gastos:    noun = count == 1 ? "gasto" : "gastos"
        case .ingresos:  noun = count == 1 ? "ingreso" : "ingresos"
        case .porCobrar: noun = "por cobrar"
        }
        return "\(count) " + noun + (searchText.isEmpty ? "" : " encontrados")
    }

    // MARK: - Selección

    private var selectedExpenses: [Expense] {
        expenses.filter { selected.contains($0.id) }
    }

    private var deletableSelection: [Expense] {
        BulkExpenseEdit.deletable(selectedExpenses)
    }

    private func toggle(_ expense: Expense) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if selected.contains(expense.id) { selected.remove(expense.id) } else { selected.insert(expense.id) }
        }
    }

    private func endSelection() {
        withAnimation(.snappy(duration: 0.25)) {
            isSelecting = false
            selected.removeAll()
        }
    }

    private var selectButton: some View {
        Button {
            if isSelecting {
                endSelection()
            } else {
                searchFocused = false
                withAnimation(.snappy(duration: 0.25)) { isSelecting = true }
            }
        } label: {
            Text(isSelecting ? "Listo" : "Seleccionar")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent.onSurface(scheme))
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Buscador

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.secondaryLabel)

            TextField(MovementSearch.placeholder, text: $searchText)
                .font(.system(size: 14.5))
                .foregroundStyle(palette.label)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.tertiaryLabel)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(palette.hairline, lineWidth: 0.5))
    }

    // MARK: - Lista

    private func dayBlock(_ bucket: DayBucket, splitParts: [String: [Expense]]) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(MovementDay.shortLabel(for: bucket.day))
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(palette.secondaryLabel)

                Spacer()

                Text(dayTotal(bucket, splitParts: splitParts))
                    .font(.system(size: 13.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(palette.secondaryLabel)
            }
            .padding(.horizontal, 4)

            MovementCard {
                ForEach(Array(bucket.items.enumerated()), id: \.element.id) { index, item in
                    let isNew = NewMovements.key(item).map(highlighted.contains) == true
                    Group {
                        switch item {
                        case .expense(let expense) where expense.isSplit
                            && !ExpenseSplit.parts(of: expense, in: splitParts).isEmpty:
                            SplitGroupRows(parent: expense,
                                           parts: ExpenseSplit.parts(of: expense, in: splitParts),
                                           isExpanded: !collapsedSplits.contains(expense.id),
                                           onToggle: { toggleSplit(expense) },
                                           onOpenPart: { selectedExpense = $0 },
                                           onOpenParent: { selectedExpense = expense },
                                           onEditSplit: { splitting = expense })
                        case .expense(let expense) where isSelecting:
                            let isOn = selected.contains(expense.id)
                            MovementRow(expense: expense,
                                        showsTime: true,
                                        onTap: { toggle(expense) },
                                        selection: isOn)
                        case .expense(let expense):
                            MovementRow(expense: expense,
                                        showsTime: true,
                                        onTap: { selectedExpense = expense })
                        case .income(let income):
                            IncomeRow(income: income, showsTime: true, onTap: { selectedIncome = income })
                        }
                    }
                    .background(palette.expenseSoft.opacity(isNew ? 1 : 0))

                    if index < bucket.items.count - 1 { MovementSeparator() }
                }
            }
        }
    }

    private func toggleSplit(_ parent: Expense) {
        withAnimation(.snappy(duration: 0.25)) {
            if collapsedSplits.contains(parent.id) {
                collapsedSplits.remove(parent.id)
            } else {
                collapsedSplits.insert(parent.id)
            }
        }
    }

    private func dayTotal(_ bucket: DayBucket, splitParts: [String: [Expense]]) -> String {
        if kind == .porCobrar {
            let total = Money.sum(bucket.items.compactMap { item -> Double? in
                guard case .expense(let e) = item else { return nil }
                return Accounting.outstanding(of: e)
            })
            return "falta " + Money.format(total)
        }
        if kind == .ingresos {
            let total = Money.sum(bucket.items.compactMap { item -> Double? in
                guard case .income(let i) = item else { return nil }
                return Accounting.amountInPEN(i, fallbackRate: rate)
            })
            return "+" + Money.format(total)
        }
        // Un pago dividido cuesta cero; lo que suma son sus partes.
        let total = Money.sum(bucket.items.flatMap { item -> [Expense] in
            guard case .expense(let e) = item else { return [] }
            return e.isSplit ? ExpenseSplit.parts(of: e, in: splitParts) : [e]
        }) { Accounting.netCostInPEN($0, fallbackRate: rate) }
        return "–" + Money.format(total)
    }

    private func loadMoreButton(remaining: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                visibleCount += Self.pageSize
            }
        } label: {
            HStack(spacing: 6) {
                Text("Cargar más")
                    .font(.system(size: 14, weight: .semibold))
                Text("(\(remaining))")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondaryLabel)
            }
            .foregroundStyle(accent.onSurface(scheme))
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(palette.surface, in: Capsule())
            .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            ShellEmptyState(icon: "magnifyingglass",
                            title: "Sin resultados para «" + searchText + "»",
                            message: MovementSearch.emptyMessage(for: searchText))
        } else if filter.selection != nil {
            ShellEmptyState(icon: "tray",
                            title: "Nada en esta cuenta",
                            message: "No hay movimientos de esta cuenta en esta lista.")
        } else {
            ShellEmptyState(icon: "tray",
                            title: "Nada por aquí",
                            message: "Cuando llegue un movimiento aparecerá en esta lista.")
        }
    }

    struct DayBucket: Identifiable {
        let day: Date
        let items: [TransactionItem]
        var id: Date { day }
    }
}
