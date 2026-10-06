import SwiftUI

/// El gráfico del dashboard (`2d` de «Resumen Gráficas»): una barra por
/// periodo, lisa. Sólo la elegida lleva color; las demás van en el gris del
/// carril, para que el ojo vaya directo a la que tiene el monto encima. Al
/// entrar cada barra se llena con un rebote corto. Las burbujas de la barra
/// elegida se quitaron: eran lo que trababa el scroll.
///
/// «Días» son los últimos siete días, uno por barra, terminando hoy.
/// «Semanas», las del mes mostrado; «Meses», los últimos seis.
///
/// Con ingresos en los periodos (`3b` de «Resumen Gráficas Ingresos») el
/// gráfico se parte en espejo: el ingreso sube desde el eje y el gasto baja,
/// y lo del periodo elegido se lee en una línea encima («Vie 18 +S/ 45
/// −S/ 86»). Sin ingresos queda el de siempre, con el monto sobre la barra.
///
/// Tocar una barra la elige. Por defecto, la última con movimiento.
struct SpendBarChart: View {

    enum Mode: String, CaseIterable, Hashable {
        case days = "Días"
        case weeks = "Semanas"
        case months = "Meses"

        /// La segunda línea del menú.
        var hint: String {
            switch self {
            case .days: return "Últimos 7 días"
            case .weeks: return "Semanas de este mes"
            case .months: return "Últimos 6 meses"
            }
        }
    }

    struct Column: Identifiable {
        let id: Int
        let label: String
        /// La línea de lectura y VoiceOver: «Vie 18», «21–27 set (esta semana)».
        let detail: String
        let total: Double
        var income: Double = 0
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
    /// Cada mitad del espejo; la línea de lectura va encima.
    private static let halfArea: CGFloat = 46
    private static let halfBar: CGFloat = 44
    private static let readoutRoom: CGFloat = 26
    private static let labelRoom: CGFloat = 22
    /// Aire entre el monto de la barra más alta y el título del gráfico: sin
    /// él, con la barra a la izquierda, el monto quedaba pegado al subtítulo.
    private static let topRoom: CGFloat = 30
    private static let stagger: TimeInterval = 0.07
    private static let sideInset: CGFloat = 14

    private var maximum: Double { columns.map(\.total).max() ?? 0 }
    private var incomeMaximum: Double { columns.map(\.income).max() ?? 0 }
    private var isMirrored: Bool { Money.cents(incomeMaximum) > 0 }

    /// Identifica el juego de periodos, no sus montos: un gasto nuevo no
    /// repite la entrada.
    private var periodsKey: String { columns.map(\.label).joined(separator: "|") + (isReady ? "" : "|…") }

    var body: some View {
        Group {
            if isMirrored {
                VStack(alignment: .leading, spacing: 8) {
                    readout
                    HStack(alignment: .bottom, spacing: 10) {
                        ForEach(columns) { mirroredColumn($0) }
                    }
                    .padding(.horizontal, Self.sideInset)
                }
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(columns) { column in
                        columnView(column)
                    }
                }
                // Un poco más angosto que la tarjeta: las barras no llegan a los bordes.
                .padding(.horizontal, Self.sideInset)
            }
        }
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
                        .foregroundStyle(amountColor)
                        .fixedSize()
                        .offset(y: -Self.labelRoom + max(0, Self.barArea - barHeight) - 4)
                        .transition(.opacity)
                }
            }

            label(column.label, isSelected: isSelected)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) { selected = column.id }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(column.detail)
        .accessibilityValue(Money.format(column.total).masked(hidesAmounts))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Espejo

    /// «Vie 18  +S/ 45  −S/ 86» del periodo elegido.
    private var readout: some View {
        let column = columns.first { $0.id == selected }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let column {
                Text(column.detail)
                    .foregroundStyle(palette.secondaryLabel)
                if Money.cents(column.income) > 0 {
                    Text(("+" + Money.formatCompact(column.income)).masked(hidesAmounts))
                        .fontWeight(.semibold)
                        .foregroundStyle(palette.income)
                        .amountVeil()
                }
                Text((Money.cents(column.total) > 0 ? "−" + Money.formatCompact(column.total)
                                                     : Money.formatCompact(0)).masked(hidesAmounts))
                    .fontWeight(.semibold)
                    .foregroundStyle(amountColor)
                    .amountVeil()
            }
        }
        .font(.system(size: 12.5))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(height: 18)
        .padding(.horizontal, Self.sideInset + 2)
        .animation(nil, value: selected)
    }

    private func mirroredColumn(_ column: Column) -> some View {
        let isSelected = selected == column.id
        let hasSpend = Money.cents(column.total) > 0
        let hasIncome = Money.cents(column.income) > 0
        let incomeHeight = hasIncome ? max(3, Self.halfBar * CGFloat(column.income / incomeMaximum)) : 0
        let spendHeight = hasSpend && maximum > 0 ? max(3, Self.halfBar * CGFloat(column.total / maximum)) : 3
        let index = columns.firstIndex { $0.id == column.id } ?? 0
        let entry: Animation? = filled ? .spring(duration: 0.55, bounce: 0.3).delay(Double(index) * Self.stagger) : nil
        let radius = proTheme?.barCornerRadius ?? 5

        return VStack(spacing: 0) {
            // El ingreso sube desde el eje.
            UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: 1.5,
                                   bottomTrailingRadius: 1.5, topTrailingRadius: radius, style: .continuous)
                .fill(isSelected ? palette.income : palette.income.opacity(0.3))
                .frame(width: barWidth, height: incomeHeight)
                .offset(y: filled ? 0 : incomeHeight + 2)
                .animation(entry, value: filled)
                .frame(maxWidth: .infinity)
                .frame(height: Self.halfArea, alignment: .bottom)
                .clipShape(OpenTopClip())

            Rectangle()
                .fill(palette.track)
                .frame(height: 1)
                .padding(.horizontal, -5)
                .padding(.vertical, 2)

            // El gasto baja.
            UnevenRoundedRectangle(topLeadingRadius: 1.5, bottomLeadingRadius: radius,
                                   bottomTrailingRadius: radius, topTrailingRadius: 1.5, style: .continuous)
                .fill(isSelected && hasSpend ? selectedColor.opacity(0.9) : palette.track)
                .frame(width: barWidth, height: spendHeight)
                .offset(y: filled ? 0 : -(spendHeight + 2))
                .animation(entry, value: filled)
                .frame(maxWidth: .infinity)
                .frame(height: Self.halfArea, alignment: .top)
                .clipShape(OpenBottomClip())

            label(column.label, isSelected: isSelected)
                .padding(.top, 7)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) { selected = column.id }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(column.detail)
        .accessibilityValue(accessibilityValue(column))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func accessibilityValue(_ column: Column) -> String {
        var value = "Gasto " + Money.format(column.total).masked(hidesAmounts)
        if Money.cents(column.income) > 0 {
            value += ", ingreso " + Money.format(column.income).masked(hidesAmounts)
        }
        return value
    }

    private func label(_ text: String, isSelected: Bool) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? palette.expenseText : palette.secondaryLabel)
            .lineLimit(1)
            .fixedSize()
    }

    /// El monto del gasto elegido, sobre la barra o en la línea de lectura.
    private var amountColor: Color {
        palette.duoText ?? (proTheme == nil ? palette.expense : palette.expenseText)
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

/// El espejo de `OpenTopClip`: el gasto del gráfico en espejo baja desde el
/// eje y rebota hacia abajo.
private struct OpenBottomClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX - 4, y: rect.minY - 2, width: rect.width + 8, height: rect.height + 42))
    }
}
