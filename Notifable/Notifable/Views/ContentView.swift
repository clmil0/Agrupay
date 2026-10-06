import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var recurringRules: [RecurringExpense]
    /// La bandeja de Pendientes: el globo de Movimientos y su «visto».
    @Query private var unclassified: [Expense]
    @AppStorage("remindRecurring") private var remindRecurring = true
    @State private var didResolveRecurring = false
    /// Lo que se apiló sobre el Resumen. Casi siempre una sola pantalla: las
    /// hermanas (Categorías ↔ Etiquetas) se alternan dentro de ella.
    @State private var path: [AppSection] = []

    @State private var tab: RootTab = .summary
    /// La hermana visible en cada pestaña con píldora.
    @State private var movementsSection: AppSection = .movements
    @State private var friendsSection: AppSection = .social
    /// Dónde está el «+» de la barra mientras se mantiene presionado: ahí
    /// encima sale el micrófono. `nil`: no se muestra.
    @State private var micAnchor: CGRect?

    /// El desplazamiento del dashboard, en una clase observable para no
    /// invalidar este cuerpo en cada fotograma (ver `ScrollProgress`).
    @State private var scrollProgress = ScrollProgress()
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    
    /// Tema Pro del Resumen (`3b`–`3e`): sólo con Pro activo.
    @AppStorage(ProTheme.storageKey) private var proThemeRaw = ""
    @AppStorage(ProStore.enabledKey) private var isPro = false
    private var proTheme: ProTheme? { isPro ? ProTheme(rawValue: proThemeRaw) : nil }

    var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    var themeColor: Color { accent.color }
    @State private var showSettings = false
    /// Ver el `.id` del `NavigationStack`.
    @State private var paletteRevision = 0
    @State private var appliedTones = ProTheme.toneSignature

    @Environment(\.colorScheme) private var systemScheme
    @State private var selectedTransactionType: TransactionType? = nil
    @State private var showsDictation = false
    /// Lo que pidió el último enlace `agrupay://` para el formulario.
    @State private var linkedSource: String?
    @State private var linkedQuickID: UUID?
    /// Un enlace que llegó con la app bloqueada o con el splash: se aplica al
    /// desbloquear, nunca por encima de la pantalla de bloqueo.
    @State private var pendingLink: AppDeepLink?
    @State private var showSplash = true
    @StateObject private var appLock = AppLock.shared
    /// El movimiento al que pidió ir una hoja (`ActivityFocus`): se abre su
    /// detalle en cuanto las hojas de encima terminan de bajar.
    @State private var focusedExpense: Expense?
    @State private var focusedIncome: Income?
    @Environment(\.scenePhase) private var scenePhase
    @State private var reminders = PaymentReminders.shared
    @State private var auth = SupabaseAuthManager.shared

    init() {
        // Lo mismo que cuenta Pendientes (`countsAsSpending`).
        let unclassified = Accounting.unclassified
        _unclassified = Query(filter: #Predicate<Expense> {
            $0.category == unclassified && !$0.isTransfer && !$0.isVoided && !$0.isReversal && !$0.isSplit
        })
    }

    /// El fondo liso del Resumen: el del tema Pro o el de siempre.
    private var dashboardBase: Color { proTheme?.base ?? Palette(systemScheme).background }

    /// Aplica las reglas con `autoConfirm` y programa el aviso de las que
    /// esperan confirmación. Una vez por sesión.
    private func resolveRecurring() {
        guard !didResolveRecurring else { return }
        didResolveRecurring = true

        // Sólo la ventana que el motor necesita para casar cada regla con el
        // cobro que ya llegó del banco. Antes esto venía de un `@Query` sin
        // predicado en la raíz: la app materializaba el historial completo al
        // arrancar —y lo mantenía vivo— para una comprobación que corre una
        // vez por sesión.
        let expenses = recurringExpenses()

        RecurringEngine.applyAutomatic(rules: recurringRules, expenses: expenses, in: modelContext)
        try? modelContext.save()

        // También una vez por sesión: `isTransfer` al día con «Tus cuentas»
        // aunque éstas hayan llegado de un respaldo o de otra versión.
        TransferDetector.apply(in: modelContext)

        let awaiting = RecurringEngine.pending(rules: recurringRules, expenses: expenses)
            .filter(\.isAwaiting)
        let count = awaiting.reduce(0) { $0 + $1.dates.count }
        let total = Money.sum(awaiting) { $0.totalAmount }
        NotificationManager.shared.updateRecurringReminder(
            count: count,
            total: total,
            merchant: awaiting.first.map { Accounting.displayName($0.merchant) },
            enabled: remindRecurring
        )
    }

    /// Los gastos de la ventana de casado de recurrentes. Sin reglas activas
    /// no hay nada que casar y no se pide nada.
    private func recurringExpenses() -> [Expense] {
        guard let window = RecurringEngine.matchWindow(rules: recurringRules) else { return [] }
        let start = window.start
        let end = window.end
        let descriptor = FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\Expense.date, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Enlaces

    private func applyPendingLinkIfReady() {
        guard let link = pendingLink, !showSplash else { return }
        if appLock.isLocked {
            // Anotar desde el widget no espera al desbloqueo: Face ID se pide
            // al bajar el formulario. Lo demás sí espera.
            guard link.isQuickEntry else { return }
            appLock.beginQuickEntry()
        }
        pendingLink = nil
        showSettings = false

        switch link {
        case let .add(isIncome, source):
            presentAdd(isIncome ? .ingreso : .gasto, source: source, quickID: nil)
        case .quick(let id):
            presentAdd(.gasto, source: nil, quickID: id)
        // Los enlaces `agrupay://` de los widgets y de Siri siguen siendo los
        // mismos: cada uno abre su pestaña, o su pantalla sobre el Resumen.
        case .summary:
            selectedTransactionType = nil
            path = []
            select(.summary)
        case .categories:
            open(.categories)
        case .pending:
            open(.pending)
        case .rhythm:
            open(.analysis)
        case .friends:
            open(.social)
        case .friendInvite(let code):
            FriendInviteRouter.shared.pendingCode = code
            open(.social)
        }
    }

    // MARK: - Cobro intenso

    /// La sesión de Amigos antes sólo se abría al entrar a Amigos, y hasta
    /// entonces no se podían pedir los cobros: el modal intenso salía recién
    /// ahí. Ahora se abre al arrancar, en silencio (sin pantallas de login).
    private func startFriendsSession() async {
        #if DEBUG
        if QAMode.isOn { return }
        #endif
        guard !auth.isReady, !auth.needsGoogleAccount else { return }
        let name = SocialProfileStore.shared.displayName
        await auth.ensureSession(defaultName: name.isEmpty ? "Amigo" : name)
    }

    /// El modal de un cobro intenso sale al abrir la app (`1c`), nunca por
    /// encima del splash ni del bloqueo.
    private func presentReminderIfReady() {
        guard !showSplash, !appLock.isLocked, scenePhase == .active,
              !PaymentReminderModalPresenter.isPresenting,
              let reminder = reminders.pendingModal else { return }
        // Un respiro para que la pantalla termine de asentarse: el personaje
        // cae sobre la app ya quieta.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !showSplash, !appLock.isLocked, reminders.pendingModal?.id == reminder.id else { return }
            PaymentReminderModalPresenter.present(reminder)
        }
    }

    /// Lleva a una sección desde un enlace: a su pestaña si tiene, o como una
    /// sola pantalla sobre el Resumen.
    private func open(_ section: AppSection) {
        selectedTransactionType = nil
        path = []
        show(section)
    }

    /// Lo que piden las tarjetas del Resumen: Movimientos y Amigos cambian
    /// de pestaña; lo demás se apila encima.
    private func show(_ section: AppSection) {
        switch RootTab(hosting: section) {
        case .movements:
            movementsSection = section
            select(.movements)
        case .friends:
            friendsSection = section
            select(.friends)
        default:
            select(.summary)
            path.append(section)
        }
    }

    private func select(_ newTab: RootTab) {
        tab = newTab
    }

    // MARK: - Analítica

    /// Lo que se ve debajo de las hojas: `summary`, `summary/categories`,
    /// `movements/pending`, `friends/receivables`…
    private var rootScreenName: String {
        switch tab {
        case .summary:
            return path.last.map { "summary/" + $0.analyticsName } ?? "summary"
        case .movements: return "movements/" + movementsSection.analyticsName
        case .friends:   return "friends/" + friendsSection.analyticsName
        case .goals:     return "goals"
        case .add:       return "summary"
        }
    }

    private func sectionSelected(_ section: AppSection) {
        Analytics.track(.sectionSelect, ["section": section.analyticsName])
        if let feature = section.analyticsFeature { Analytics.featureUsed(feature) }
    }

    /// El «+» es una pestaña más para el sistema (la de búsqueda, que en iOS
    /// 26 se dibuja como círculo aparte), pero no se elige: abre el
    /// formulario y la pestaña de antes sigue abierta.
    private var tabSelection: Binding<RootTab> {
        Binding(get: { tab }, set: { newTab in
            micAnchor = nil
            if newTab == .add {
                Analytics.tap("tabbar.add")
                presentAdd(.gasto, source: nil, quickID: nil)
                return
            }
            if newTab != tab { Analytics.track(.tabSelect, ["tab": newTab.analyticsName]) }
            // Llegó algo sin clasificar que aún no se vio: Movimientos abre
            // la bandeja esta vez; las siguientes, la lista.
            if newTab == .movements, tab != .movements {
                if PendingInbox.hasUnseen(pendingIDs) {
                    movementsSection = .pending
                } else if movementsSection == .pending {
                    movementsSection = .movements
                }
            }
            tab = newTab
        })
    }

    /// Solicitudes, cobros que te recuerdan y «¿esto fue un pago?»: lo mismo
    /// que suman los globos de la píldora de Amigos.
    private var friendsBadge: Int {
        FriendsManager.shared.incomingRequests.count
            + PaymentReminders.shared.inbox.count
            + FriendDebts.shared.suggestions.count
    }

    /// Lo sin clasificar de este mes: lo mismo que el número grande de la
    /// tarjeta Pendientes y el ícono de la app. Lo de meses anteriores sigue
    /// en la bandeja, pero ni pinta globo ni lleva a ella.
    private var monthPending: [Expense] {
        let range = Period(granularity: .mes, reference: Date()).interval
        return unclassified.filter { $0.date >= range.start && $0.date < range.end }
    }

    private var pendingIDs: [UUID] { monthPending.map(\.id) }

    /// La bandeja en pantalla cuenta como vista.
    private func markPendingSeenIfShown() {
        guard tab == .movements, movementsSection == .pending else { return }
        PendingInbox.markSeen(pendingIDs)
    }

    /// Si ya había un formulario abierto se cierra primero: cambiar el
    /// `item` de una hoja presentada no la vuelve a construir.
    private func presentAdd(_ type: TransactionType, source: String?, quickID: UUID?) {
        let open = {
            linkedSource = source
            linkedQuickID = quickID
            selectedTransactionType = type
        }
        if selectedTransactionType != nil {
            selectedTransactionType = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: open)
        } else {
            open()
        }
    }

    var body: some View {
        ZStack {
            tabs
            // Las variantes de los temas Pro no pasan por el entorno: al volver
            // de Configuración con otra variante, el Resumen se vuelve a armar.
            .id(paletteRevision)
            .background(Palette(systemScheme).background.ignoresSafeArea())
            .ignoresSafeArea(.keyboard)
            .onAppear(perform: resolveRecurring)
            .onChange(of: tab) { _, _ in markPendingSeenIfShown() }
            // Mi cabecera en Social sigue al fondo Pro mientras no elija otra:
            // que mis amigos vean el cambio.
            .onChange(of: proThemeRaw) { _, _ in
                Task { await SupabaseAuthManager.shared.pushSocialStyle() }
            }
            .onChange(of: movementsSection) { _, section in
                markPendingSeenIfShown()
                sectionSelected(section)
            }
            .onChange(of: friendsSection) { _, section in sectionSelected(section) }
            // La pantalla de abajo de la pila de `ScreenTracker`: la pestaña,
            // su sección o lo apilado sobre el Resumen.
            .onChange(of: rootScreenName, initial: true) { _, name in
                ScreenTracker.shared.setRoot(name)
            }
            .onAppear { AnalyticsPerformance.markFirstFrame() }
            .onChange(of: pendingIDs) { _, _ in markPendingSeenIfShown() }
            .onChange(of: appLock.isLocked) { _, locked in
                // Ajustes y las hojas se presentan en la capa de modales de
                // iOS, por encima de este `ZStack`: si quedaran abiertas, la
                // pantalla de bloqueo estaría **detrás** de ellas y no taparía
                // nada. Bloquear cierra lo que hubiera encima.
                guard locked else { return }
                PaymentReminderModalPresenter.suspend()
                showSettings = false
                selectedTransactionType = nil
                showsDictation = false
            }
            .gmailLinkFlow(isEnabled: !showSettings)
            // Las solicitudes de amistad pintan un número en la pestaña
            // Amigos: se piden al abrir, sin esperar a que se visite.
            .task {
                await startFriendsSession()
                if SupabaseAuthManager.shared.isReady { await FriendsManager.shared.refresh() }
                await reminders.refresh()
                // Lo que te pagaron entra como ingreso sin tener que abrir Amigos.
                await FriendDebts.shared.refresh()
            }
            // Los cobros se piden al abrir, no sólo al visitar Amigos: el
            // modo intenso tiene que salir apenas se abre la app.
            .onChange(of: auth.isReady) { _, ready in
                guard ready else { return }
                Task {
                    await reminders.refresh()
                    await FriendsManager.shared.refresh()
                    await FriendDebts.shared.refresh()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    await startFriendsSession()
                    await reminders.refresh()
                }
                // Día o mes nuevo: el numerito del ícono se vuelve a contar.
                NotificationManager.shared.recount()
                presentReminderIfReady()
            }
            .onChange(of: reminders.pendingModal?.arrivalKey) { _, _ in presentReminderIfReady() }
            .fullScreenCover(isPresented: $showSettings, onDismiss: {
                let tones = ProTheme.toneSignature
                guard tones != appliedTones else { return }
                appliedTones = tones
                paletteRevision += 1
            }) {
                SettingsView()
            }
            .sheet(item: $selectedTransactionType, onDismiss: {
                linkedSource = nil
                linkedQuickID = nil
                appLock.endQuickEntry()
            }) { type in
                AddTransactionSheet(transactionType: type, source: linkedSource, savingQuick: linkedQuickID,
                                    isLockedEntry: appLock.defersForQuickEntry)
            }
            .sheet(isPresented: $showsDictation) {
                DictationSheet()
                    .presentationDetents([.fraction(0.72), .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
            }
            .onOpenURL { url in
                guard let link = AppDeepLink(url: url) else { return }
                Diagnostics.shared.log("Enlace: \(url.host ?? "")")
                if case .friendInvite = link {
                    AppOpenTracker.note("invite")
                } else {
                    // Los widgets y la app Atajos abren con `agrupay://`.
                    AppOpenTracker.note("link", ["link": url.host ?? "?"])
                }
                pendingLink = link
                applyPendingLinkIfReady()
            }
            .onChange(of: appLock.isLocked) { _, _ in
                applyPendingLinkIfReady()
                presentReminderIfReady()
            }
            .onReceive(NotificationCenter.default.publisher(for: ActivityFocus.notification)) { note in
                guard let request = ActivityFocus.request(from: note) else { return }
                Task { await focus(on: request) }
            }
            .sheet(item: $focusedExpense) { ExpenseDetailsView(expense: $0) }
            .sheet(item: $focusedIncome) { IncomeDetailsView(income: $0) }
            .onChange(of: showSplash) { _, _ in
                applyPendingLinkIfReady()
                presentReminderIfReady()
            }
            
            // Blindaje instantáneo: montado siempre, sin `.task` ni
            // transición — sólo cambia opacidad. `LockScreenView` reacciona a
            // `appLock.isLocked` a través de `@Published`, y SwiftUI puede
            // tardar un fotograma en montarla la primera vez; si ese
            // fotograma justo coincide con el que iOS fotografía para el
            // conmutador de apps (lo típico es pasar a segundo plano al
            // toque de haber desbloqueado, con la vista recién reconstruida),
            // el contenido de verdad queda expuesto ahí. Esta capa, al no
            // tener que montarse desde cero, sólo cambia una opacidad sobre
            // una vista que ya existe — lo que sí alcanza a dibujarse a
            // tiempo — y cubre mientras la pantalla interactiva llega.
            privacyShield
                .opacity(appLock.isLocked ? 1 : 0)
                .allowsHitTesting(false)
                .animation(nil, value: appLock.isLocked)
                .zIndex(9)

            // La puerta va por encima de todo lo de esta pantalla, y por
            // debajo del splash: al abrir se ve primero la marca y luego el
            // bloqueo, no los dos peleándose.
            // Con un registro rápido del widget encima, sólo el blindaje: la
            // pantalla de bloqueo pediría Face ID detrás del formulario.
            if appLock.isLocked && !appLock.defersForQuickEntry {
                // Siempre en oscuro (`5l`), sea cual sea el tema: es la
                // pantalla previa a la app, y así no destella al desbloquear.
                LockScreenView(lock: appLock)
                    .environment(\.colorScheme, .dark)
                    .transition(.opacity)
                    .zIndex(10)
            }

            // Splash Screen Overlay: la gota a gota de "Icono y Splash" (handoff
            // de identidad) — reemplaza el placeholder de la campanita.
            if showSplash {
                SplashView {
                    withAnimation(.easeOut(duration: 0.4)) {
                        showSplash = false
                    }
                }
                .transition(.opacity)
            }
        }
    }
    
    // MARK: - Pestañas

    /// La barra es la del sistema: en iOS 26, Liquid Glass con la gota que se
    /// arrastra entre pestañas; en iOS 18, la barra clásica. El ícono elegido
    /// toma el color del tema por el `tint` de la app.
    private var tabs: some View {
        TabView(selection: tabSelection) {
            Tab(RootTab.summary.title, systemImage: RootTab.summary.icon, value: .summary) {
                summaryStack
                    .background { tabBackground(calm: false, paused: !path.isEmpty) }
            }
            Tab(RootTab.movements.title, systemImage: RootTab.movements.icon, value: .movements) {
                SectionScreen(section: $movementsSection, siblings: AppSection.movements.siblings,
                              pendingCount: pendingIDs.count)
                    .background { tabBackground() }
            }
            .badge(pendingIDs.count)
            Tab(RootTab.goals.title, systemImage: RootTab.goals.icon, value: .goals) {
                GoalsPlaceholderView()
                    .background { tabBackground() }
            }
            Tab(RootTab.friends.title, systemImage: RootTab.friends.icon, value: .friends) {
                SectionScreen(section: $friendsSection, siblings: AppSection.social.siblings)
                    .background { tabBackground() }
            }
            .badge(friendsBadge)
            Tab(RootTab.add.title, systemImage: RootTab.add.icon, value: .add, role: .search) {
                Color.clear
            }
        }
        // Mantener presionado el «+» saca el micrófono: la barra del sistema
        // no tiene ese gesto, se le cuelga uno (`TabBarLongPress`).
        .background(TabBarLongPress { frame in
            Analytics.featureUsed(.micHold)
            withAnimation(.bouncy(duration: 0.4)) { micAnchor = frame }
        })
        .overlay {
            if let micAnchor {
                DictationBubble(anchor: micAnchor, isDictating: showsDictation,
                                onDictate: {
                                    self.micAnchor = nil
                                    showsDictation = true
                                },
                                onDismiss: {
                                    withAnimation(.bouncy(duration: 0.3)) { self.micAnchor = nil }
                                })
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: micAnchor != nil) { _, shown in shown }
        // El tema Pro va en todas las pestañas y en lo que se apila encima.
        .environment(\.proTheme, proTheme)
    }

    /// El fondo de cada pestaña. Va dentro de cada una y no detrás del
    /// `TabView`: el sistema pinta un fondo opaco por pestaña que lo taparía.
    /// Con tema Pro, el cielo en todas; fuera del Resumen atenuado, para que
    /// las listas se lean sobre liso. Se pausa con Configuración encima o con
    /// una pantalla apilada, que trae su propio cielo; el de las pestañas que
    /// no se ven se pausa solo (`ProThemeBackdrop` mira si está en pantalla).
    @ViewBuilder
    private func tabBackground(calm: Bool = true, paused: Bool = false) -> some View {
        if let proTheme {
            ProThemeBackdrop(theme: proTheme, calm: calm, paused: showSettings || paused)
        } else {
            Palette(systemScheme).background.ignoresSafeArea()
        }
    }

    private var summaryStack: some View {
        NavigationStack(path: $path) {
            DashboardScreen(progress: scrollProgress,
                            onOpen: {
                                Analytics.tap("summary.card", ["section": $0.analyticsName])
                                show($0)
                            },
                            onSettings: {
                                Analytics.tap("summary.settings")
                                showSettings = true
                            })
                // Transparente: el fondo es el cielo compartido de las
                // pestañas. Si no, la pila pinta el negro del sistema encima.
                .containerBackground(.clear, for: .navigation)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: AppSection.self) { section in
                    DrillScreen(entry: section)
                        .onAppear {
                            if let feature = section.analyticsFeature { Analytics.featureUsed(feature) }
                        }
                }
        }
    }

    // MARK: - Blindaje de privacidad

    /// Ver `PrivacyShieldView`: sólo tapa hasta que la pantalla de bloqueo
    /// de verdad llega.
    private var privacyShield: some View {
        PrivacyShieldView()
    }

    // MARK: - Ir a un movimiento

    /// Espera a que bajen las hojas que pidieron ir (se cierran solas al
    /// recibir el aviso) y abre el detalle del movimiento.
    @MainActor
    private func focus(on request: ActivityFocus.Request) async {
        try? await Task.sleep(for: .milliseconds(650))
        let id = request.id
        if let expense = try? modelContext.fetch(FetchDescriptor<Expense>(predicate: #Predicate { $0.id == id })).first {
            focusedExpense = expense
        } else if let income = try? modelContext.fetch(FetchDescriptor<Income>(predicate: #Predicate { $0.id == id })).first {
            focusedIncome = income
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Expense.self, inMemory: true)
}
