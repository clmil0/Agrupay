import SwiftUI

/// Encabezado de sección en versalitas. El de «POR CONFIRMAR», «TU CÓDIGO»,
/// «COMPROMETIDO CADA MES»: dice de qué va el bloque sin competir con los
/// montos, que son lo que la pantalla quiere que leas.
struct ShellSectionHeader: View {
    let title: String
    var trailing: String?
    /// Color de `trailing` cuando dice algo que acaba de pasar («ahora»).
    var trailingTint: Color?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    private var palette: Palette { Palette(scheme).themed(proTheme) }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 11.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(palette.secondaryLabel)

            Spacer()

            if let trailing {
                Text(trailing)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(trailingTint ?? palette.secondaryLabel)
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 8)
    }
}

/// La tarjeta del rediseño: superficie opaca, radio 20 y hairline de 0.5.
struct ShellCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    private var palette: Palette { Palette(scheme).themed(proTheme) }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5)
            )
    }
}

/// Una cifra con su etiqueta. Las dos de Balance (Ingresos / Gastos) y las dos
/// de ritmo (Promedio diario / Disponible al día).
struct StatTile: View {
    let label: String
    let value: String
    var tint: Color?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    private var palette: Palette { Palette(scheme).themed(proTheme) }

    var body: some View {
        ShellCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
                Text(value)
                    .font(.system(size: 20, weight: proTheme?.numberWeight ?? .bold,
                                  design: proTheme?.numberDesign ?? .default))
                    .foregroundStyle(tint ?? palette.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
    }
}

/// Barra de progreso con **marca de ritmo**: la línea vertical que dice dónde
/// deberías ir a estas alturas del periodo.
///
/// Es la pieza que convierte «S/ 2,612 de 4,200» en un juicio. Sin la marca,
/// el 62 % no significa nada: puede ser ir bien el día 28 o fatal el día 3.
struct PaceBar: View {
    /// 0…1 de lo gastado.
    let fraction: Double
    /// 0…1 del periodo transcurrido. `nil` la esconde.
    var expected: Double?
    var status: Pace.Status = .ok
    var height: CGFloat = 8

    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    private var palette: Palette { Palette(scheme).themed(proTheme) }

    private var fill: Color {
        switch status {
        case .ok:      return AppThemeColor.current.color
        case .warning: return palette.warning
        case .over:    return palette.negative
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track)

                Capsule()
                    .fill(fill)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)

                if let expected {
                    // Contraste invertido: la marca tiene que leerse **sobre**
                    // el relleno de color y sobre la pista gris a la vez.
                    Rectangle()
                        .fill(palette.label)
                        .frame(width: 2, height: height + 4)
                        .offset(x: max(0, min(1, expected)) * geo.size.width - 1)
                }
            }
        }
        .frame(height: height + 4)
    }
}

/// Segmento de píldoras: «Gastos / Ingresos», «Este mes / Todo el historial»,
/// «Día · Semana · Mes · Año».
///
/// La opción elegida va en el gris de selección (`1b`); `tint` la pinta de un
/// color cuando el color dice algo —el naranja del gasto en Análisis—.
struct ShellSegment<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    var tint: Color?
    let label: (Item) -> String

    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    private var palette: Palette { Palette(scheme).themed(proTheme) }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                Button {
                    guard selection != item else { return }
                    withAnimation(.easeInOut(duration: 0.22)) { selection = item }
                } label: {
                    Text(label(item))
                        .font(.system(size: 13, weight: selection == item ? .semibold : .regular))
                        .foregroundStyle(selection == item ? selectedText : palette.secondaryLabel)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background {
                            if selection == item {
                                Capsule().fill(tint?.readableFill ?? palette.selectedFill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(palette.surface, in: Capsule())
        .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
    }

    /// Sobre el gris, el texto. Sobre un acento, blanco o tinta oscura según
    /// el contraste WCAG (`Color.readableText`).
    private var selectedText: Color {
        guard let tint else { return palette.label }
        return tint.readableText
    }
}

/// El titular de una sub-vista cuando no hay un monto grande que haga de
/// título: «Pendientes», «Presupuestos», «Amigos». Alineado a la izquierda y
/// con su línea de contexto debajo.
struct ShellTitle: View {
    let title: String
    var subtitle: String?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    private var palette: Palette { Palette(scheme).themed(proTheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 32, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(palette.label)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(palette.secondaryLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.top, 2)
        .padding(.bottom, 14)
    }
}

/// Estado vacío: un ícono tenue, una frase que dice qué pasa y otra que dice
/// qué hacer. Nunca sólo «Sin datos».
struct ShellEmptyState: View {
    let icon: String
    let title: String
    let message: String

    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    private var palette: Palette { Palette(scheme).themed(proTheme) }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(palette.tertiaryLabel)

            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.label)

            Text(message)
                .font(.system(size: 13.5))
                .foregroundStyle(palette.secondaryLabel)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .padding(.horizontal, 24)
    }
}

/// Una línea con ícono a la izquierda: los mensajes de ritmo («Vas al 62 %…»,
/// «Pasaste el límite por S/ 68»).
struct ShellNote: View {
    let icon: String
    let text: String
    var tint: Color?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    private var palette: Palette { Palette(scheme).themed(proTheme) }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint ?? palette.secondaryLabel)
    }
}
