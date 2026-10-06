import SwiftUI

/// Lo que pasa **después** de conectar Gmail, venga de donde venga: el
/// respaldo encontrado, cuánto correo leer, y la lectura con su progreso.
///
/// Antes esta cadena vivía dentro de `OnboardingView` y sólo existía en la
/// primera apertura. Quien entraba con "Continuar sin cuenta" y vinculaba el
/// correo más tarde, desde Ajustes, se quedaba sin las dos preguntas que
/// importan: volvía a la pantalla de ajustes sin que nadie le dijera que esa
/// cuenta ya tenía configuración guardada, y sin ofrecerle leer su pasado —
/// tenía que descubrir el selector de "DESDE" por su cuenta. Al extraerla
/// aquí, las dos entradas hacen exactamente lo mismo.
struct GmailLinkFlow: View {

    /// Se llama al terminar la cadena — el onboarding entra a la app, Ajustes
    /// cierra la presentación.
    let onFinish: () -> Void

    @Environment(\.colorScheme) private var scheme
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false

    enum Step: Equatable {
        /// Mientras se pregunta al servidor si esa cuenta tiene respaldo.
        case checking
        case restore(BackupHeader)
        case history
        case reading(monthsLabel: String)
    }

    @State private var step: Step = .checking

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .blue }
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()

            switch step {
            case .checking:
                checking
            case .restore(let header):
                OnboardingRestoreView(header: header) { restored in
                    Analytics.track(.onboardingStep, ["step": restored ? "restore_accepted" : "restore_declined"])
                    // "Empezar de cero" no puede subir este teléfono vacío
                    // encima de la copia: queda en pausa apuntando a ella.
                    if !restored { ConfigBackupManager.shared.keepRemotePaused(header) }
                    Task { await advanceAfterAccount(restored: restored) }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            case .history:
                OnboardingHistoryView(usesGmail: true) { monthsLabel in
                    Analytics.track(.rangeSync, ["origin": "link_flow",
                                                 "months": monthsLabel == nil ? 0 : UserDefaults.standard.integer(forKey: "readPeriodMonths")])
                    if let monthsLabel {
                        OnboardingView.step("reading")
                        withAnimation(.snappy) { step = .reading(monthsLabel: monthsLabel) }
                    } else {
                        onFinish()
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            case .reading(let monthsLabel):
                OnboardingReadingView(monthsLabel: monthsLabel) { onFinish() }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: step)
        .task { await lookForBackup() }
    }

    /// Un momento de espera con cara, no una pantalla en blanco: `peek` es una
    /// llamada de red y sin esto el salto desde Google parpadea.
    private var checking: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(accent.color)
            Text("Revisando tu cuenta…")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryLabel)
        }
    }

    private func lookForBackup() async {
        guard step == .checking else { return }
        let manager = ConfigBackupManager.shared
        // La pregunta del respaldo ya está contestada —se restauró, o se dijo
        // "ahora no" en el aviso suelto de `BackupFoundView`—: repetirla aquí
        // sería preguntar dos veces lo mismo. Se pasa directo a la lectura.
        if manager.isEnabled || manager.wasBackupOfferAnswered {
            await advanceAfterAccount(restored: true)
            return
        }
        if let header = await manager.peek(code: nil), header.hasData {
            manager.lastErrorMessage = nil
            OnboardingView.step("restore_offered")
            withAnimation(.snappy) { step = .restore(header) }
        } else {
            manager.lastErrorMessage = nil
            await advanceAfterAccount(restored: false)
        }
    }

    private func advanceAfterAccount(restored: Bool) async {
        let manager = ConfigBackupManager.shared
        // Si no restauró, la sincronización se enciende igual: es una cuenta
        // nueva y a partir de ahora lo que configure se guarda solo. Con la
        // sincronización ya encendida —volver a vincular Gmail desde Ajustes—
        // no hay nada que activar.
        if !restored, !manager.isEnabled, !manager.isPausedAfterWipe {
            await manager.enableWithAccount()
        }
        manager.dismissBackupOffer()
        OnboardingView.step("history")
        withAnimation(.snappy) { step = .history }
    }
}

// MARK: - Presentación

/// Presenta `GmailLinkFlow` en cuanto hay cuenta y queda una vinculación por
/// atender.
///
/// Existe como modificador porque **quién** presenta importa: Ajustes es un
/// `fullScreenCover` de `ContentView`, y una vista que ya tiene un cover encima
/// no puede presentar otro —el modal se quedaba en cola hasta cerrar Ajustes y
/// aparecía en el siguiente arranque—. Así el mismo código se cuelga de los dos
/// sitios: dentro de Ajustes, y en la raíz para cuando Ajustes está cerrado.
private struct GmailLinkFlowPresenter: ViewModifier {

    /// `false` en `ContentView` mientras Ajustes esté abierto: ahí presenta la
    /// copia de dentro, y dos a la vez se estorbarían.
    let isEnabled: Bool

    @AppStorage(GmailAuthService.pendingLinkFlowKey) private var isPending = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @StateObject private var gmailAuth = GmailAuthService.shared
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onAppear(perform: present)
            // `onReceive` y no `onChange`: el token llega en una respuesta de
            // red, y lo que hay que escuchar es la publicación del servicio.
            .onReceive(gmailAuth.$isAuthenticated) { _ in present() }
            .onChange(of: isEnabled) { _, _ in present() }
            .fullScreenCover(isPresented: $isPresented) {
                GmailLinkFlow {
                    isPending = false
                    ConfigBackupManager.shared.isPresentingLinkFlow = false
                    isPresented = false
                }
            }
    }

    private var canPresent: Bool {
        isEnabled && isPending && hasSeenOnboarding && !isPresented
            && GmailAuthService.shared.isAuthenticated
    }

    /// El respiro no es cosmético: el token llega mientras la hoja de Google
    /// todavía se está cerrando, y una presentación lanzada en ese instante se
    /// pierde en silencio —ni error ni cover—. Por eso el modal sólo aparecía
    /// al cerrar Ajustes, que era cuando lo recogía la copia de `ContentView`.
    private func present() {
        guard canPresent else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard canPresent else { return }
            ConfigBackupManager.shared.isPresentingLinkFlow = true
            isPresented = true
        }
    }
}

extension View {
    /// Ver `GmailLinkFlowPresenter`.
    func gmailLinkFlow(isEnabled: Bool = true) -> some View {
        modifier(GmailLinkFlowPresenter(isEnabled: isEnabled))
    }
}
