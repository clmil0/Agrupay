import SwiftUI

// Piezas de las pantallas internas de Configuración (`4a`–`4l`).
//
// Todas comparten la misma forma: título grande, grupos con su rótulo en
// mayúsculas fuera de la tarjeta, filas de 52 pt y una nota al pie cuando la
// opción necesita explicarse. Antes cada pantalla era un `Form` distinto o un
// `ScrollView` con sus propias tarjetas; ahora se leen como una sola app.

/// Página de ajustes: fondo de la app, título grande y los grupos apilados.
struct SettingsPage<Content: View>: View {

    let title: String
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var scheme
    /// Sólo para redibujar al cambiar de tema: `Palette` tiñe el fondo.
    @AppStorage(AppThemeColor.storageKey) private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    @Environment(\.proTheme) private var proTheme
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                content()
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .settingsScrollActivity()
        .background {
            if let proTheme {
                ProThemeBackdrop(theme: proTheme, calm: true)
            } else {
                palette.background
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }
}

/// Un grupo: rótulo opcional, la tarjeta con las filas y una nota opcional.
struct SettingsGroup<Content: View>: View {

    var title: String? = nil
    var footer: String? = nil
    /// Borde rojo tenue, para «Borrar datos» y compañía.
    var destructive = false
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var scheme
    @AppStorage(AppThemeColor.storageKey) private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.caption)
                    .tracking(0.3)
                    .foregroundStyle(palette.secondaryLabel)
                    .padding(.horizontal, 20)
            }

            VStack(spacing: 0) {
                content()
            }
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(destructive ? palette.negative.opacity(0.3) : palette.hairline,
                            lineWidth: destructive ? 0.75 : 0.5)
            )
            .padding(.horizontal, 16)

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }
        }
    }
}

/// Separador entre filas: sangrado al texto (56 pt con ícono, 16 sin él).
struct SettingsDivider: View {
    var inset: CGFloat = 56
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(Palette(scheme).separator)
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}

/// El cuerpo de una fila: ícono, título (con su «PRO» si aplica), subtítulo y
/// lo que vaya a la derecha.
struct SettingsItem<Trailing: View>: View {

    var icon: String? = nil
    var tint: Color = .blue
    let title: String
    var subtitle: String? = nil
    var pro = false
    var titleColor: Color? = nil
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                SettingsRowIcon(systemName: icon, tint: tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .foregroundStyle(titleColor ?? palette.label)
                        .lineLimit(1)
                    if pro { ProBadge() }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// Valor gris y galón: lo de la derecha en una fila que lleva a otra parte.
struct SettingsValueChevron: View {
    var value: String = ""
    var chevron = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        HStack(spacing: 8) {
            if !value.isEmpty {
                Text(value)
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.tertiaryLabel)
            }
        }
    }
}

/// Fila con interruptor.
struct SettingsToggle: View {
    var icon: String? = nil
    var tint: Color = .blue
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    private var accent: AppThemeColor { .current }

    var body: some View {
        SettingsItem(icon: icon, tint: tint, title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(accent.color)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Fila que abre otra pantalla.
struct SettingsLink<Destination: View>: View {
    var icon: String? = nil
    var tint: Color = .blue
    let title: String
    var subtitle: String? = nil
    var value: String = ""
    var pro = false
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            SettingsItem(icon: icon, tint: tint, title: title, subtitle: subtitle, pro: pro) {
                SettingsValueChevron(value: value)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Fila que hace algo al tocarla (abrir una hoja, el paywall…).
struct SettingsButton: View {
    var icon: String? = nil
    var tint: Color = .blue
    let title: String
    var subtitle: String? = nil
    var value: String = ""
    var pro = false
    var chevron = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsItem(icon: icon, tint: tint, title: title, subtitle: subtitle, pro: pro) {
                SettingsValueChevron(value: value, chevron: chevron)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Una acción de texto a secas: «Leer ahora» en azul, «Quitar número» en rojo.
struct SettingsAction: View {
    let title: String
    var destructive = false
    var busy = false
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(destructive ? palette.negative : AppThemeColor.current.onSurface(scheme))
                Spacer()
                if busy { ProgressView() }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

/// Opción de una lista de elección única, con su marca a la derecha.
struct SettingsChoice: View {
    let title: String
    var subtitle: String? = nil
    var pro = false
    let selected: Bool
    /// Galón en vez de marca: la opción abre algo más (un rango, el paywall).
    var opensMore = false
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            SettingsItem(title: title, subtitle: subtitle, pro: pro) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppThemeColor.current.onSurface(scheme))
                } else if opensMore {
                    SettingsValueChevron()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// La tarjeta de cabecera de algunas pantallas (Celular, Bloqueo): un ícono
/// en círculo, una línea fuerte y una explicación.
struct SettingsHeroCard: View {
    let icon: String
    var tint: Color = .green
    let title: String
    var subtitle: String? = nil

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 56, height: 56)
                .background(tint.opacity(0.16), in: Circle())
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(palette.label)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
        .padding(.horizontal, 16)
    }
}

/// El aviso punteado «Úsalo también en iPad y laptop · Ver Pro».
struct ProUpsellCard: View {
    let title: String
    let subtitle: String
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    private static let gold = Color(red: 0.965, green: 0.776, blue: 0.294)

    var body: some View {
        let palette = Palette(scheme)
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Self.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.label)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text("Ver Pro")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Self.gold)
            }
            .padding(14)
            .background(Self.gold.opacity(scheme == .dark ? 0.07 : 0.10),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Self.gold.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}
