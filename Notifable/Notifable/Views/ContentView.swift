import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var recurringRules: [RecurringExpense]
    @AppStorage("remindRecurring") private var remindRecurring = true
    @State private var didResolveRecurring = false
    /// Lo que se apiló sobre el dashboard. Casi siempre una sola pantalla: las
    /// hermanas (Movimientos ↔ Análisis) se alternan dentro de ella.
    @State private var path: [AppSection] = []

    /// El desplazamiento del dashboard, en una clase observable para no
    /// invalidar este cuerpo en cada fotograma (ver `ScrollProgress`).
    @State private var scrollProgress = ScrollProgress()
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    
    var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    var themeColor: Color { accent.color }
    @State private var showSettings = false

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
        guard let link = pendingLink, !appLock.isLocked, !showSplash else { return }
        pendingLink = nil
        showSettings = false

        switch link {
        case let .add(isIncome, source):
            presentAdd(isIncome ? .ingreso : .gasto, source: source, quickID: nil)
        case .quick(let id):
            presentAdd(.gasto, source: nil, quickID: id)
        // Los enlaces `agrupay://` de los widgets y de Siri siguen siendo los
        // mismos; lo que cambia es dónde aterrizan: ya no hay pestañas, así
        // que cada uno abre su pantalla sobre el dashboard.
        case .summary:
            selectedTransactionType = nil
            path = []
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

    /// Deja una sola pantalla sobre el dashboard: la pedida.
    private func open(_ section: AppSection) {
        selectedTransactionType = nil
        path = [section]
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
            NavigationStack(path: $path) {
                ZStack(alignment: .bottom) {
                    DashboardScreen(progress: scrollProgress,
                                    onOpen: { path.append($0) },
                                    onSettings: { showSettings = true })

                    // Degradado al pie: sin él las tarjetas se leen a través
                    // del FAB y de «Dictar». Llega hasta el borde físico de la
                    // pantalla —la franja del indicador de inicio incluida—:
                    // si se quedaba en el área segura, las tarjetas volvían a
                    // verse nítidas debajo y se notaba el corte.
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        LinearGradient(stops: [.init(color: Palette(systemScheme).background.opacity(0), location: 0),
                                               .init(color: Palette(systemScheme).background.opacity(0.85), location: 0.45),
                                               .init(color: Palette(systemScheme).background, location: 0.75)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 170)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)

                    HStack(alignment: .bottom) {
                        ShellDictateButton(isDictating: showsDictation) { showsDictation = true }
                            .padding(.bottom, 4)
                        Spacer()
                        ShellFAB { presentAdd(.ingreso, source: nil, quickID: nil) }
                    }
                    .padding(.horizontal, ShellMetrics.sideInset)
                    .padding(.bottom, 4)
                }
                .background(Palette(systemScheme).background.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: AppSection.self) { section in
                    DrillScreen(entry: section)
                }
            }
            .background(Palette(systemScheme).background.ignoresSafeArea())
            .ignoresSafeArea(.keyboard)
            .onAppear(perform: resolveRecurring)
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
            // Social: se piden al abrir, sin esperar a que se visite.
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
            .fullScreenCover(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(item: $selectedTransactionType, onDismiss: {
                linkedSource = nil
                linkedQuickID = nil
            }) { type in
                AddTransactionSheet(transactionType: type, source: linkedSource, savingQuick: linkedQuickID)
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
            if appLock.isLocked {
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
    
    // MARK: - Blindaje de privacidad

    /// Fondo + ícono, nada interactivo. A propósito no es `LockScreenView`:
    /// esa arranca Face ID en `.task` al aparecer, y esta vista está montada
    /// todo el tiempo — dispararía el diálogo del sistema con la app en
    /// segundo plano. Sólo tapa hasta que la pantalla de verdad llega.
    private var privacyShield: some View {
        ZStack {
            // Oscuro como el bloqueo que tapa: si no, el paso de uno a otro
            // destellaba en claro.
            Palette(.dark).background.ignoresSafeArea()
            AppIconTile(size: 64, accent: themeColor, coinFace: .white, detail: false)
        }
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
