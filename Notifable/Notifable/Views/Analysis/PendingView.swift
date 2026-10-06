import SwiftUI
import SwiftData

/// Pendientes (`2c`): los comercios que la app no supo clasificar.
///
/// Su tarjeta en el dashboard **sólo existe mientras quedan pendientes**
/// (`3d`); al llegar a cero, Etiquetas ocupa su sitio: un destino permanente
/// que casi siempre dice «nada pendiente» es ruido.
///
/// La sugerencia va **dentro del grupo**, no como banner aparte. Antes vivía
/// arriba, en una tarjeta propia, y había que acordarse de a qué comercio se
/// refería mientras se miraba la lista.
///
/// Cada comercio se despliega con la flecha de la derecha y muestra sus
/// movimientos, que se eligen uno a uno: no todo lo de un comercio va siempre
/// a la misma categoría. La selección es por movimiento; tocar el comercio
/// elige (o suelta) todos los suyos.
struct PendingView: View {
    @Binding var scrollToTopTrigger: Bool
    let progress: ScrollProgress

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @Query(sort: \Expense.date, order: .reverse) private var expenses: [Expense]
    @StateObject private var rates = ExchangeRateService.shared

    /// El periodo elegido. `nil` hasta que la pantalla aparece: mientras
    /// tanto vale el de por defecto (`initialScope`), así el primer dibujado
    /// ya sale en el bueno en vez de pasar por «Este mes» y saltar.
    @State private var chosenScope: Scope?
    /// Movimientos elegidos.
    @State private var selected: Set<UUID> = []
    @State private var expanded: Set<String> = []
    @State private var visibleCount = pageSize
    @State private var assigning: AssignTarget?
    @State private var showsBulk = false
    @State private var confirmingDelete = false
    @State private var showsTagPicker = false
    /// Cómo se agrupa la lista. Por día de entrada, igual que Movimientos; se
    /// recuerda si alguien prefiere agrupar por comercio.
    @AppStorage("pendingLayout") private var layout: Layout = .day

    enum Scope: Hashable { case month, all }

    /// Por comercio (una decisión para varios movimientos, lo que más ahorra
    /// al clasificar) o por día, con la misma fila y la misma separación que
    /// Movimientos: un movimiento se reconoce igual en las dos pantallas.
    enum Layout: String { case merchant, day }

