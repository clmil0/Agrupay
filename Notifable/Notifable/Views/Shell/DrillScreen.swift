import SwiftUI

/// Una pantalla que se apila sobre el Resumen: Categorías o Etiquetas.
/// Movimientos (con Pendientes) y Amigos tienen pestaña propia (`RootTab`).
///
/// Las hermanas comparten pantalla y se alternan con la píldora del header,
/// **sin** apilar otra pantalla encima: de Categorías a Etiquetas y de vuelta
/// se vuelve al Resumen con un solo «atrás», que es lo que se espera de dos
/// vistas del mismo dato.
struct DrillScreen: View {
    let entry: AppSection

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme

    @State private var section: AppSection

    init(entry: AppSection) {
        self.entry = entry
        self._section = State(initialValue: entry)
    }

    var body: some View {
        SectionScreen(section: $section, siblings: entry.siblings, onBack: { dismiss() })
            .background {
                // Con tema Pro, el cielo del Resumen atenuado: se nota el tema
                // y el texto sigue leyéndose sobre liso.
                if let proTheme {
                    ProThemeBackdrop(theme: proTheme, calm: true)
                } else {
                    Palette(scheme).background.ignoresSafeArea()
                }
            }
            .background(SwipeBackEnabler().frame(width: 0, height: 0))
            .toolbar(.hidden, for: .navigationBar)
            // Tiene su propio «volver» y, algunas, su barra de acciones abajo.
            .toolbar(.hidden, for: .tabBar)
    }
}

/// El contenido de una sección con su header: lo comparten las pantallas de
/// drill-down y la raíz de las pestañas Movimientos y Amigos. Sin fondo: lo
/// pone quien la muestra.
struct SectionScreen: View {
    @Binding var section: AppSection
    let siblings: [AppSection]
    /// `nil` en la raíz de una pestaña: no hay a dónde volver.
    var onBack: (() -> Void)?
    /// Cambia al tocar la pestaña que ya está abierta: vuelve arriba.
    var scrollToTopRequest = 0
    /// Lo que queda sin clasificar: el globo de Pendientes en la píldora.
    var pendingCount = 0

    @State private var progress = ScrollProgress()
    @State private var scrollToTopTrigger = false

    var body: some View {
        ZStack(alignment: .top) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            DrillHeader(progress: progress, onBack: onBack) {
                if siblings.count > 1 {
                    SubtabPill(tabs: siblings, selection: $section) { tab in
                        switch tab {
                        // Solicitudes de amistad y cobros que te recuerdan: los
                        // dos se atienden en Amigos.
                        case .social:
                            let pending = FriendsManager.shared.incomingRequests.count
                                + PaymentReminders.shared.inbox.count
                            return pending > 0 ? pending : nil
                        // «¿Esto fue un pago?»: se contesta en Cobros.
                        case .receivables:
                            let questions = FriendDebts.shared.suggestions.count
                            return questions > 0 ? questions : nil
                        case .pending:
                            return pendingCount > 0 ? pendingCount : nil
                        default:
                            return nil
                        }
                    }
                }
            }
        }
        .onChange(of: section) { _, _ in progress.reset() }
        .onChange(of: scrollToTopRequest) { _, _ in scrollToTopTrigger.toggle() }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .movements:
            MovementsView(scrollToTopTrigger: $scrollToTopTrigger, progress: progress)
        case .analysis:
            HistoryView(scrollToTopTrigger: $scrollToTopTrigger, progress: progress)
        case .categories:
            CategoriesOverviewView(scrollToTopTrigger: $scrollToTopTrigger, progress: progress)
        case .tags:
            TagsView(scrollToTopTrigger: $scrollToTopTrigger, progress: progress)
        case .pending:
            PendingView(scrollToTopTrigger: $scrollToTopTrigger, progress: progress)
        case .social:
            SocialHubView(scrollToTopTrigger: $scrollToTopTrigger, progress: progress)
        case .profile:
            ProfileView(scrollToTopTrigger: $scrollToTopTrigger, progress: progress)
        case .receivables:
            ReceivablesView(scrollToTopTrigger: $scrollToTopTrigger, progress: progress)
        }
    }
}
