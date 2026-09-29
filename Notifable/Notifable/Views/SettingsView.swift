import SwiftUI
import SwiftData

/// Configuración (`2a` gratis, `2b` Pro de «Configuración Pro»).
///
/// Menos filas que antes: el perfil va arriba en una tarjeta compacta, y Pro
/// no tiene fila propia ni candados por todas partes — en Gratis es la
/// pastilla junto al perfil; en Pro, la tarjeta entera se vuelve el hero con
/// el espacio animado. Dentro de cada pantalla, lo que pide Pro aparece como
/// una opción más con su «PRO».
///
/// Presupuesto y Categorías son ahora una sola fila, y «Leer un rango pasado»
/// vive dentro de Gmail y bancos; Estadísticas, dentro de Apariencia y
/// resumen; Diagnóstico, dentro de Datos y respaldo.
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
    @State private var social = SocialProfileStore.shared
    @State private var phone = PhoneVerification.shared
    @State private var backup = ConfigBackupManager.shared

    @AppStorage(ProStore.enabledKey) private var isPro = false
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.dark.rawValue
    @AppStorage(BudgetStore.monthlyBudgetKey) private var monthlyBudget: Double = 0
    @AppStorage(BudgetStore.enabledKey) private var budgetEnabled = true
    // Se leen aquí para que la fila de la raíz se redibuje al cambiarlos dentro.
    @AppStorage(NotificationSettings.budgetKey) private var notifyBudget = true
    @AppStorage(NotificationSettings.recurringKey) private var notifyRecurring = true
    @AppStorage(NotificationSettings.debtEnabledKey) private var notifyDebt = true
    @AppStorage(NotificationSettings.reminderIntensityKey) private var reminderIntensity = PaymentReminder.Intensity.soft.rawValue
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
    @State private var showsPaywall = false

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    private var appearance: AppAppearance { AppAppearance(rawValue: appearanceRaw) ?? .dark }
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if query.isEmpty {
                        profileCard

                        // Conectado, la tarjeta sobra: la fila de Correo ya
                        // dice la cuenta. Sin conectar, es la única forma
                        // visible de empezar, y se queda arriba.
                        if !gmailAuth.isAuthenticated {
                            statusCard
                        }

                        accountSection
                        moneySection
                        captureSection
                        personalSection
                        privacySection
                        versionFooter
                    } else {
                        searchResults
                    }
                }
                .padding(.vertical, 16)
            }
            .background(palette.background)
            .onAppear(perform: refreshCounts)
            .task { await phone.refresh() }
            .searchable(text: $query, prompt: "Buscar en configuración")
            .navigationTitle("Configuración")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .proPaywall(isPresented: $showsPaywall)
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

    // MARK: - Perfil

    /// Gratis: tarjeta compacta con la pastilla «Pro» a un lado. Pro: la
    /// misma tarjeta, pero con el espacio animado detrás.
    private var profileCard: some View {
        NavigationLink {
            ProfileSettingsView()
        } label: {
            if isPro {
                SettingsProHero(look: social.penguin, name: displayName,
                                subtitle: ProStore.memberSinceLabel)
            } else {
                freeProfileCard
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private var displayName: String {
        social.displayName.isEmpty ? "Tu perfil" : social.displayName
    }

    private var freeProfileCard: some View {
        HStack(spacing: 12) {
            PenguinAvatar(look: social.penguin, size: 54, background: palette.neutralSurface)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                Text("Perfil, avatar y estado")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
            }

            Spacer(minLength: 8)

            // Un botón dentro del enlace: tocar la pastilla abre Pro y no el
            // perfil (el gesto más interno gana).
            Button { showsPaywall = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .bold))
                    Text("Pro")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(SettingsProHero.gold)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(SettingsProHero.gold.opacity(0.14), in: Capsule())
                .overlay(Capsule().stroke(SettingsProHero.gold.opacity(0.5), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ver AgruPay Pro")

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.tertiaryLabel)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
        .contentShape(Rectangle())
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
            unclassifiedMerchants: counts.unclassifiedMerchants,
            pendingRecurring: 0
        )
    }

    /// Se refresca al abrir la raíz y al volver a ella desde una pantalla
    /// interior, que es donde se pueden borrar o importar datos.
    private func refreshCounts() {
        counts = SettingsCounts(context: modelContext)
    }

    /// Sin cuenta, el botón de dentro es la única acción.
    private var statusCard: some View {
        SettingsStatusCard(status: status, accent: accent.color) {
            gmailAuth.signIn()
        }
    }

    // MARK: - Secciones

    private var accountSection: some View {
        SettingsSection(title: "Cuenta") {
            SettingsRow(title: "Correo", icon: "envelope.fill",
                        tint: Color(hex: 0xEA4335), value: emailValue) {
                EmailSettingsView()
            }
            SettingsSeparator()
            SettingsRow(title: "Celular", icon: "phone.fill",
                        tint: Color(hex: 0x30D158), value: phone.formattedPhone ?? "Sin verificar",
                        valueSeal: phone.formattedPhone != nil) {
                PhoneSettingsView()
            }
            SettingsSeparator()
            SettingsRow(title: "Dispositivos", icon: "laptopcomputer.and.iphone",
                        tint: Color(hex: 0x5E5CE6), value: "Este iPhone") {
                DevicesSettingsView()
            }
        }
    }

    private var moneySection: some View {
        SettingsSection(title: "Tu dinero") {
            SettingsRow(title: "Presupuesto y categorías", icon: "chart.bar.fill",
                        tint: Color(hex: 0x0A84FF), subtitle: budgetSubtitle) {
                BudgetCategoriesView()
            }
            SettingsSeparator()
            SettingsRow(title: "Recurrentes y atajos", icon: "arrow.triangle.2.circlepath",
                        tint: Color(hex: 0x0A84FF), subtitle: recurringValue) {
                RecurringManagementView()
            }
        }
    }

    private var captureSection: some View {
        SettingsSection(title: "Captura automática") {
            SettingsRow(title: "Gmail y bancos", icon: "building.columns.fill",
                        tint: Color(hex: 0x40C8E0), subtitle: gmailSubtitle) {
                GmailBanksView()
            }
        }
    }

    private var personalSection: some View {
        SettingsSection(title: "Personalización") {
            SettingsRow(title: "Apariencia y resumen", icon: "paintbrush.fill",
                        tint: Color(hex: 0xBF5AF2), subtitle: appearanceSubtitle) {
                AppearanceSettingsView()
            }
            SettingsSeparator()
            SettingsRow(title: "Asistente", icon: "sparkles",
                        tint: Color(hex: 0xBF5AF2), subtitle: isPro ? "Memoria extendida" : "Memoria básica") {
                AssistantSettingsView()
            }
            SettingsSeparator()
            SettingsRow(title: "Notificaciones", icon: "bell.fill",
                        tint: Color(hex: 0xFF453A), subtitle: notificationsValue) {
                NotificationSettingsView()
            }
        }
    }

    private var privacySection: some View {
        SettingsSection(title: "Privacidad y datos") {
            SettingsRow(title: "Bloqueo", icon: AppLock.biometryIcon,
                        tint: Color(white: 0.35), subtitle: lockValue) {
                AppLockSettingsView()
            }
            SettingsSeparator()
            SettingsRow(title: "Datos y respaldo", icon: "externaldrive.fill",
                        tint: Color(white: 0.35), subtitle: dataSubtitle) {
                DataBackupView()
            }
        }
    }

    // MARK: - Valores de cada fila
    //
    // Ninguno queda vacío: "Sin definir" y "Ninguna" también son información.

    private var emailValue: String {
        guard gmailAuth.isAuthenticated else { return gmailAuth.accessRevoked ? "Se desconectó" : "Sin conectar" }
        if gmailAuth.missingGmailScope { return "Falta permiso" }
        return gmailAuth.accountEmail ?? "Conectado"
    }

    /// «S/ 2,500 · 11 categorías · 9 reglas».
    private var budgetSubtitle: String {
        let budget = BudgetStore.hasBudget(monthlyBudget: monthlyBudget, enabled: budgetEnabled)
            ? Money.format(monthlyBudget) : "Sin presupuesto"
        let categories = counts.categories == 1 ? "1 categoría" : "\(counts.categories) categorías"
        let rules = MerchantRules.all().count
        return [budget, categories, rules == 1 ? "1 regla" : "\(rules) reglas"].joined(separator: " · ")
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

    /// «5 bancos · leer rangos pasados».
    private var gmailSubtitle: String {
        guard gmailAuth.isAuthenticated else { return gmailAuth.accessRevoked ? "Se desconectó" : "Sin conectar" }
        if gmailAuth.missingGmailScope { return "Falta el permiso de Gmail" }
        let active = BankSource.activeCount
        let banks = active == 0 ? "Ningún banco" : active == 1 ? "1 banco" : "\(active) bancos"
        return banks + " · leer rangos pasados"
    }

    /// «Azul · Oscuro · 5 de 7 estadísticas».
    private var appearanceSubtitle: String {
        let count = DashboardStatsSettings.decode(statsRaw).count
        let stats = count == 0 ? "sin estadísticas" : "\(count) de \(DashboardStat.allCases.count) estadísticas"
        return [accent.rawValue, appearance.rawValue, stats].joined(separator: " · ")
    }

    private var lockValue: String {
        guard AppLock.canLock else { return "No disponible" }
        return lockEnabled ? AppLock.biometryName : "Desactivado"
    }

    private var notificationsValue: String {
        let count = NotificationSettings.activeCount()
        var text = count == 0 ? "Ninguna" : count == 1 ? "1 activa" : "\(count) activas"
        if isPro, reminderIntensity == PaymentReminder.Intensity.intense.rawValue {
            text += " · cobros intensos"
        }
        return text
    }

    /// «En la nube · hoy 9:12» con Pro y la nube encendida.
    private var dataSubtitle: String {
        guard backup.isEnabled else { return "Respaldo, exportar y diagnóstico" }
        guard isPro else { return "Nube en pausa · respaldo y exportar" }
        guard let last = backup.lastSyncedAt else { return "En la nube" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_PE")
        f.dateFormat = Period.calendar.isDateInToday(last) ? "'hoy' H:mm" : "d MMM, H:mm"
        return "En la nube · " + f.string(from: last)
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
        case "profile":       ProfileSettingsView()
        case "email":         EmailSettingsView()
        case "phone":         PhoneSettingsView()
        case "devices":       DevicesSettingsView()
        case "budget":        BudgetCategoriesView()
        case "recurring":     RecurringManagementView()
        case "rules":         CategoryRulesScreen()
        case "gmail":         GmailBanksView()
        case "range":         RangeSyncView()
        case "appearance":    AppearanceSettingsView()
        case "stats":         StatsSettingsView()
        case "assistant":     AssistantSettingsView()
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

// MARK: - Hero Pro

/// La tarjeta del perfil con Pro (`2b`): el mismo tamaño que la de Gratis,
/// con un cielo morado, estrellas que titilan y un planeta asomando.
struct SettingsProHero: View {
    let look: PenguinLook
    let name: String
    let subtitle: String

    static let gold = Color(hex: 0xF6C64B)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Posiciones fijas (en fracciones de la tarjeta): el cielo no cambia de
    /// una apertura a otra.
    private static let stars: [(x: CGFloat, y: CGFloat, size: CGFloat)] = [
        (0.08, 0.14, 3), (0.22, 0.40, 2), (0.84, 0.12, 2), (0.92, 0.34, 3), (0.14, 0.62, 2),
        (0.88, 0.58, 2), (0.30, 0.08, 3), (0.70, 0.06, 2), (0.06, 0.40, 2), (0.96, 0.78, 2),
        (0.18, 0.84, 3), (0.62, 0.86, 2), (0.50, 0.04, 2), (0.60, 0.72, 3)
    ]

    var body: some View {
        HStack(spacing: 12) {
            PenguinAvatar(look: look, size: 56, background: Color(hex: 0x14122B))
                .padding(4)
                .overlay(
                    Circle().strokeBorder(
                        AngularGradient(colors: [Color(hex: 0xFFD60A), Color(hex: 0xFF6B9A), Color(hex: 0xBF5AF2),
                                                 Color(hex: 0x0A84FF), Color(hex: 0x30D158), Color(hex: 0xFFD60A)],
                                        center: .center),
                        lineWidth: 3)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 3) {
                        Image(systemName: "rosette")
                            .font(.system(size: 9, weight: .bold))
                        Text("PRO")
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(0.5)
                    }
                    .foregroundStyle(Color(hex: 0x3A2A00))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Self.gold, in: Capsule())
                }
                Text(subtitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xC4B5FD))
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .background(space)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.5))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var space: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                LinearGradient(colors: [Color(hex: 0x1B1640), Color(hex: 0x2A1B54), Color(hex: 0x120F2B)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(hex: 0x6D28D9).opacity(0.45), .clear],
                               center: UnitPoint(x: 0.35, y: 0.2), startRadius: 0, endRadius: size.width * 0.5)

                TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ForEach(Array(Self.stars.enumerated()), id: \.offset) { index, star in
                        let period = 2.2 + Double(index % 4) * 0.7
                        let phase = (t + Double(index) * 0.37) / period * 2 * .pi
                        let glow = reduceMotion ? 0.7 : 0.15 + 0.85 * (0.5 + 0.5 * sin(phase))
                        Circle()
                            .fill(.white)
                            .frame(width: star.size, height: star.size)
                            .opacity(glow)
                            .position(x: star.x * size.width, y: star.y * size.height)
                    }
                }

                // El planeta: una esfera naranja con su anillo, cortada por el
                // borde de la tarjeta.
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [Color(hex: 0xFFC58A), Color(hex: 0xF28C28), Color(hex: 0x8A3A0A)],
                                             center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: 46))
                        .frame(width: 70, height: 70)
                    Ellipse()
                        .stroke(Color(hex: 0xFFD8A8).opacity(0.55), lineWidth: 1.2)
                        .frame(width: 118, height: 26)
                        .rotationEffect(.degrees(-14))
                }
                .position(x: size.width - 10, y: size.height - 4)
            }
        }
    }
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
struct CategoryRulesStats {
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
