import SwiftUI
import UIKit

/// Las pestañas de la barra de abajo, que es la del sistema (`TabView`).
///
/// Vuelven las pestañas que `1b` había quitado, pero sólo para lo que se usa
/// a diario: el Resumen, Movimientos y Amigos. Categorías, Etiquetas y
/// Pendientes se siguen abriendo desde su tarjeta del Resumen.
enum RootTab: Int, CaseIterable, Identifiable {
    case summary
    case movements
    case goals
    case friends
    /// El «+»: va como la pestaña de búsqueda, que en iOS 26 el sistema dibuja
    /// como un círculo aparte a la derecha. Nunca queda elegida.
    case add

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .summary:   return "Resumen"
        case .movements: return "Movimientos"
        case .goals:     return "Metas"
        case .friends:   return "Amigos"
        case .add:       return "Registrar"
        }
    }

    var icon: String {
        switch self {
        case .summary:   return "chart.pie.fill"
        case .movements: return "list.bullet"
        case .goals:     return "target"
        case .friends:   return "person.2.fill"
        case .add:       return "plus"
        }
    }

    /// La pestaña en la que vive una sección. `nil`: no tiene pestaña propia
    /// y se apila sobre el Resumen (Categorías, Etiquetas, Pendientes).
    init?(hosting section: AppSection) {
        switch section {
        case .movements, .analysis:               self = .movements
        case .social, .receivables, .profile:     self = .friends
        case .categories, .tags, .pending:        return nil
        }
    }
}

// MARK: - Mantener presionado el «+»

/// Las pestañas del sistema no tienen gesto de mantener presionado. Éste
/// busca la `UITabBar` de la ventana y le cuelga uno que sólo empieza sobre
/// el «+»: en el resto de la barra no se mete con la gota que se arrastra
/// entre pestañas. Al reconocerse cancela el toque, así que soltar no abre
/// además el formulario.
///
/// Avisa con el marco del «+» en coordenadas de la ventana, para dibujar el
/// micrófono justo encima.
struct TabBarLongPress: UIViewRepresentable {
    let onLongPress: (CGRect) -> Void

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.coordinator = context.coordinator
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// Una vista vacía que, al entrar en la ventana, va a buscar la barra.
    final class Probe: UIView {
        weak var coordinator: Coordinator?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attach(retries: 5)
        }

        /// La barra se monta un instante después que el `TabView`: se
        /// reintenta un par de veces hasta encontrarla.
        private func attach(retries: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, let window, let coordinator else { return }
                if !coordinator.attach(to: window), retries > 0 {
                    attach(retries: retries - 1)
                }
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TabBarLongPress
        private weak var tabBar: UITabBar?
        private let recognizer = UILongPressGestureRecognizer()

        init(parent: TabBarLongPress) {
            self.parent = parent
            super.init()
            recognizer.minimumPressDuration = 0.4
            recognizer.delegate = self
            recognizer.addTarget(self, action: #selector(pressed(_:)))
        }

        /// `false` si todavía no hay barra.
        @discardableResult
        func attach(to window: UIWindow) -> Bool {
            guard let bar = Self.findTabBar(in: window) else { return false }
            guard bar !== tabBar else { return true }
            tabBar?.removeGestureRecognizer(recognizer)
            bar.addGestureRecognizer(recognizer)
            tabBar = bar
            return true
        }

        @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let tabBar, let frame = itemFrame(in: tabBar) else { return }
            parent.onLongPress(tabBar.convert(frame, to: nil))
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let tabBar, let frame = itemFrame(in: tabBar) else { return false }
            return frame.insetBy(dx: -6, dy: -6).contains(recognizer.location(in: tabBar))
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// El botón del «+»: el control que queda más a la derecha. En iOS 26
        /// es el círculo aparte de la pestaña de búsqueda; en la barra clásica
        /// de iOS 18, la última pestaña. Los botones de la barra no llevan su
        /// título en la jerarquía de vistas, así que se buscan por posición.
        private func itemFrame(in tabBar: UITabBar) -> CGRect? {
            var best: CGRect?
            func visit(_ view: UIView) {
                guard !view.isHidden, view.alpha > 0 else { return }
                if view is UIControl, view.bounds.width > 0 {
                    let frame = view.convert(view.bounds, to: tabBar)
                    if best.map({ frame.maxX > $0.maxX }) ?? true { best = frame }
                }
                view.subviews.forEach(visit)
            }
            visit(tabBar)
            return best
        }

        private static func findTabBar(in view: UIView) -> UITabBar? {
            if let bar = view as? UITabBar, !bar.isHidden { return bar }
            for subview in view.subviews {
                if let bar = findTabBar(in: subview) { return bar }
            }
            return nil
        }
    }
}

// MARK: - Micrófono sobre el «+»

/// El círculo con micrófono que sale encima del «+» al mantenerlo presionado.
/// Tocar fuera lo guarda.
struct DictationBubble: View {
    /// El marco del «+» en la ventana.
    let anchor: CGRect
    var isDictating = false
    let onDictate: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    private var palette: Palette { Palette(scheme).themed(proTheme) }

    private static let size: CGFloat = 56

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .onTapGesture(perform: onDismiss)

                Button(action: onDictate) {
                    Image(systemName: isDictating ? "mic.fill" : "mic")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(palette.label)
                        .frame(width: Self.size, height: Self.size)
                        .modifier(BubbleSurface(palette: palette))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dictar un gasto")
                .position(x: anchor.midX - origin.x,
                          y: anchor.minY - origin.y - 14 - Self.size / 2)
                .transition(.scale(scale: 0.4, anchor: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
    }
}

/// Vidrio en iOS 26; en iOS 18, la superficie opaca con hairline del resto
/// del chrome.
private struct BubbleSurface: ViewModifier {
    let palette: Palette

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(palette.surface, in: Circle())
                .overlay(Circle().stroke(palette.hairline, lineWidth: 0.5))
        }
    }
}

// MARK: - Metas

/// Metas todavía no tiene diseño: la pestaña existe para que la barra tenga
/// su forma final.
struct GoalsPlaceholderView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    private var palette: Palette { Palette(scheme).themed(proTheme) }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "target")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(palette.secondaryLabel)
            Text("Metas")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(palette.label)
            Text("Muy pronto")
                .font(.system(size: 15))
                .foregroundStyle(palette.secondaryLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
