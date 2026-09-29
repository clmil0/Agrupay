import SwiftUI
import SwiftData

@main
struct NotifableApp: App {
    /// Sólo para `PrivacyShield`: `applicationWillResignActive` es el único
    /// punto que UIKit garantiza que corre antes de que el sistema fotografíe
    /// la pantalla para el selector de apps.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // El mismo contenedor que usan los intents de Siri: ver `AppModelContainer`.
    var sharedModelContainer: ModelContainer { AppModelContainer.shared }

    init() {
        // Traduce el `dashboardFilter` guardado por la versión anterior al
        // nuevo `Period` único y borra las claves que ya no existen.
        Period.migrateLegacyFilterIfNeeded()
        // Conserva la elección previa de isDarkMode: quien tenía modo oscuro
        // sigue en oscuro, no pasa a "Automático".
        AppAppearance.migrateIfNeeded()
        // La hora del recordatorio de deuda se guardaba como fecha completa y
        // quedaba anclada al día en que se configuró.
        NotificationSettings.migrateIfNeeded()
        // «Ocultar montos al abrir»: el ojito arranca cerrado.
        AmountPrivacy.applyLaunchPreference()
        // Rebrand: el tema pasa a "Azul" (el azul del ícono), una sola vez.
        AppThemeColor.migrateToBrandBlueIfNeeded()
        // En `init` y no en el `.task` de la ventana: cuando Siri despierta la
        // app en segundo plano no se monta ninguna escena, y el guardado de un
        // intent también tiene que llegar a los widgets.
        #if DEBUG
        // Datos falsos para probar en el simulador (`-qaFakeData`).
        MainActor.assumeIsolated { QAMode.prepare(container: AppModelContainer.shared) }
        #endif
        StoreRevision.start()
        WidgetSnapshotWriter.shared.start(container: AppModelContainer.shared)
        // También en `init`: registrar una tarea de segundo plano después de
        // que la app termine de lanzarse es un error fatal.
        BackgroundSync.register()
        // Quien ya venía usando la app no tiene por qué ver el onboarding: si
        // hay correo conectado o correos ya procesados, se da por visto.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "hasSeenOnboarding") == nil {
            let yaUsaba = GmailAuthService.hasStoredSession
                || !(defaults.stringArray(forKey: "processedEmailIDs") ?? []).isEmpty
            defaults.set(yaUsaba, forKey: "hasSeenOnboarding")
        }
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var backupManager = ConfigBackupManager.shared
    /// Primera apertura: el carrusel y la pantalla de login. Lo pone en `true`
    /// la propia `OnboardingView` al terminar.
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(AppThemeColor(rawValue: appAccentColor)?.color ?? .purple)
                .appTextSize()
                .appAppearance()
                .task {
                    AvatarCatalog.prewarm()
                    // En modo QA nada sale del teléfono: sin respaldo en la
                    // nube, Amigos ni recordatorios.
                    guard GmailSyncService.qaToken == nil else {
                        GmailSyncService.shared.modelContext = sharedModelContainer.mainContext
                        FriendDebts.shared.start(container: sharedModelContainer)
                        #if DEBUG
                        QAMode.seedSocial()
                        QAMode.seedDebts(container: sharedModelContainer)
                        #endif
                        // Sólo avisos locales y el numerito del ícono: nada
                        // sale del teléfono.
                        NotificationManager.shared.start(container: sharedModelContainer)
                        NotificationManager.shared.requestPermission()
                        return
                    }
                    Diagnostics.shared.log("Configurando respaldo y amigos")
                    // A partir de aquí la sincronización se dispara sola con
                    // cada guardado; ninguna vista tiene que avisarle de nada.
                    backupManager.configure(container: sharedModelContainer)
                    // Pinta Amigos con lo último que se vio, antes de que
                    // AmigosHubView llegue a pedir nada por red.
                    FriendsManager.shared.configure(container: sharedModelContainer)
                    // Y re-publica lo que les compartes cada vez que cambia
                    // el gasto del mes.
                    ShareAutoSync.shared.start(container: sharedModelContainer)
                    // Los pagos entre amigos: detectar los tuyos y anotar
                    // los que te hicieron.
                    FriendDebts.shared.start(container: sharedModelContainer)
                    Task {
                        await PaymentReminders.shared.uploadStoredToken()
                        await PaymentReminders.shared.refresh()
                    }
                    // Duplicados de Apple que dejaron las lecturas por rango
                    // anteriores al arreglo de `existingEmailIDs`.
                    GmailSyncService.removeLinkedDuplicates(in: sharedModelContainer.mainContext)
                    NotificationManager.shared.start(container: sharedModelContainer)
                    if hasSeenOnboarding { NotificationManager.shared.requestPermission() }
                    Diagnostics.shared.log("Respaldo y amigos configurados")
                }
                // Presentación en cadena: primero el onboarding y sólo después,
                // si esa cuenta ya tenía respaldo, la oferta de restaurarlo. Dos
                // `fullScreenCover` a la vez no se pueden mostrar, y el orden
                // importa: la oferta no significa nada antes de conectar Gmail.
                .fullScreenCover(isPresented: .init(get: { !hasSeenOnboarding },
                                                    set: { hasSeenOnboarding = !$0 })) {
                    OnboardingView()
                }
                // Recién terminado el onboarding: no antes, para no tapar el
                // carrusel con el diálogo del sistema.
                .onChange(of: hasSeenOnboarding) { _, seen in
                    if seen { NotificationManager.shared.requestPermission() }
                }
                // En pausa sobre una copia con datos y el usuario cambió algo:
                // la sincronización automática la borraría, así que pregunta.
                .sheet(item: $backupManager.overwritePrompt) { header in
                    OverwriteBackupSheet(header: header,
                                         accent: AppThemeColor(rawValue: appAccentColor) ?? .blue) {
                        Task { await backupManager.restoreInsteadOfOverwrite() }
                    } onOverwrite: {
                        Task { await backupManager.confirmOverwrite() }
                    } onLater: {
                        backupManager.postponeOverwrite()
                    }
                }
                // Celular nuevo: la cuenta que acaba de conectar ya tenía un
                // respaldo. Se pregunta una sola vez.
                .fullScreenCover(item: $backupManager.foundBackup) { header in
                    BackupFoundView(header: header) {
                        Task { await backupManager.acceptFoundBackup() }
                    } onSkip: {
                        backupManager.dismissBackupOffer()
                    }
                }
        }
        .modelContainer(sharedModelContainer) // Inyecta la BD a todas las vistas
        .onChange(of: scenePhase) { oldPhase, newPhase in
            Diagnostics.shared.log("Fase: \(oldPhase) → \(newPhase)")
            // El bloqueo se arma al **salir**, no al volver: `.inactive` es la
            // pantalla que iOS fotografía para el conmutador de apps, así que
            // esperar al regreso dejaría el saldo a la vista en la vista de
            // tarjetas. `AppLock` ignora el paso a `.inactive` que provoca el
            // propio diálogo de Face ID.
            if newPhase == .active {
                AppLock.shared.sceneDidBecomeActive()
            } else {
                AppLock.shared.sceneWillResignActive()
                GmailSyncService.shared.stopForegroundPolling()
                // Con la app cerrada el correo lo mira el sistema cuando
                // puede; ver `BackgroundSync`.
                BackgroundSync.schedule()
            }

            if newPhase == .active, GmailSyncService.qaToken == nil {
                if GmailAuthService.shared.isAuthenticated {
                    GmailSyncService.shared.modelContext = sharedModelContainer.mainContext
                    GmailSyncService.shared.syncEmails()
                }
                GmailSyncService.shared.startForegroundPolling()
                Task { await ConfigBackupManager.shared.checkForExistingBackup() }
                // Al volver a la app: si llegó un recordatorio con ella
                // cerrada, aquí aparece aunque la notificación se perdiera.
                Task { await PaymentReminders.shared.refresh() }
                // Sólo pregunta la versión; baja la lista si hay comercios nuevos.
                Task { await MerchantCatalog.shared.refreshIfNeeded() }
            }
        }
    }

}
