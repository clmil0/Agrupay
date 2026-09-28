import SwiftUI
import SwiftData

/// Configuración.
///
/// Antes eran seis `NavigationLink` idénticos con nombres que no decían qué
/// contenían ("Apariencia y Navegación", "Respaldo y Funciones Online"), ninguna
/// fila mostraba su valor, y el dato que sostiene la app —si la lectura de
/// correo funciona— estaba dos niveles adentro. Ahora: estado arriba, tres
/// secciones agrupadas por intención, y el valor de cada fila a la vista.
struct SettingsView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    /// Conteos de la raíz, pedidos a la base con `fetchCount` y no con un
    /// `@Query` del historial entero: esa consulta se volvía a recorrer en cada
    /// redibujado —p. ej. al cambiar de tema en Apariencia— sólo para contar.
    @State private var counts = SettingsCounts()
    @Query private var recurringRules: [RecurringExpense]
    @Query private var quickExpenses: [QuickExpense]

    @StateObject private var gmailAuth = GmailAuthService.shared

    /// Ver el `onReceive` del final del cuerpo.
    @AppStorage(GmailAuthService.pendingLinkFlowKey) private var pendingLinkFlow = false
    @State private var didReadInitialAuthState = false
    @StateObject private var gmailSync = GmailSyncService.shared

    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.dark.rawValue
    @AppStorage(BudgetStore.monthlyBudgetKey) private var monthlyBudget: Double = 0
    @AppStorage(BudgetStore.enabledKey) private var budgetEnabled = true
    // Se leen aquí para que la fila de la raíz se redibuje al cambiarlos dentro.
    @AppStorage(NotificationSettings.budgetKey) private var notifyBudget = true
    @AppStorage(NotificationSettings.recurringKey) private var notifyRecurring = true
    @AppStorage(NotificationSettings.debtEnabledKey) private var notifyDebt = true
    @AppStorage("syncBBVA") private var syncBBVA = true
    @AppStorage("syncBCP") private var syncBCP = true
    @AppStorage("syncYape") private var syncYape = true
    @AppStorage("syncInterbank") private var syncInterbank = true
    @AppStorage("syncScotiabank") private var syncScotiabank = true
    // Igual que los avisos: se lee aquí para que la fila de la raíz refleje el
    // valor sin tener que volver a entrar.
    @AppStorage(AppLock.enabledKey) private var lockEnabled = false
    @AppStorage(DashboardStatsSettings.key) private var statsRaw = DashboardStatsSettings.defaultValue

    @State private var query = ""

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    private var appearance: AppAppearance { AppAppearance(rawValue: appearanceRaw) ?? .dark }
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if query.isEmpty {
                        // Conectado, la tarjeta sobra: la fila de Gmail ya dice
                        // la cuenta y los bancos. Sin conectar, es la única
                        // forma visible de empezar, y se queda arriba.
                        if !gmailAuth.isAuthenticated {
                            statusCard
                        }

                        moneySection
                        captureSection
                        appSection
                        versionFooter
                    } else {
                        searchResults
                    }
                }
                .padding(.vertical, 16)
            }
            .background(palette.background)
            .onAppear(perform: refreshCounts)
            .searchable(text: $query, prompt: "Buscar en configuración")
            .navigationTitle("Configuración")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .appAppearance()
            .appTextSize()
        }
        // Vincular desde la tarjeta de arriba, o desde Gmail y bancos: al
        // llegar el token, Ajustes se cierra solo y la secuencia la presenta
        // `ContentView`. Presentarla desde aquí, encima del propio
        // `fullScreenCover` de Ajustes, no funciona: iOS descarta esa
        // presentación mientras la hoja de Google se está cerrando, y el modal
        // no aparecía hasta que el usuario cerraba Ajustes a mano.
        .onReceive(gmailAuth.$isAuthenticated) { isAuthenticated in
            // La primera emisión es el valor que ya traía al abrir la pantalla;
            // sin saltarla, entrar a Ajustes con una vinculación a medias lo
            // cerraría de inmediato.
            guard didReadInitialAuthState else {
                didReadInitialAuthState = true
                return
            }
            guard isAuthenticated, pendingLinkFlow else { return }
            dismiss()
        }
    }

    // MARK: - Estado

    private var status: SettingsStatus {
        SettingsStatus(
            isConnected: gmailAuth.isAuthenticated,
            missingGmailScope: gmailAuth.missingGmailScope,
            account: gmailAuth.isAuthenticated ? "Sólo lectura del correo" : nil,
            lastSync: gmailSync.lastSyncDate,
            activeBankCount: BankSource.activeCount,
            totalBankCount: BankSource.all.count,
            expensesThisMonth: counts.thisMonth,
            unclassifiedMerchants: unclassifiedMerchantCount,
            pendingRecurring: 0
        )
    }

    private var unclassifiedMerchantCount: Int { counts.unclassifiedMerchants }

    /// Se refresca al abrir la raíz y al volver a ella desde una pantalla
    /// interior, que es donde se pueden borrar o importar datos.
    private func refreshCounts() {
        counts = SettingsCounts(context: modelContext)
    }

    /// La tarjeta entera lleva a Gmail y bancos, pero sólo cuando hay cuenta:
    /// sin conectar, el botón de dentro es la única acción y no debe quedar
    /// tapado por un enlace.
    @ViewBuilder
    private var statusCard: some View {
        if gmailAuth.isAuthenticated {
            NavigationLink {
                GmailBanksView()
            } label: {
                SettingsStatusCard(status: status, accent: accent.color) {}
            }
            .buttonStyle(.plain)
        } else {
            SettingsStatusCard(status: status, accent: accent.color) {
                gmailAuth.signIn()
            }
        }
    }

    // MARK: - Secciones

    private var moneySection: some View {
        SettingsSection(title: "Tu dinero") {
            SettingsRow(title: "Presupuesto", icon: "chart.bar.fill",
                        tint: .blue, value: budgetValue) {
                BudgetScreen()
            }
            SettingsSeparator()
            SettingsRow(title: "Recurrentes y atajos", icon: "arrow.triangle.2.circlepath",
                        tint: .blue, value: recurringValue) {
                RecurringManagementView()
            }
            SettingsSeparator()
            SettingsRow(title: "Categorías y reglas", icon: "tag.fill",
                        tint: .blue, value: rulesValue) {
                CategoryRulesScreen()
            }
        }
    }

    private var captureSection: some View {
        SettingsSection(title: "Captura automática") {
            SettingsRow(title: "Gmail y bancos", icon: "building.columns.fill",
                        tint: .teal, value: gmailValue,
                        subtitle: gmailAuth.isAuthenticated ? "Sólo lectura del correo" : nil) {
                GmailBanksView()
            }
            SettingsSeparator()
            SettingsRow(title: "Leer un rango pasado", icon: "calendar",
                        tint: .green) {
                RangeSyncView()
            }
        }
    }

    private var appSection: some View {
        SettingsSection(title: "La app") {
            SettingsRow(title: "Apariencia", icon: "paintbrush.fill",
                        tint: .purple, value: accent.rawValue + " · " + appearance.rawValue) {
                AppearanceSettingsView()
            }
            SettingsSeparator()
            SettingsRow(title: "Estadísticas", icon: "chart.xyaxis.line",
                        tint: .indigo, value: statsValue) {
                StatsSettingsView()
            }
            SettingsSeparator()
            SettingsRow(title: "Notificaciones", icon: "bell.fill",
                        tint: .red, value: notificationsValue) {
                NotificationSettingsView()
            }
            SettingsSeparator()
            SettingsRow(title: "Bloqueo", icon: AppLock.biometryIcon,
                        tint: Color(white: 0.35), value: lockValue) {
                AppLockSettingsView()
            }
            SettingsSeparator()
            SettingsRow(title: "Datos y respaldo", icon: "externaldrive.fill",
                        tint: Color(white: 0.35)) {
                DataBackupView()
            }
            SettingsSeparator()
            // Visible otra vez: hace falta para pedir el informe de Gmail a
            // quien no puede buscarlo. FinanceKit sigue fuera: es una prueba
            // de desarrollo y sólo existe en DEBUG (`SettingsEntry.searchable`).
            SettingsRow(title: "Diagnóstico", icon: "stethoscope",
                        tint: Color(white: 0.35)) {
                DiagnosticsView()
            }
        }
    }

    // MARK: - Valores de cada fila
    //
    // Ninguno queda vacío: "Sin definir" y "Ninguna" también son información.

    private var budgetValue: String {
        guard BudgetStore.hasBudget(monthlyBudget: monthlyBudget, enabled: budgetEnabled) else {
            return "Sin definir"
        }
        return Money.format(monthlyBudget)
    }

    /// «6 activos · 3 atajos».
    private var recurringValue: String {
        let active = recurringRules.filter { !$0.isPaused }.count
        var parts: [String] = []
        if active > 0 { parts.append(active == 1 ? "1 activo" : "\(active) activos") }
        if !quickExpenses.isEmpty {
            parts.append(quickExpenses.count == 1 ? "1 atajo" : "\(quickExpenses.count) atajos")
        }
        return parts.isEmpty ? "Ninguno" : parts.joined(separator: " · ")
    }

    /// «5 de 7».
    private var statsValue: String {
        let count = DashboardStatsSettings.decode(statsRaw).count
        return count == 0 ? "Ninguna" : "\(count) de \(DashboardStat.allCases.count)"
    }

    private var lockValue: String {
        guard AppLock.canLock else { return "No disponible" }
        return lockEnabled ? AppLock.biometryName : "Desactivado"
    }

    /// «11 · 9 reglas»: las categorías y cuántas reglas las alimentan.
    private var rulesValue: String {
        let rules = MerchantRules.all().count
        let rulesLabel = rules == 1 ? "1 regla" : "\(rules) reglas"
        return "\(counts.categories) · " + rulesLabel
    }

    private var gmailValue: String {
        guard gmailAuth.isAuthenticated else { return gmailAuth.accessRevoked ? "Se desconectó" : "Sin conectar" }
        if gmailAuth.missingGmailScope { return "Falta permiso" }
        return BankSource.summaryLabel
    }

    private var notificationsValue: String {
        let count = NotificationSettings.activeCount()
        if count == 0 { return "Ninguna" }
        return count == 1 ? "1 activa" : "\(count) activas"
    }

    // MARK: - Búsqueda

    @ViewBuilder
    private var searchResults: some View {
        let results = SettingsEntry.matching(query)

        if results.isEmpty {
            ContentUnavailableView("Nada coincide con «\(query)»",
                                   systemImage: "magnifyingglass",
                                   description: Text("Prueba con otra palabra."))
                .padding(.top, 40)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                    searchRow(entry)
                    if index < results.count - 1 { SettingsSeparator() }
                }
            }
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5)
            )
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func searchRow(_ entry: SettingsEntry) -> some View {
        NavigationLink {
            destination(for: entry.destination)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .foregroundStyle(palette.label)
                    // De dónde viene: sin esto, el resultado no dice dónde vive.
                    Text(entry.section)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryLabel)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.tertiaryLabel)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func destination(for id: String) -> some View {
        switch id {
        case "budget":        BudgetScreen()
        case "recurring":     RecurringManagementView()
        case "rules":         CategoryRulesScreen()
        case "gmail":         GmailBanksView()
        case "range":         RangeSyncView()
        case "appearance":    AppearanceSettingsView()
        case "stats":         StatsSettingsView()
        case "notifications": NotificationSettingsView()
        case "lock":          AppLockSettingsView()
        case "diagnostics":   DiagnosticsView()
        #if DEBUG
        case "financekit":    FinanceKitPOCView()
        #endif
        default:              DataBackupView()
        }
    }

    // MARK: - Pie

    /// La versión del bundle (`MARKETING_VERSION`), no un texto a mano que se
    /// queda atrás en cada release.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var versionFooter: some View {
        Text("AgruPay " + Self.appVersion)
            .font(.caption)
            .foregroundStyle(palette.tertiaryLabel)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
    }
}

