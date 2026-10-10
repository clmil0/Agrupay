import SwiftUI

/// El `ScrollView` de las cuatro pestañas, con "volver arriba" al tocar de
/// nuevo la pestaña que ya está abierta.
///
/// **Antes también publicaba el desplazamiento** en un `@Binding` que subía
/// hasta un `@State` de `ContentView`. Nadie lo leía —ni la cabecera ni la
/// barra de pestañas reaccionaban al scroll—, pero escribirlo invalidaba el
/// cuerpo de `ContentView` entero en cada fotograma del desplazamiento: la
/// cabecera, la barra flotante y la pestaña visible se reevaluaban a 120 Hz, y
/// con ellas `Accounting.totals` sobre todo el historial. Era la causa de que
/// la app se sintiera pesada justo al desplazarse, que es cuando más se nota.
///
/// Si algún día la cabecera tiene que reaccionar al scroll, el sitio es
/// `.onScrollGeometryChange` sobre esta vista, nunca un `@State` de la raíz.
struct TrackableScrollView<Content: View>: View {
    let content: () -> Content
    @Binding var scrollToTopTrigger: Bool
    /// Fila a la que desplazarse, centrada. Se vuelve a `nil` al llegar.
    @Binding var scrollTarget: UUID?
    /// Jalar hacia abajo desde arriba: la rueda gira mientras dura. `nil`, sin
    /// recarga.
    var onRefresh: (@MainActor () async -> Void)?
    /// Si esta lista avisó a `ScrollActivity` de que se desliza: al
    /// desaparecer a mitad de gesto hay que cerrar ese aviso. En una caja y no
    /// en un `@State` suelto: cambiarlo no debe volver a dibujar nada, y como
    /// `@State` reconstruía la lista entera al empezar y al terminar cada
    /// deslizamiento.
    @State private var report = ScrollReport()

    init(scrollToTopTrigger: Binding<Bool> = .constant(false),
         scrollTarget: Binding<UUID?> = .constant(nil),
         onRefresh: (@MainActor () async -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self._scrollToTopTrigger = scrollToTopTrigger
        self._scrollTarget = scrollTarget
        self.onRefresh = onRefresh
        self.content = content
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("top")
                    content()
                }
                // La rueda sale encima del margen de abajo; el contenido sube
                // lo mismo para quedarse donde estaba.
                .padding(.top, onRefresh == nil ? 0 : -PullToRefresh.headerClearance)
            }
            // Sin barra de desplazamiento: con el header y el FAB flotando,
            // la barra del sistema se veía enorme y tapaba el borde derecho.
            .scrollIndicators(.hidden)
            .modifier(PullToRefresh(action: onRefresh))
            .onScrollPhaseChange { _, phase in
                report.update(isScrolling: phase.isScrolling)
            }
            .onDisappear { report.update(isScrolling: false) }
            .onChange(of: scrollToTopTrigger) { _, _ in
                withAnimation {
                    proxy.scrollTo("top", anchor: .top)
                }
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.45)) {
                    proxy.scrollTo(target, anchor: .center)
                }
                scrollTarget = nil
            }
        }
    }
}

/// `.refreshable` sólo si hay qué recargar: sin acción, la lista no se deja
/// jalar.
private struct PullToRefresh: ViewModifier {
    let action: (@MainActor () async -> Void)?

    /// La cabecera flota sobre la lista: sin este margen la rueda quedaba
    /// escondida detrás de ella.
    static let headerClearance = ShellMetrics.headerHeight

    func body(content: Content) -> some View {
        if let action {
            content
                .contentMargins(.top, Self.headerClearance, for: .scrollContent)
                .refreshable { await action() }
        } else {
            content
        }
    }
}

/// Lo que una lista le dijo a `ScrollActivity`. Clase simple, sin observar.
final class ScrollReport {
    private var isScrolling = false

    func update(isScrolling scrolling: Bool) {
        guard scrolling != isScrolling else { return }
        isScrolling = scrolling
        if scrolling { ScrollActivity.began() } else { ScrollActivity.ended() }
    }
}

/// Las animaciones de adorno —el cielo de los temas Pro y las estrellas de
/// la tarjeta Pro— se detienen mientras se desliza Configuración.
///
/// Corrían a 20–30 fotogramas por segundo detrás y encima de las filas
/// mientras el dedo movía la lista: cada fotograma de desplazamiento tenía que
/// volver a componer también el cielo (con su `hueRotation` a pantalla
/// completa). Quieto, el cielo no se nota; con tirones, sí. Sólo lo cambian
/// las listas de Configuración: el Resumen ya iba fluido y su cielo sigue vivo.
@Observable
final class DecorationPause {
    static let shared = DecorationPause()
    private(set) var isScrolling = false

    func setScrolling(_ scrolling: Bool) {
        if scrolling != isScrolling { isScrolling = scrolling }
    }
}

extension View {
    /// Para los `ScrollView` de Configuración, que no son `TrackableScrollView`:
    /// avisan a `ScrollActivity` (lo diferido espera a que se suelte el dedo,
    /// igual que en el Resumen) y detienen los adornos animados.
    func settingsScrollActivity() -> some View {
        modifier(SettingsScrollActivity())
    }
}

private struct SettingsScrollActivity: ViewModifier {
    @State private var report = ScrollReport()

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in
                report.update(isScrolling: phase.isScrolling)
                DecorationPause.shared.setScrolling(phase.isScrolling)
            }
            .onDisappear {
                report.update(isScrolling: false)
                DecorationPause.shared.setScrolling(false)
            }
    }
}
