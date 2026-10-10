import SwiftUI

/// Medidas del chrome flotante. Las cifras salen del documento de diseño
/// (393×852), no de tanteos: cambiarlas aquí las cambia en todas las pantallas.
enum ShellMetrics {
    /// Alto reservado bajo la barra de estado para el header flotante.
    static let headerHeight: CGFloat = 54
    /// Desde el tope del área segura hasta el contenido que se desplaza. El
    /// header flota encima, no lo empuja: este hueco es sólo para que la
    /// primera fila no nazca tapada.
    static let contentTopInset: CGFloat = 58
    /// Espacio al pie de las pantallas a las que se entra desde el dashboard.
    /// En las pestañas la barra del sistema ya corre el área segura; en las
    /// pantallas apiladas no hay barra, y basta con que la última fila no
    /// quede pegada al indicador de inicio (y a la barra de «Asignar» de
    /// Pendientes, que se apoya en este mismo margen).
    static let contentBottomInset: CGFloat = 56

    /// Margen lateral de todas las pantallas: contenido, header y barra de abajo.
    static let sideInset: CGFloat = 22

    static let circleButton: CGFloat = 38
    /// Alto de lo que va en el header de una sección: el «volver», la
    /// cápsula de la izquierda y la píldora de hermanas (`1a`, 44 pt para
    /// que se apunten con el dedo sin mirar).
    static let headerControl: CGFloat = 44
    static let pillCorner: CGFloat = 999

    /// Desplazamiento con el que el degradado de arriba ya se ve entero.
    static let blurThreshold: CGFloat = 24
}

// MARK: - Botón circular del header

/// Ajustes, volver. Superficie opaca con hairline, como el chip de cuentas.
struct ShellCircleButton: View {
    let icon: String
    let label: String
    var tint: Color?
    var size: CGFloat = ShellMetrics.circleButton
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    private var palette: Palette { Palette(scheme).themed(proTheme) }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint ?? palette.secondaryLabel)
                .frame(width: size, height: size)
                // Superficie opaca, no material: el blur se recalculaba en
                // cada fotograma con el contenido pasando por debajo.
                .background(palette.surface, in: Circle())
                .overlay(Circle().stroke(palette.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Píldora de hermanas

/// La píldora de la derecha del header de una pantalla de drill-down: alterna
/// entre hermanas (Movimientos ↔ Análisis) sin volver al dashboard.
struct SubtabPill<Tab: AppSubtab>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    var badge: (Tab) -> Int? = { _ in nil }

    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    private var palette: Palette { Palette(scheme).themed(proTheme) }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                Button {
                    guard selection != tab else { return }
                    withAnimation(.easeInOut(duration: 0.26)) { selection = tab }
                } label: {
                    ZStack {
                        if selection == tab {
                            Capsule().fill(palette.selectedFill)
                                .matchedGeometryEffect(id: "subtab", in: namespace)
                        }
                        Image(systemName: tab.icon)
                            .font(.system(size: 17, weight: selection == tab ? .semibold : .regular))
                            .foregroundStyle(selection == tab ? palette.label : palette.secondaryLabel)
                    }
                    // `1a`: segmentos de 50×38 en una cápsula de 44 — antes
                    // eran círculos de 32 y se tocaba el vecino.
                    .frame(width: 50, height: ShellMetrics.headerControl - 6)
                    .overlay(alignment: .topTrailing) {
                        if let count = badge(tab), selection != tab {
                            Text(count > 99 ? "99+" : "\(count)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(palette.expense, in: Capsule())
                                .offset(x: -4, y: 1)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(3)
        .background(palette.surface, in: Capsule())
        .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
    }

    @Namespace private var namespace
}

// MARK: - Fondo del header

/// El mismo degradado que el pie del dashboard, pero arriba: el contenido se
/// desvanece bajo la barra de estado y el header en lugar de cortarse.
/// Aparece al empezar a desplazarse, para no velar la primera fila en
/// reposo. Lee el desplazamiento aquí dentro para que sólo el fondo se
/// redibuje por fotograma (ver `ScrollProgress`).
///
/// Es un degradado del color de la pantalla, **no un material**: un
/// `.ultraThinMaterial` vuelve a desenfocar lo que pasa por debajo en cada
/// fotograma del scroll, y era lo que hacía que las pantallas se sintieran
/// pesadas al deslizar.
struct ShellHeaderBackground: View {
    let progress: ScrollProgress

    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    private var palette: Palette { Palette(scheme).themed(proTheme) }

    /// Cuánto se alarga el degradado por debajo del header.
    private static let fadeBelow: CGFloat = 36

    private var opacity: Double {
        min(max(progress.offset / ShellMetrics.blurThreshold, 0), 1)
    }

    var body: some View {
        Color.clear
            .overlay {
                LinearGradient(stops: [.init(color: palette.background, location: 0),
                                       .init(color: palette.background, location: 0.3),
                                       .init(color: palette.background.opacity(0.85), location: 0.6),
                                       .init(color: palette.background.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .padding(.bottom, -Self.fadeBelow)
                    .opacity(opacity)
            }
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }
}

// MARK: - Header de drill-down

/// Volver a la izquierda y, si la pantalla tiene hermanas, la píldora a la
/// derecha (`1b` › Movimientos, Categorías).
struct DrillHeader<Trailing: View>: View {
    let progress: ScrollProgress
    /// `nil` en la raíz de una pestaña: sin botón de volver.
    let onBack: (() -> Void)?
    /// En la raíz de una pestaña, lo que ocupa el hueco del «volver».
    var leading: AnyView? = nil
    @ViewBuilder var trailing: Trailing

    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    private var palette: Palette { Palette(scheme).themed(proTheme) }

    var body: some View {
        HStack(spacing: 10) {
            if let onBack {
                ShellCircleButton(icon: "chevron.left", label: "Volver", tint: palette.label,
                                  size: ShellMetrics.headerControl, action: onBack)
            } else if let leading {
                leading
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, ShellMetrics.sideInset)
        .frame(height: ShellMetrics.headerHeight)
        .background(ShellHeaderBackground(progress: progress))
    }
}

// MARK: - Deslizar para volver

/// El header propio esconde la barra de navegación, y con ella iOS apaga el
/// gesto de deslizar desde el borde para volver. Se vuelve a encender desde
/// una vista invisible que busca su `UINavigationController`: sin él, la
/// única forma de salir de Movimientos sería el botón de arriba.
///
/// No se hace con una extensión que sobrescriba `viewDidLoad` de
/// `UINavigationController`: eso reemplaza el método de UIKit en todas las
/// pilas de la app, y se salta lo que UIKit hace ahí.
struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            navigationController?.interactivePopGestureRecognizer?.delegate = self
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            navigationController?.interactivePopGestureRecognizer?.delegate = self
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
