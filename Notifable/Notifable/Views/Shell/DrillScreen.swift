import SwiftUI

/// Una pantalla a la que se entra desde el dashboard (`1b`): Movimientos,
/// Análisis, Categorías, Etiquetas, Pendientes, Social o Perfil.
///
/// Las hermanas comparten pantalla y se alternan con la píldora del header,
/// **sin** apilar otra pantalla encima: de Movimientos a Análisis y de vuelta
/// se vuelve al dashboard con un solo «atrás», que es lo que se espera de dos
/// vistas del mismo dato.
///
/// Social y Perfil conservan su diseño de siempre: sólo cambia cómo se llega a
/// ellas.
struct DrillScreen: View {
    let entry: AppSection

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme

    @State private var section: AppSection
    @State private var progress = ScrollProgress()
    @State private var scrollToTopTrigger = false

    init(entry: AppSection) {
        self.entry = entry
        self._section = State(initialValue: entry)
    }

    private var palette: Palette { Palette(scheme) }

    var body: some View {
        ZStack(alignment: .top) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            DrillHeader(progress: progress, onBack: { dismiss() }) {
                if entry.siblings.count > 1 {
                    SubtabPill(tabs: entry.siblings, selection: $section) { tab in
                        // Solicitudes de amistad y cobros que te recuerdan: los
                        // dos se atienden en la misma pantalla fusionada.
                        guard tab == .social else { return nil }
                        let pending = FriendsManager.shared.incomingRequests.count
                            + PaymentReminders.shared.inbox.count
                        return pending > 0 ? pending : nil
                    }
                }
            }
        }
        .background {
            // Con tema Pro, el cielo del Resumen atenuado: se nota el tema
            // y el texto sigue leyéndose sobre liso.
            if let proTheme {
                ProThemeBackdrop(theme: proTheme, calm: true)
            } else {
                palette.background.ignoresSafeArea()
            }
        }
        .background(SwipeBackEnabler().frame(width: 0, height: 0))
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: section) { _, _ in progress.reset() }
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
        }
    }
}