/// Presupuesto: aquí, en "Tu dinero", y no dentro de "Apariencia y Navegación",
/// que es donde estaba un ajuste financiero.
struct BudgetScreen: View {
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false

    var body: some View {
        Form {
            BudgetSettingsSection(tint: AppThemeColor(rawValue: appAccentColor)?.color ?? .purple)
        }
        .navigationTitle("Presupuesto")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Categorías y reglas (`5f`).
///
/// Cada fila dice las dos cosas que se vienen a editar: el límite y cuántos
/// comercios caen ahí por regla. El bloque «sin usar» propone la limpieza en
/// vez de dejar que la lista crezca sin fin.
struct CategoryRulesScreen: View {

    @Environment(\.colorScheme) private var scheme
    @Environment(\.modelContext) private var modelContext
    @StateObject private var budgets = CategoryBudgetStore.shared
    @StateObject private var catalog = CategoryCatalog.shared

    @State private var stats = CategoryRulesStats()
    @State private var editing: CategoryRef?
    @State private var creating = false
    @State private var merging: CategoryRef?
    @State private var history: [Expense] = []

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                rulesCard

                VStack(spacing: 8) {
                    ShellSectionHeader(title: "Tus categorías · \(stats.active.count)")
                    MovementCard {
                        ForEach(Array(stats.active.enumerated()), id: \.element) { index, name in
                            categoryRow(name)
                            if index < stats.active.count - 1 { MovementSeparator() }
                        }
                    }
                }

                if !stats.unused.isEmpty {
                    VStack(spacing: 8) {
                        ShellSectionHeader(title: "Sin usar hace 3 meses")
                        MovementCard {
                            ForEach(Array(stats.unused.enumerated()), id: \.element) { index, name in
                                unusedRow(name)
                                if index < stats.unused.count - 1 { MovementSeparator() }
                            }
                        }
                        Text("Al fusionar, sus movimientos y reglas pasan a la categoría que elijas. Nada se borra.")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.secondaryLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                    }
                }
            }
            .padding(16)
        }
        .background(palette.background)
        .navigationTitle("Categorías y reglas")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Nueva categoría")
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $editing, onDismiss: reload) { ref in
            NavigationStack {
                CategorySettingsView(category: ref.name, history: history)
            }
        }
        .sheet(isPresented: $creating, onDismiss: reload) {
            NavigationStack {
                CategorySettingsView(category: "", isNew: true, history: history)
            }
        }
        .sheet(item: $merging) { ref in
            CategoryMergeSheet(source: ref.name, onDone: reload)
        }
    }

    // MARK: - Reglas

    private var rulesCard: some View {
        NavigationLink {
            MerchantRulesList()
        } label: {
            ShellCard {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(accent.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stats.ruleCount == 1 ? "1 regla activa" : "\(stats.ruleCount) reglas activas")
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(palette.label)
                        Text(stats.ruleCount == 0
                             ? "Se crean al asignar una categoría a un comercio"
                             : "Clasifican solas el \(stats.coveragePercent)% de tus gastos")
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.secondaryLabel)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.tertiaryLabel)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Filas

    private func categoryRow(_ name: String) -> some View {
        Button { editing = CategoryRef(name: name) } label: {
            HStack(spacing: 12) {
                MovementIcon(icon: CategoryStyle.icon(for: name),
                             color: CategoryStyle.color(for: name, accent: accent.color),
                             size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.label)
                    Text(detail(for: name))
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryLabel)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.tertiaryLabel)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// «Límite S/ 900 · 4 comercios», «Sin límite · sin comercios».
    private func detail(for name: String) -> String {
        let limit = budgets.budget(for: name).map { "Límite " + Money.formatCompact($0.amount) } ?? "Sin límite"
        let merchants = stats.merchantsByCategory[name] ?? 0
        let merchantLabel = merchants == 0 ? "sin comercios"
            : merchants == 1 ? "1 comercio" : "\(merchants) comercios"
        return limit + " · " + merchantLabel
    }

    private func unusedRow(_ name: String) -> some View {
        HStack(spacing: 12) {
            MovementIcon(icon: CategoryStyle.icon(for: name), color: palette.tertiaryLabel, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.label)
                let total = stats.totalByCategory[name] ?? 0
                Text(total == 1 ? "1 movimiento" : "\(total) movimientos")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
            }
            Spacer()
            Button("Fusionar") { merging = CategoryRef(name: name) }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.label)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(palette.neutralSurface, in: Capsule())
                .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func reload() {
        stats = CategoryRulesStats(context: modelContext, catalog: catalog)
        history = (try? modelContext.fetch(FetchDescriptor<Expense>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
    }
}

/// Los números de Categorías y reglas, contados una vez al entrar.
private struct CategoryRulesStats {
    var active: [String] = []
    var unused: [String] = []
    var ruleCount = 0
    var coveragePercent = 0
    var merchantsByCategory: [String: Int] = [:]
    var totalByCategory: [String: Int] = [:]

    init() {}

    init(context: ModelContext, catalog: CategoryCatalog) {
        let rules = MerchantRules.all()
        ruleCount = rules.count
        for (_, category) in rules { merchantsByCategory[category, default: 0] += 1 }

        var descriptor = FetchDescriptor<Expense>()
        descriptor.propertiesToFetch = [\.category, \.merchant, \.date]
        let expenses = (try? context.fetch(descriptor)) ?? []

        let cutoff = Period.calendar.date(byAdding: .month, value: -3, to: Date()) ?? Date()
        var recent: Set<String> = []
        var recentCount = 0, recentByRule = 0
        for expense in expenses {
            totalByCategory[expense.category, default: 0] += 1
            guard expense.date >= cutoff else { continue }
            recent.insert(expense.category)
            recentCount += 1
            if rules[expense.merchant] != nil { recentByRule += 1 }
        }
        // Sobre los últimos 3 meses: es lo que dice cómo funcionan las reglas
        // hoy, no lo que clasificaste a mano hace dos años.
        coveragePercent = recentCount == 0 ? 0 : Int((Double(recentByRule) / Double(recentCount) * 100).rounded())

        let builtIns = Set(CategoryStyle.defaults)
        let all = Set(totalByCategory.keys).union(catalog.entries.keys).union(builtIns)
            .subtracting([Accounting.unclassified])
        active = all.filter { recent.contains($0) || builtIns.contains($0) }.sorted()
        unused = all.subtracting(active).sorted()
    }
}

/// La lista de reglas por comercio. Antes era la pantalla entera; ahora es un
/// nivel más abajo, detrás de la tarjeta que dice cuánto hacen.
struct MerchantRulesList: View {
    @Environment(\.colorScheme) private var scheme
    @State private var rules: [String: String] = [:]

    private var palette: Palette { Palette(scheme) }

    private var sorted: [(merchant: String, category: String)] {
        rules.map { (merchant: $0.key, category: $0.value) }
            .sorted { $0.merchant.localizedCaseInsensitiveCompare($1.merchant) == .orderedAscending }
    }

    var body: some View {
        List {
            if sorted.isEmpty {
                Text("Todavía no has clasificado ningún comercio. Al asignarle una categoría a uno en Pendientes, la regla aparece aquí.")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryLabel)
            } else {
                Section {
                    ForEach(sorted, id: \.merchant) { rule in
                        HStack {
                            Text(Accounting.displayName(rule.merchant)).lineLimit(1)
                            Spacer()
                            Text(rule.category).foregroundStyle(palette.secondaryLabel)
                        }
                    }
                    .onDelete(perform: delete)
                } footer: {
                    Text("Cada regla clasifica sola los movimientos futuros de ese comercio. Desliza para borrar una.")
                }
            }
        }
        .navigationTitle("Reglas")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { rules = MerchantRules.all() }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { MerchantRules.remove(sorted[index].merchant) }
        rules = MerchantRules.all()
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: [Expense.self, Income.self, RecurringExpense.self, QuickExpense.self],
                        inMemory: true)
}

/// Los tres números de la raíz de Configuración, contados en la base.
private struct SettingsCounts {
    var total = 0
    var thisMonth = 0
    var unclassifiedMerchants = 0
    var categories = 0

    init() {}

    init(context: ModelContext) {
        total = (try? context.fetchCount(FetchDescriptor<Expense>())) ?? 0

        let month = Period(granularity: .mes, reference: Date()).interval
        let start = month.start, end = month.end
        thisMonth = (try? context.fetchCount(FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= start && $0.date < end }))) ?? 0

        let unclassified = Accounting.unclassified
        var pending = FetchDescriptor<Expense>(predicate: #Predicate { $0.category == unclassified && !$0.isTransfer && !$0.isVoided && !$0.isReversal && !$0.isSplit })
        pending.propertiesToFetch = [\.merchant]
        let merchants = ((try? context.fetch(pending)) ?? []).map(\.merchant)
        unclassifiedMerchants = Set(merchants).count

        var all = FetchDescriptor<Expense>()
        all.propertiesToFetch = [\.category]
        categories = Set(((try? context.fetch(all)) ?? []).map(\.category))
            .subtracting([unclassified]).count
    }
}
