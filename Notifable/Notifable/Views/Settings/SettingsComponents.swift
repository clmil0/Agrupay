import SwiftUI

/// Una fila de ajuste con su valor a la derecha.
///
/// Ajustes de iOS pone el valor de cada fila a la derecha justamente para que no
/// haya que entrar a mirarlo. Aquí el valor **nunca** queda vacío: sin
/// presupuesto pone "Sin definir", sin reglas pone "Ninguna". Un valor ausente
/// también es información.
struct SettingsRow<Destination: View>: View {

    let title: String
    let icon: String
    let tint: Color
    var value: String = ""
    /// Segunda línea bajo el título («Sólo lectura del correo»).
    var subtitle: String? = nil
    /// Punto de color delante del valor (el acento actual, en Apariencia).
    var valueDot: Color?
    /// Sello verde delante del valor (el celular verificado).
    var valueSeal = false
    @ViewBuilder let destination: () -> Destination

    @Environment(\.colorScheme) private var scheme
    /// Sólo para redibujar al cambiar de tema: `Palette` tiñe la superficie.
    @AppStorage(AppThemeColor.storageKey) private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                SettingsRowIcon(systemName: icon, tint: tint)

                // El título manda sobre el valor: si no cabe todo, se acorta
                // el valor («1 activo · 1 atajo»), nunca el nombre de la fila.
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(palette.label)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(palette.secondaryLabel)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let valueDot {
                    Circle()
                        .fill(valueDot)
                        .frame(width: 13, height: 13)
                }

                if valueSeal {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.positive)
                }

                if !value.isEmpty {
                    Text(value)
                        .foregroundStyle(palette.secondaryLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.tertiaryLabel)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingsRowIcon: View {
    let systemName: String
    let tint: Color

    var body: some View {
        ZStack {
            // Relleno sólido y glifo blanco (`5a`): con el tinte al 22 % los
            // colores de sección apenas se distinguían en claro, y el color es
            // lo que permite encontrar una fila sin leerla.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint)
                .frame(width: 30, height: 30)
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
        }
    }
}

/// Contenedor de sección: título fuera, tarjeta con las filas dentro y el
/// separador sangrado a 56 pt para que quede alineado al texto, no al borde.
struct SettingsSection<Content: View>: View {

    let title: String
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var scheme
    /// Sólo para redibujar al cambiar de tema: `Palette` tiñe la superficie.
    @AppStorage(AppThemeColor.storageKey) private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption)
                .tracking(0.3)
                .foregroundStyle(palette.secondaryLabel)
                .padding(.horizontal, 20)

            VStack(spacing: 0) {
                content()
            }
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5)
            )
            .padding(.horizontal, 16)
        }
    }
}

struct SettingsSeparator: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(Palette(scheme).separator)
            .frame(height: 0.5)
            .padding(.leading, 56)
    }
}

/// La tarjeta de estado de la raíz.
///
/// Lo primero que un usuario quiere confirmar —si la lectura de correo funciona
/// y cuándo corrió— estaba dos niveles adentro, en una pantalla llamada "Bancos
/// y Sincronización Automática". Aquí está antes que nada.
struct SettingsStatusCard: View {

    let status: SettingsStatus
    let accent: Color
    var onConnect: () -> Void

    @Environment(\.colorScheme) private var scheme
    /// Sólo para redibujar al cambiar de tema: `Palette` tiñe la superficie.
    @AppStorage(AppThemeColor.storageKey) private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    private var palette: Palette { Palette(scheme) }

    private var dotColor: Color {
        switch status.level {
        case .ok: return palette.positive
        case .attention: return palette.warning
        case .disconnected: return palette.tertiaryLabel
        }
    }

    private var iconTint: Color {
        status.level == .disconnected ? palette.tertiaryLabel : palette.positive
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if status.isConnected {
                Rectangle().fill(palette.separator).frame(height: 0.5)
                columns

                if status.level == .attention {
                    Rectangle().fill(palette.separator).frame(height: 0.5)
                    attentionRow
                }
            } else {
                connectButton
            }
        }
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(iconTint.opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: "envelope.fill")
                    .foregroundStyle(iconTint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(status.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                Text(status.subhead)
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
        }
        .padding(16)
    }

    private var columns: some View {
        HStack(spacing: 0) {
            column(title: "Última lectura", value: status.lastSyncLabel)
            divider
            column(title: "Bancos", value: status.bankLabel)
            divider
            column(title: "Este mes", value: "\(status.expensesThisMonth) gastos")
        }
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Rectangle()
            .fill(palette.separator)
            .frame(width: 0.5, height: 30)
    }

    private func column(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    /// Con `attention` la tarjeta dice la causa, no sólo que algo va mal.
    private var attentionRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(palette.warning)
            Text(attentionCause)
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var attentionCause: String {
        if status.missingGmailScope {
            return "Google no dio permiso para leer el correo. Toca, vuelve a conectar y marca la casilla de Gmail."
        }
        if status.activeBankCount == 0 {
            return "Ningún banco activo: no entrará ningún gasto. Actívalos en Correo y bancos."
        }
        return "La última lectura fue hace más de dos días. Toca para leer ahora."
    }

    private var connectButton: some View {
        Button(action: onConnect) {
            Text("Conectar Gmail")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent.readableText)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(accent.readableFill)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding([.horizontal, .bottom], 16)
    }
}
