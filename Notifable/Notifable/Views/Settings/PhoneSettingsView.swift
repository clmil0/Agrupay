import SwiftUI

/// Configuración › Celular (`4c`): el número verificado por WhatsApp.
///
/// Verificar, esperar el mensaje y cambiar de número siguen pasando por la
/// misma hoja de Social (`PhoneVerificationSheet`); aquí se ve el estado y
/// se quita el número.
struct PhoneSettingsView: View {

    @Environment(\.colorScheme) private var scheme
    @State private var verification = PhoneVerification.shared
    @State private var showsSheet = false
    @State private var confirmForget = false

    private var palette: Palette { Palette(scheme) }

    var body: some View {
        SettingsPage(title: "Celular") {
            if let phone = verification.formattedPhone {
                SettingsHeroCard(icon: "checkmark.seal.fill", tint: palette.positive,
                                 title: phone, subtitle: verifiedCaption)

                SettingsGroup(footer: "Tus amigos no ven tu número. Sólo se usa para reconocer los pagos que te hacen.") {
                    SettingsAction(title: "Cambiar número") {
                        Task { await verification.start() }
                        showsSheet = true
                    }
                    SettingsDivider(inset: 14)
                    SettingsAction(title: "Quitar número", destructive: true) { confirmForget = true }
                }
            } else {
                SettingsHeroCard(icon: "phone.badge.checkmark", tint: AppThemeColor.current.color,
                                 title: verification.pending == nil ? "Sin verificar" : "Esperando tu WhatsApp",
                                 subtitle: "Verifícalo mandando un WhatsApp: así AgruPay reconoce los pagos que te hacen tus amigos.")

                SettingsGroup {
                    SettingsAction(title: verification.pending == nil ? "Verificar por WhatsApp" : "Ver el código") {
                        showsSheet = true
                    }
                }
            }
        }
        .task { await verification.refresh() }
        .sheet(isPresented: $showsSheet) { PhoneVerificationSheet() }
        .alert("¿Quitar tu número?", isPresented: $confirmForget) {
            Button("Cancelar", role: .cancel) {}
            Button("Quitar", role: .destructive) { Task { await verification.forget() } }
        } message: {
            Text("Se borra del servidor. Puedes volver a verificarlo cuando quieras.")
        }
    }

    /// «Verificado por WhatsApp el 14 sep».
    private var verifiedCaption: String {
        guard let date = verification.verifiedAt else { return "Verificado por WhatsApp" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_PE")
        f.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "d MMM" : "d MMM yyyy"
        return "Verificado por WhatsApp el " + f.string(from: date).replacingOccurrences(of: ".", with: "")
    }
}

/// Configuración › Dispositivos (`4d`). Gratis: sólo este iPhone, con la
/// invitación a Pro para usarlo en iPad y laptop.
struct DevicesSettingsView: View {

    @Environment(\.colorScheme) private var scheme
    @AppStorage(ProStore.enabledKey) private var isPro = false
    @State private var paywall: ProStore.Feature?

    private var palette: Palette { Palette(scheme) }

    var body: some View {
        SettingsPage(title: "Dispositivos") {
            SettingsGroup(title: "Conectados") {
                SettingsItem(icon: "iphone", tint: Color(hex: 0x5E5CE6),
                             title: UIDevice.current.name, subtitle: "Este dispositivo · ahora") {
                    EmptyView()
                }
            }

            if !isPro {
                ProUpsellCard(title: "Úsalo también en iPad y laptop",
                              subtitle: "Tus datos y ajustes al día en todos lados") { paywall = .sync }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("OTROS DISPOSITIVOS")
                    .font(.caption)
                    .tracking(0.3)
                    .foregroundStyle(palette.secondaryLabel)
                    .padding(.horizontal, 20)
                VStack(spacing: 10) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 22))
                        .foregroundStyle(palette.tertiaryLabel)
                    Text(isPro
                         ? "Aquí aparecerán tu iPad o tu Mac cuando inicies sesión en ellos con tu cuenta."
                         : "Aquí aparecerán tu iPad o tu Mac cuando inicies sesión en ellos.")
                        .font(.subheadline)
                        .foregroundStyle(palette.secondaryLabel)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
                .padding(.horizontal, 20)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
                .padding(.horizontal, 16)
            }
        }
        .proPaywall($paywall)
    }
}
