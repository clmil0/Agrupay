import SwiftUI

/// El modal de AgruPay Pro (`2a` → «Pro»).
///
/// Se abre desde la pastilla del perfil (todas las funciones por igual) o
/// desde una opción con «PRO» dentro de una pantalla: entonces esa función va
/// resaltada con «LO BUSCABAS» y la frase de arriba habla de ella.
struct ProPaywallSheet: View {

    let feature: ProStore.Feature?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var plan: ProStore.Plan = .anual
    @State private var social = SocialProfileStore.shared
    @State private var showsRestoreNote = false

    private var palette: Palette { Palette(scheme) }
    private static let blue = Color(hex: 0x0A84FF)
    private static let violet = Color(hex: 0xBF5AF2)

    var body: some View {
        trackedBody.trackScreen("paywall")
            .onAppear {
                shownAt = Date()
                Analytics.track(.paywallShown, ["feature": feature?.rawValue ?? "general"])
            }
            .onDisappear {
                guard !startedTrial else { return }
                Analytics.track(.paywallDismissed, ["feature": feature?.rawValue ?? "general",
                                                    "plan": plan.rawValue,
                                                    "seconds": Int(Date().timeIntervalSince(shownAt))])
            }
    }

    @State private var shownAt = Date()
    @State private var startedTrial = false

    /// El `body` de siempre; `body` lo envuelve para contarlo como pantalla.
    @ViewBuilder private var trackedBody: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    featureList
                    Label("Gratis sigues teniendo 3 meses de historial, respaldo local y todos los temas de uno y dos colores.",
                          systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                    plans
                }
                .padding(.horizontal, 16)
                .padding(.top, 34)
                .padding(.bottom, 130)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom) { cta }

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.secondaryLabel)
                    .frame(width: 30, height: 30)
                    .background(palette.neutralSurface, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
            .accessibilityLabel("Cerrar")
        }
        .background(background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .alert("Nada que restaurar", isPresented: $showsRestoreNote) {
            Button("Entendido", role: .cancel) {}
        } message: {
            Text("No encontramos compras de AgruPay Pro con tu cuenta de Apple.")
        }
    }

    /// Un resplandor azul y violeta arriba, sobre el fondo de la app.
    private var background: some View {
        ZStack {
            palette.background
            RadialGradient(colors: [Self.blue.opacity(scheme == .dark ? 0.28 : 0.16), .clear],
                           center: UnitPoint(x: 0.15, y: 0.0), startRadius: 0, endRadius: 360)
            RadialGradient(colors: [Self.violet.opacity(scheme == .dark ? 0.24 : 0.14), .clear],
                           center: UnitPoint(x: 0.9, y: 0.05), startRadius: 0, endRadius: 320)
        }
    }

    // MARK: - Cabecera

    private var header: some View {
        VStack(spacing: 8) {
            PenguinAvatar(look: social.penguin, size: 78, background: palette.surface)
                .padding(5)
                .overlay(
                    Circle().strokeBorder(
                        AngularGradient(colors: [Color(hex: 0xFFD60A), Color(hex: 0xFF6B9A), Self.violet,
                                                 Self.blue, Color(hex: 0x30D158), Color(hex: 0xFFD60A)],
                                        center: .center),
                        lineWidth: 3.5)
                )

            (Text("AgruPay ").foregroundStyle(palette.label)
             + Text("Pro").foregroundStyle(LinearGradient(colors: [Color(hex: 0xC4B5FD), Self.violet],
                                                           startPoint: .leading, endPoint: .trailing)))
                .font(.system(size: 26, weight: .heavy))
                .padding(.top, 4)

            Text(feature?.lead ?? "Todo lo que ya usas, sin límites.")
                .font(.system(size: 14))
                .foregroundStyle(palette.secondaryLabel)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Funciones

    private var featureList: some View {
        VStack(spacing: 0) {
            ForEach(Array(ProStore.Feature.allCases.enumerated()), id: \.element) { index, item in
                featureRow(item)
                if index < ProStore.Feature.allCases.count - 1 { SettingsDivider(inset: 58) }
            }
        }
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
    }

    private func featureRow(_ item: ProStore.Feature) -> some View {
        let active = item == feature
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(item.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(palette.label)
                    if active {
                        Text("LO BUSCABAS")
                            .font(.system(size: 9, weight: .heavy))
                            .tracking(0.5)
                            .foregroundStyle(Self.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Self.blue.opacity(0.16), in: Capsule())
                    }
                }
                Text(item.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                if item == .themes {
                    // Una fila de noche y otra de día.
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach([ProTheme.night, ProTheme.day], id: \.self) { row in
                            HStack(spacing: 8) {
                                ForEach(row) { theme in
                                    VStack(spacing: 3) {
                                        ProThemeSwatch(theme: theme, size: 28, sparkle: false)
                                        Text(theme.rawValue)
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(palette.tertiaryLabel)
                                            .lineLimit(1)
                                            .fixedSize()
                                    }
                                    .frame(minWidth: 34)
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(palette.positive)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(active ? Self.blue.opacity(0.08) : .clear)
        .overlay(alignment: .leading) {
            if active { Rectangle().fill(Self.blue).frame(width: 3) }
        }
    }

    // MARK: - Planes

    private var plans: some View {
        HStack(spacing: 10) {
            planCard(.anual, price: "S/ 99.90", detail: "S/ 8.33 al mes", badge: "AHORRA 35%")
            planCard(.mensual, price: "S/ 12.90", detail: "Cancela cuando quieras", badge: nil)
        }
    }

    private func planCard(_ value: ProStore.Plan, price: String, detail: String, badge: String?) -> some View {
        let selected = plan == value
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { plan = value }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(value.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.secondaryLabel)
                Text(price)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(palette.label)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.secondaryLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(selected ? Self.blue : palette.hairline, lineWidth: selected ? 2 : 0.5))
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.4)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(palette.positive, in: Capsule())
                        .offset(x: -10, y: -8)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Botón

    private var cta: some View {
        VStack(spacing: 10) {
            Button {
                startedTrial = true
                Analytics.track(.proTrialStarted, ["feature": feature?.rawValue ?? "general",
                                                   "plan": plan.rawValue,
                                                   "seconds": Int(Date().timeIntervalSince(shownAt))])
                ProStore.startTrial(plan: plan)
                dismiss()
            } label: {
                Text("Probar 7 días gratis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(LinearGradient(colors: [Self.blue, Self.violet],
                                               startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: Self.violet.opacity(0.35), radius: 14, y: 6)
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Text(plan.afterTrial)
                Text("·")
                Button("Restaurar compras") { showsRestoreNote = true }
                    .buttonStyle(.plain)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(palette.secondaryLabel)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [palette.background.opacity(0), palette.background],
                           startPoint: .top, endPoint: .init(x: 0.5, y: 0.35))
        )
    }
}
