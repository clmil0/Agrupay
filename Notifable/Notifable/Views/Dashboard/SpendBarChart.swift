import SwiftUI

/// El gráfico del dashboard (`2d` de «Resumen Gráficas»): una barra por
/// periodo, lisa. Sólo la elegida lleva color; las demás van en el gris del
/// carril, para que el ojo vaya directo a la que tiene el monto encima. Al
/// entrar cada barra se llena con un rebote corto. Las burbujas de la barra
/// elegida se quitaron: eran lo que trababa el scroll.
///
/// «Semana» son los últimos siete días, uno por barra, terminando hoy. «Mes»
/// son las últimas seis semanas contando la actual, una por barra: treinta
/// barras de un día eran rayas que no se podían tocar.
///
/// Tocar una barra pone su monto encima. Por defecto se ve la última con gasto.
struct SpendBarChart: View {

    enum Mode: String, CaseIterable, Hashable {
        case week = "Semana"
        case month = "Mes"
    }

    struct Column: Identifiable {
        let id: Int
        let label: String
        /// Para VoiceOver: «martes 22», «semana del 15 set».
        let accessibilityLabel: String
        let total: Double
    }

    let columns: [Column]
    @Binding var selected: Int?
    /// La entrada espera a que el dashboard termine de leer el historial: la
    /// animación la mueve el hilo principal fotograma a fotograma, y si
    /// arranca mientras se lee la base, se traba.
    var isReady: Bool = true

    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hidesAmounts) private var hidesAmounts
    @AppStorage(ProStore.enabledKey) private var isPro = false
    private var palette: Palette { Palette(scheme).themed(proTheme) }

    /// Las barras ya llenas; vuelve a `false` para repetir la entrada cuando
    /// cambian los periodos (Semana ↔ Mes, otro mes).
    @State private var filled = false

    private static let barArea: CGFloat = 100
    private static let labelRoom: CGFloat = 22
    /// Aire entre el monto de la barra más alta y el título del gráfico: sin
    /// él, con la barra a la izquierda, el monto quedaba pegado al subtítulo.
    private static let topRoom: CGFloat = 30
    private static let stagger: TimeInterval = 0.07
    private static let sideInset: CGFloat = 14

    private var maximum: Double { columns.map(\.total).max() ?? 0 }

    /// Identifica el juego de periodos, no sus montos: un gasto nuevo no
    /// repite la entrada.
    private var periodsKey: String { columns.map(\.label).joined(separator: "|") + (isReady ? "" : "|…") }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(columns) { column in
                columnView(column)
            }
        }
        // Un poco más angosto que la tarjeta: las barras no llegan a los bordes.
        .padding(.horizontal, Self.sideInset)
        .frame(height: Self.barArea + Self.labelRoom + Self.topRoom, alignment: .bottom)
        .task(id: periodsKey) {
            guard isReady else { filled = false; return }
            guard !reduceMotion else { filled = true; return }
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { filled = false }
            try? await Task.sleep(for: .milliseconds(16))
            filled = true
        }
    }

    private func columnView(_ column: Column) -> some View {
        let isSelected = selected == column.id
        let hasSpend = Money.cents(column.total) > 0
        let barHeight = height(column.total)
        let index = columns.firstIndex { $0.id == column.id } ?? 0

        return VStack(spacing: 7) {
            ZStack(alignment: .bottom) {
                Color.clear.frame(height: Self.barArea)

                // Sube desde abajo desplazándose, recortada por la base: no
                // se deforma (con `scaleEffect` se aplastaban las esquinas y
                // la línea clara) y, al ser sólo un desplazamiento, no
                // obliga a recalcular el layout en cada fotograma.
                bar(hasSpend: hasSpend, isSelected: isSelected, height: barHeight)
                    .offset(y: filled ? 0 : barHeight + 2)
                    .animation(filled ? .spring(duration: 0.55, bounce: 0.3)
                                            .delay(Double(index) * Self.stagger) : nil,
                               value: filled)
                    .clipShape(OpenTopClip())
            }
            .overlay(alignment: .top) {
                if isSelected {
                    Text(Money.formatCompact(column.total).masked(hidesAmounts))
                        .amountVeil()
                        .font(.system(size: 13, weight: .semibold, design: proTheme?.numberDesign ?? .default))
                        .monospacedDigit()
                        .foregroundStyle(palette.duoText ?? (proTheme == nil ? palette.expense : palette.expenseText))
                        .fixedSize()
                        .offset(y: -Self.labelRoom + max(0, Self.barArea - barHeight) - 4)
                        .transition(.opacity)
                }
            }

            Text(column.label)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? palette.expenseText : palette.secondaryLabel)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) { selected = column.id }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(column.accessibilityLabel)
        .accessibilityValue(Money.format(column.total).masked(hidesAmounts))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Color liso sólo en la elegida; las demás, el gris del carril. Sin
    /// degradado, sin línea clara ni halo. Obsidiana y Marfil conservan sus cápsulas.
    private func bar(hasSpend: Bool, isSelected: Bool, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: proTheme?.barCornerRadius ?? 5, style: .continuous)
        return shape
            .fill(isSelected && hasSpend ? selectedColor.opacity(0.9) : palette.track)
            .frame(width: barWidth, height: height)
            .frame(maxWidth: .infinity)
    }

    /// Fino y fijo, no lo que sobre de la columna: con siete días la barra
    /// ocupaba casi todo su hueco y se veía como un bloque. Con menos
    /// columnas (las semanas del mes) hay aire para una algo más ancha.
    private var barWidth: CGFloat {
        columns.count > 6 ? 29 : 36
    }

    /// El color de la elegida: el del gasto, el acento del tema Pro, o con Pro
    /// en un tema básico, el acento de la app.
    private var selectedColor: Color {
        if let proTheme { return proTheme.accent }
        if ProTouches.isActive(isPro: isPro, theme: proTheme) { return AppThemeColor.current.color }
        return palette.expense
    }

    /// Nunca cero del todo: un periodo sin gasto se ve como una raya, no como
    /// un hueco que parezca un error de dibujo.
    private func height(_ value: Double) -> CGFloat {
        guard maximum > 0 else { return 4 }
        return max(4, Self.barArea * CGFloat(value / maximum))
    }
}

/// Recorta por abajo y por los lados, pero deja libre hacia arriba: el
/// rebote de la entrada y el borde de la barra elegida no se cortan.
private struct OpenTopClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX - 4, y: rect.minY - 40, width: rect.width + 8, height: rect.height + 42))
    }
}

/// «Semana · Mes»: el conmutador chico, sobre el fondo, del gráfico.
struct CompactSegment<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let label: (Item) -> String

    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    private var palette: Palette { Palette(scheme).themed(proTheme) }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let isOn = selection == item
                Button {
                    guard !isOn else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { selection = item }
                } label: {
                    Text(label(item))
                        .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? palette.label : palette.secondaryLabel)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background {
                            if isOn { Capsule().fill(palette.selectedFill) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(3)
        .background(proTheme.map { $0.base.opacity(0.6) } ?? palette.background, in: Capsule())
        .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
    }
}