    /// De 20 en 20 y con botón, igual que Movimientos: la carga automática al
    /// llegar al final hacía crecer la lista bajo el dedo mientras se
    /// clasificaba.
    private static let pageSize = 20

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }
    private var rate: Double { rates.usdToPenRate }
    private var month: Period { Period(granularity: .mes, reference: Date()) }

    private var scope: Scope { chosenScope ?? initialScope }

    /// Este mes si le queda algo por clasificar; si ya está al día, todo el
    /// historial, que es donde queda lo pendiente.
    private var initialScope: Scope {
        let range = month.interval
        let monthHasPending = expenses.contains {
            $0.category == Accounting.unclassified && $0.countsAsSpending
                && $0.date >= range.start && $0.date < range.end
        }
        return monthHasPending ? .month : .all
    }

    // MARK: - Datos

    private var unclassified: [Expense] {
        // Un traslado entre tus cuentas no se clasifica: no es gasto.
        let all = expenses.filter { $0.category == Accounting.unclassified && $0.countsAsSpending }
        guard scope == .month else { return all }
        let range = month.interval
        return all.filter { $0.date >= range.start && $0.date < range.end }
    }

    private var groups: [Group] {
        let calendar = Period.calendar
        var grouped: [String: [Expense]] = [:]
        for expense in unclassified {
            let startOfMonth = calendar.dateInterval(of: .month, for: expense.date)?.start ?? expense.date
            let key = expense.merchant + "|" + "\(startOfMonth.timeIntervalSince1970)"
            grouped[key, default: []].append(expense)
        }

        return grouped.map { key, items in
            let components = key.components(separatedBy: "|")
            let merchant = components[0]
            let timeInterval = components.count > 1 ? TimeInterval(components[1]) ?? 0 : 0
            let monthStart = Date(timeIntervalSince1970: timeInterval)
            
            return Group(merchant: merchant,
                         monthStart: monthStart,
                         expenses: items.sorted { $0.date > $1.date },
                         total: Money.sum(items) { Accounting.netCostInPEN($0, fallbackRate: rate) })
        }
        .sorted {
            $0.monthStart == $1.monthStart 
                ? ($0.mostRecent == $1.mostRecent ? $0.merchant < $1.merchant : $0.mostRecent > $1.mostRecent)
                : $0.monthStart > $1.monthStart
        }
    }

    /// Porcentaje de comercios ya clasificados en el alcance visible. Es la
    /// cifra que hace que valga la pena vaciar la bandeja.
    ///
    /// Cuenta comercios, no grupos: un grupo es comercio × mes, y en «Todo el
    /// historial» restar grupos de comercios daba porcentajes negativos.
    private func progressFraction(pendingMerchants: Int) -> Double {
        let range = month.interval
        let scopeExpenses = scope == .month
            ? expenses.filter { $0.date >= range.start && $0.date < range.end }
            : expenses
        let merchants = Set(scopeExpenses.map(\.merchant))
        guard !merchants.isEmpty else { return 1 }
        return min(max(Double(merchants.count - pendingMerchants) / Double(merchants.count), 0), 1)
    }

    private func suggestion(for group: Group) -> CategorySuggestion? {
        SuggestionEngine.suggest(for: group.merchant, rules: MerchantRules.all())
    }

    var body: some View {
        let groups = self.groups
        let visible = Array(groups.prefix(visibleCount))
        let total = Money.sum(groups) { $0.total }
        let movementCount = groups.reduce(0) { $0 + $1.expenses.count }
        let merchantCount = Set(groups.map(\.merchant)).count
        let hasAnyPending = expenses.contains { $0.category == Accounting.unclassified && $0.countsAsSpending }

        TrackableScrollView(scrollToTopTrigger: $scrollToTopTrigger) {
            VStack(spacing: 0) {
                ShellTitle(title: "Pendientes",
                           subtitle: groups.isEmpty ? nil
                               : (movementCount == 1 ? "1 movimiento" : "\(movementCount) movimientos")
                                 + (merchantCount == 1 ? " en 1 comercio · " : " en \(merchantCount) comercios · ")
                                 + Money.format(total))

                if !hasAnyPending {
                    ShellEmptyState(icon: "checkmark.circle",
                                    title: "Pendientes vacío",
                                    message: "Todos tus gastos están clasificados.")
                } else {
                    // El segmento se queda aunque el mes esté al día: la
                    // pestaña existe por lo pendiente de meses anteriores, y
                    // sin él no habría forma de llegar a verlo.
                    // Movimientos en los dos: son las mismas cifras que la
                    // tarjeta del dashboard («N de este mes · M de meses
                    // anteriores»), y el historial es su suma.
                    let allPending = expenses.filter { $0.category == Accounting.unclassified && $0.countsAsSpending }
                    let range = month.interval
                    let monthCount = allPending.filter { $0.date >= range.start && $0.date < range.end }.count
                    ShellSegment(items: [Scope.month, .all],
                                 selection: Binding(get: { scope }, set: { chosenScope = $0 }),
                                 tint: accent.color) {
                        $0 == .month ? "Este mes (\(monthCount))" : "Todo el historial (\(allPending.count))"
                    }
                    .padding(.bottom, 14)

                    if groups.isEmpty {
                        ShellEmptyState(icon: "checkmark.circle",
                                        title: "Este mes está al día",
                                        message: "Lo que falta clasificar es de meses anteriores. Míralo en «Todo el historial».")
                    } else {
                        progressCard(pendingMerchants: merchantCount)
                            .padding(.bottom, 12)

                        bulkButton
                            .padding(.bottom, 12)

                        layoutToggle
                            .padding(.bottom, 12)

                        selectionBar(groups: groups)
                            .padding(.bottom, 10)

                        if layout == .merchant {
                            VStack(spacing: 10) {
                                ForEach(Array(visible.enumerated()), id: \.element.id) { index, group in
                                    let isFirstOfMonth = index == 0 || visible[index - 1].monthStart != group.monthStart
                                    if isFirstOfMonth {
                                        let monthName = Period.spanishMonthName(for: group.monthStart)
                                        let year = Period.calendar.component(.year, from: group.monthStart)
                                        ShellSectionHeader(title: "\(monthName) \(year)")
                                            .padding(.top, index == 0 ? 0 : 16)
                                            .padding(.horizontal, 4)
                                    }
                                    groupCard(group)
                                }
                            }
                            .padding(.bottom, 10)

                            if visibleCount < groups.count {
                                loadMoreButton(remaining: groups.count - visibleCount)
                            }
                        } else {
                            let movements = unclassified
                            LazyVStack(spacing: 20) {
                                ForEach(dayBuckets(Array(movements.prefix(visibleCount)))) { bucket in
                                    dayBlock(bucket)
                                }
                            }
                            .padding(.bottom, 10)

                            if visibleCount < movements.count {
                                loadMoreButton(remaining: movements.count - visibleCount)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, ShellMetrics.sideInset)
            .padding(.top, ShellMetrics.contentTopInset)
            .padding(.bottom, selected.isEmpty ? ShellMetrics.contentBottomInset
                                               : ShellMetrics.contentBottomInset + 60)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            progress.update(offset)
        }
        .overlay(alignment: .bottom) {
            if !selected.isEmpty {
                assignBar
                    .padding(.bottom, ShellMetrics.contentBottomInset - 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: scope) { _, _ in
            selected.removeAll()
            visibleCount = Self.pageSize
        }
        // Lo elegido se conserva al cambiar de agrupación: son los mismos
        // movimientos vistos de otra forma.
        .onChange(of: layout) { _, _ in visibleCount = Self.pageSize }
        .onAppear {
            // Se fija el de entrada: clasificar lo último del mes no cambia de
            // periodo bajo el dedo (se ve «Este mes está al día»).
            if chosenScope == nil { chosenScope = initialScope }
        }
        .alert(deleteTitle, isPresented: $confirmingDelete) {
            if deletable.isEmpty {
                Button("Entendido", role: .cancel) {}
            } else {
                Button("Cancelar", role: .cancel) {}
                Button("Eliminar", role: .destructive) { deleteSelected() }
            }
        } message: {
            Text(deleteMessage)
        }
        .sheet(isPresented: $showsTagPicker) {
            TagPickerSheet(selected: BulkExpenseEdit.commonTags(selectedExpenses)) {
                BulkExpenseEdit.toggleTag($0, on: selectedExpenses, in: modelContext)
            }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
        .sheet(isPresented: $showsBulk) {
            BulkClassifyView(onlyThisMonth: scope == .month)
        }
        .sheet(item: $assigning) { target in
            AssignCategorySheet(context: target.context, history: expenses,
                                onAssignRules: { category, rules in
                apply(category, to: target.ids, rules: rules)
            })
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
    }

    // MARK: - Progreso

    private func progressCard(pendingMerchants: Int) -> some View {
        let fraction = progressFraction(pendingMerchants: pendingMerchants)

        return ShellCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Clasificado")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.label)
                    Spacer()
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(accent.onSurface(scheme))
                }

                PaceBar(fraction: fraction, expected: nil, status: .ok, height: 6)
            }
        }
    }

    // MARK: - En bloque

    /// La entrada a la clasificación masiva (`5j`): todos los comercios con
    /// su destino sugerido, aceptados de una vez.
    private var bulkButton: some View {
        Button { showsBulk = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                Text("Clasificar en bloque")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(accent.onSurface(scheme))
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(accent.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Selección

    @ViewBuilder
    private func selectionBar(groups: [Group]) -> some View {
        let allIDs = Set(groups.flatMap { $0.expenses.map(\.id) })
        let allSelected = !allIDs.isEmpty && allIDs.isSubset(of: selected)

        HStack {
            Text(selected.isEmpty ? (layout == .merchant ? "Toca un comercio o ábrelo con la flecha"
                                                         : "Toca los movimientos que quieras clasificar")
                                  : selected.count == 1 ? "1 movimiento elegido"
                                  : "\(selected.count) movimientos elegidos")
                .font(.system(size: 12.5))
                .foregroundStyle(palette.secondaryLabel)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selected = allSelected ? [] : allIDs
                }
            } label: {
                Text(allSelected ? "Quitar selección" : "Seleccionar todo")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(accent.onSurface(scheme))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
    }

    /// Tres acciones sobre lo elegido: categorizar (la principal, rellena),
    /// etiquetar y eliminar. Lo que se elige en Pendientes a veces no es un
    /// gasto que clasificar sino uno que sobra (un duplicado, una prueba), o
    /// uno que hay que marcar antes de decidir su categoría.
    private var assignBar: some View {
        BulkActionBar(count: selected.count,
                      onCategorize: {
                          assigning = AssignTarget(ids: selected, groups: groups,
                                                   earlier: Self.earlierPending(than: selected, in: expenses).count)
                      },
                      onTags: { showsTagPicker = true },
                      onDelete: { confirmingDelete = true })
    }

    // MARK: - Agrupar

    private var layoutToggle: some View {
        HStack(spacing: 6) {
            Text("Agrupar")
                .font(.system(size: 12.5))
                .foregroundStyle(palette.secondaryLabel)
            Spacer()
            layoutChip("Por día", icon: "calendar", value: .day)
            layoutChip("Por comercio", icon: "storefront", value: .merchant)
        }
        .padding(.horizontal, 6)
    }

    private func layoutChip(_ title: String, icon: String, value: Layout) -> some View {
        let isOn = layout == value
        return Button {
            withAnimation(.snappy(duration: 0.25)) { layout = value }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(isOn ? accent.onSurface(scheme) : palette.secondaryLabel)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(isOn ? accent.color.opacity(0.12) : palette.surface, in: Capsule())
            .overlay(Capsule().stroke(isOn ? Color.clear : palette.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - Por día

    struct DayBucket: Identifiable {
        let day: Date
        let expenses: [Expense]
        var id: Date { day }
    }

    /// `unclassified` ya llega del más nuevo al más viejo.
    private func dayBuckets(_ expenses: [Expense]) -> [DayBucket] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [Expense]] = [:]
        for expense in expenses {
            let day = calendar.startOfDay(for: expense.date)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(expense)
        }
        return order.map { DayBucket(day: $0, expenses: buckets[$0] ?? []) }
    }

    /// Igual que un día de Movimientos: cabecera con el total y la fila de
    /// siempre, con su casilla.
    private func dayBlock(_ bucket: DayBucket) -> some View {
        let ids = Set(bucket.expenses.map(\.id))
        let picked = ids.intersection(selected).count
        return VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if picked == ids.count { selected.subtract(ids) } else { selected.formUnion(ids) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        SelectionCheck(state: picked == 0 ? .off : picked == ids.count ? .on : .partial, size: 18)
                        Text(MovementDay.shortLabel(for: bucket.day))
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(palette.secondaryLabel)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Elegir todo el " + MovementDay.shortLabel(for: bucket.day))

                Spacer()

                Text("–" + Money.format(Money.sum(bucket.expenses) { Accounting.netCostInPEN($0, fallbackRate: rate) }))
                    .font(.system(size: 13.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(palette.secondaryLabel)
            }
            .padding(.horizontal, 4)

            MovementCard {
                ForEach(Array(bucket.expenses.enumerated()), id: \.element.id) { index, expense in
                    let isOn = selected.contains(expense.id)
                    MovementRow(expense: expense,
                                showsTime: true,
                                onTap: {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        if isOn { selected.remove(expense.id) } else { selected.insert(expense.id) }
                                    }
                                },
                                selection: isOn)
                    if index < bucket.expenses.count - 1 { MovementSeparator() }
                }
            }
        }
    }

    // MARK: - Etiquetas en bloque

    private var selectedExpenses: [Expense] {
        expenses.filter { selected.contains($0.id) }
    }

    private var deletable: [Expense] { BulkExpenseEdit.deletable(selectedExpenses) }

    private var deleteTitle: String {
        BulkExpenseEdit.deleteTitle(selected: selected.count, deletable: deletable.count)
    }

    private var deleteMessage: String {
        BulkExpenseEdit.deleteMessage(selected: selected.count, deletable: deletable.count)
    }

    private func deleteSelected() {
        let targets = deletable
        withAnimation(.easeInOut(duration: 0.25)) {
            BulkExpenseEdit.delete(targets, in: modelContext)
            selected.removeAll()
        }
    }

    // MARK: - Grupo

    private func groupCard(_ group: Group) -> some View {
        let ids = Set(group.expenses.map(\.id))
        let picked = ids.intersection(selected).count
        let state: Check = picked == 0 ? .off : picked == ids.count ? .on : .partial
        let isExpanded = expanded.contains(group.merchant)
        let hint = suggestion(for: group)

        return ShellCard(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if state == .on { selected.subtract(ids) } else { selected.formUnion(ids) }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            checkmark(state, size: 24)

                            if let sample = group.expenses.first {
                                let look = sourceLook(sample)
                                MovementIcon(icon: look.icon, color: look.color, size: 36)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(Accounting.displayName(group.merchant))
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(palette.label)
                                    .lineLimit(1)

                                Text(countLabel(group, picked: picked))
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(palette.secondaryLabel)
                            }

                            Spacer(minLength: 8)

                            Text(Money.format(group.total))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(palette.label)
                        }
                        .padding(.leading, 14)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            if isExpanded { expanded.remove(group.merchant) }
                            else { expanded.insert(group.merchant) }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(accent.onSurface(scheme))
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .frame(width: 30, height: 30)
                            .background(accent.color.opacity(0.10), in: Circle())
                            .padding(.leading, 10)
                            .padding(.trailing, 12)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Ocultar movimientos" : "Ver movimientos")
                }
                .fixedSize(horizontal: false, vertical: true)

                if isExpanded {
                    VStack(spacing: 0) {
                        ForEach(group.expenses) { expense in
                            Rectangle().fill(palette.hairline).frame(height: 0.5)
                                .padding(.leading, 50)
                            movementRow(expense)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // La sugerencia sólo aparece en el grupo elegido: en todos a
                // la vez sería una pantalla de botones verdes compitiendo.
                if picked > 0, let hint, hint.confidence >= 0.45 {
                    suggestionRow(group: group, hint: hint)
                        .padding(.top, isExpanded ? 12 : 0)
                }
            }
        }
    }

    private func movementRow(_ expense: Expense) -> some View {
        let isOn = selected.contains(expense.id)

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isOn { selected.remove(expense.id) } else { selected.insert(expense.id) }
            }
        } label: {
            HStack(spacing: 12) {
                checkmark(isOn ? .on : .off, size: 20)
                    .frame(width: 24)

                Text(expense.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(Locale(identifier: "es_ES")))
                        .capitalized(with: Locale(identifier: "es_ES")))
                    .font(.system(size: 14))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(Money.format(expense.amount, currency: expense.currency))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.secondaryLabel)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(isOn ? accent.color.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private typealias Check = SelectionCheck.State

    private func checkmark(_ state: Check, size: CGFloat) -> some View {
        SelectionCheck(state: state, size: size)
    }

    private func countLabel(_ group: Group, picked: Int) -> String {
        let count = group.expenses.count
        let base = count == 1 ? "1 movimiento" : "\(count) movimientos"
        let source = group.expenses.first.flatMap(MovementStyle.source(for:))
        guard picked > 0, picked < count else { return source.map { $0 + " · " + base } ?? base }
        return "\(picked) de \(count) elegidos"
    }

    /// De dónde salió el dinero, que es lo único que distingue a un yapeo de
    /// un plin o de una compra con tarjeta: todavía no tienen categoría, así
    /// que el ícono de categoría sería el mismo cajón para todos.
    private func sourceLook(_ expense: Expense) -> (icon: String, color: Color) {
        let icon = MovementStyle.icon(for: expense)
        if icon == CategoryStyle.icon(for: Accounting.unclassified) {
            // El logo del banco que se detectó (BBVA, BCP, Interbank…) sobre
            // su color, en vez de una tarjeta gris que no dice de dónde vino.
            if let institution = MovementStyle.institution(for: expense),
               let logo = institution.logoAsset {
                return (logo, CardFace(institution).colors.first ?? palette.secondaryLabel)
            }
            let hasCard = !(expense.cardLastDigits ?? "").isEmpty
            return (hasCard ? "creditcard.fill" : "questionmark", palette.secondaryLabel)
        }
        return (icon, MovementStyle.color(for: expense, accent: accent.color, scheme: scheme))
    }

    private func suggestionRow(group: Group, hint: CategorySuggestion) -> some View {
        HStack(spacing: 8) {
            Text("¿Es")
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryLabel)

            HStack(spacing: 5) {
                Image(systemName: CategoryStyle.icon(for: hint.category))
                    .font(.system(size: 11, weight: .semibold))
                Text(hint.category)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(CategoryStyle.color(for: hint.category, accent: accent.color))

            Text("?")
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryLabel)

            Spacer(minLength: 6)

            Button {
                // Aceptar la sugerencia clasifica sólo lo elegido; la regla
                // para lo que llegue se pide en la hoja («Otra»).
                var props = Analytics.suggestionProps(hint)
                props["screen"] = "pending"
                Analytics.track(.suggestionAccepted, props)
                apply(hint.category, to: pickedIDs(in: group), rules: AssignCategoryRules(),
                      via: .pendingSuggestion)
            } label: {
                Text("Sí")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 18)
                    .frame(height: 30)
                    .background(palette.positive, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                var props = Analytics.suggestionProps(hint)
                props["screen"] = "pending"
                Analytics.track(.suggestionDismissed, props)
                let ids = pickedIDs(in: group)
                assigning = AssignTarget(ids: ids, groups: groups,
                                         earlier: Self.earlierPending(than: ids, in: expenses).count)
            } label: {
                Text("Otra")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.secondaryLabel)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(palette.neutralSurface, in: Capsule())
                    .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .onAppear { Analytics.suggestionShown(hint, merchant: group.merchant, screen: "pending") }
    }

    // MARK: - Aplicar

    private func pickedIDs(in group: Group) -> Set<UUID> {
        Set(group.expenses.map(\.id)).intersection(selected)
    }

    /// Lo elegido se clasifica siempre; lo demás, sólo si se pidió en la hoja
    /// (los dos interruptores llegan apagados): `rules.past` arrastra lo
    /// pendiente más antiguo de esos comercios, aunque esté fuera del alcance
    /// visible, y `rules.future` deja la regla para lo que llegue.
    private func apply(_ category: String, to ids: Set<UUID>, rules: AssignCategoryRules,
                       via: ClassificationVia = .pendingSheet) {
        let picked = expenses.filter { ids.contains($0.id) }
        let earlier = rules.past ? Self.earlierPending(than: ids, in: expenses) : []

        Analytics.classified((picked + earlier).map { ($0.id, $0.category) }, to: category,
                             via: via, ruleCreated: rules.future)
        if rules.future {
            let merchants = Set(picked.map(\.merchant))
            for merchant in merchants { MerchantRules.set(category, for: merchant) }
            Analytics.ruleCreated(origin: "pending", count: merchants.count)
        }
        for expense in picked + earlier {
            expense.category = category
            ExpenseEditStore.record(expense, category: category)
        }
        try? modelContext.save()

        withAnimation(.easeInOut(duration: 0.25)) {
            selected.subtract(ids)
        }
    }

    /// «Los anteriores»: lo pendiente de los mismos comercios, más antiguo
    /// que el movimiento más viejo elegido de cada uno. Por fecha y no «todo
    /// lo demás»: lo que se dejó sin marcar en el mismo mes se dejó a propósito.
    static func earlierPending(than ids: Set<UUID>, in expenses: [Expense]) -> [Expense] {
        var oldest: [String: Date] = [:]
        for expense in expenses where ids.contains(expense.id) {
            oldest[expense.merchant] = min(oldest[expense.merchant] ?? expense.date, expense.date)
        }
        guard !oldest.isEmpty else { return [] }
        return expenses.filter { expense in
            guard !ids.contains(expense.id),
                  expense.category == Accounting.unclassified, expense.countsAsSpending,
                  let limit = oldest[expense.merchant] else { return false }
            return expense.date < limit
        }
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

    // MARK: - Tipos

    struct Group: Identifiable {
        let merchant: String
        let monthStart: Date
        let expenses: [Expense]
        let total: Double
        var id: String { merchant + "-" + monthStart.description }
        var mostRecent: Date { expenses.first?.date ?? .distantPast }
    }

    /// Lo que la hoja de asignar necesita saber: los movimientos elegidos,
    /// de uno o varios comercios, y cuántos anteriores quedan pendientes.
    struct AssignTarget: Identifiable {
        let ids: Set<UUID>
        let groups: [Group]
        let earlier: Int
        let id = UUID()

        var context: AssignCategoryContext {
            let touched = groups.compactMap { group -> (Group, [Expense])? in
                let picked = group.expenses.filter { ids.contains($0.id) }
                return picked.isEmpty ? nil : (group, picked)
            }
            let movements = touched.reduce(0) { $0 + $1.1.count }
            let total = Money.sum(touched.flatMap(\.1)) { Accounting.netCostInPEN($0, fallbackRate: ExchangeRateService.shared.usdToPenRate) }
            var merchants: [String] = []
            for (group, _) in touched where !merchants.contains(group.merchant) { merchants.append(group.merchant) }
            let scope = AssignCategoryContext.RuleScope.pending(merchants: merchants, selected: movements, earlier: earlier)
            let count = movements == 1 ? "1 movimiento" : "\(movements) movimientos"

            if merchants.count == 1, let merchant = merchants.first {
                let all = touched.reduce(0) { $0 + $1.0.expenses.count }
                return AssignCategoryContext(
                    merchant: merchant,
                    title: Accounting.displayName(merchant),
                    subtitle: (movements == all ? count : "\(movements) de \(all) movimientos") + " · " + Money.format(total),
                    amount: nil,
                    ruleScope: scope
                )
            }
            return AssignCategoryContext(
                merchant: nil,
                title: "\(merchants.count) comercios",
                subtitle: count + " · " + Money.format(total),
                amount: total,
                ruleScope: scope
            )
        }
    }
}
