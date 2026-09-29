import SwiftUI

/// Bloqueo (`4k`): Face ID y la privacidad de los montos.
///
/// El interruptor del bloqueo no escribe la preferencia directamente: pide
/// autenticarse y sólo entonces la guarda, tanto para encender como para
/// apagar. Por eso no es un `@AppStorage` atado al `Toggle`, sino un
/// `Binding` con acción.
struct AppLockSettingsView: View {

    @StateObject private var lock = AppLock.shared
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    @AppStorage(AmountPrivacy.hideOnLaunchKey) private var hideOnLaunch = false
    /// Sólo para redibujar: los valores reales (con su regla por defecto) los
    /// leen `WidgetSnapshotBuilder` y `PrivacyShield`.
    @AppStorage(WidgetSnapshotBuilder.showAmountsKey) private var widgetKeyMirror = false
    @AppStorage(PrivacyShield.coverKey) private var coverKeyMirror = false

    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        SettingsPage(title: "Bloqueo") {
            if AppLock.canLock {
                SettingsHeroCard(icon: AppLock.biometryIcon, tint: Color(white: 0.75),
                                 title: lock.isEnabled ? "AgruPay se abre con \(AppLock.biometryName)"
                                                       : "Protege AgruPay con \(AppLock.biometryName)",
                                 subtitle: lock.isEnabled
                                    ? "Si no te reconoce, puedes usar el código del iPhone."
                                    : "Tus movimientos, deudas y sueldo quedan detrás de \(AppLock.biometryName).")

                SettingsGroup(footer: error) {
                    SettingsItem(title: "Bloquear con \(AppLock.biometryName)") {
                        Toggle("", isOn: toggleBinding)
                            .labelsHidden()
                            .tint(AppThemeColor.current.color)
                            .disabled(isWorking)
                    }
                    if lock.isEnabled {
                        SettingsDivider(inset: 14)
                        Menu {
                            Picker("Pedir al volver", selection: graceBinding) {
                                ForEach(AppLock.Grace.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                        } label: {
                            SettingsItem(title: "Pedir al volver") {
                                SettingsValueChevron(value: lock.grace.label)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                SettingsHeroCard(icon: "lock.slash", tint: Color(white: 0.6),
                                 title: "Sin código en este iPhone",
                                 subtitle: "Para bloquear AgruPay hace falta un código de desbloqueo. Se configura en Ajustes de iOS → Face ID y código.")
            }

            SettingsGroup(title: "Privacidad") {
                SettingsToggle(title: "Ocultar montos al abrir", subtitle: "Empieza con el ojito cerrado",
                               isOn: $hideOnLaunch)
                SettingsDivider(inset: 14)
                SettingsToggle(title: "Montos en los widgets", subtitle: "Se ven en la pantalla de inicio",
                               isOn: widgetBinding)
                SettingsDivider(inset: 14)
                SettingsToggle(title: "Tapar al cambiar de app",
                               subtitle: "El selector de apps no enseña tus cifras",
                               isOn: coverBinding)
            }
        }
    }

    /// Encender y apagar pasan por `AppLock`, que exige autenticarse antes de
    /// tocar la preferencia. El `Toggle` sólo dispara la intención.
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { lock.isEnabled },
            set: { wanted in
                guard wanted != lock.isEnabled, !isWorking else { return }
                Task {
                    isWorking = true
                    error = wanted ? await lock.enable() : await lock.disable()
                    isWorking = false
                }
            }
        )
    }

    private var graceBinding: Binding<AppLock.Grace> {
        Binding(get: { lock.grace }, set: { lock.setGrace($0) })
    }

    private var widgetBinding: Binding<Bool> {
        Binding(
            get: { _ = widgetKeyMirror; _ = lock.isEnabled; return WidgetSnapshotBuilder.showsAmounts() },
            set: { widgetKeyMirror = $0 }
        )
    }

    private var coverBinding: Binding<Bool> {
        Binding(
            get: { _ = coverKeyMirror; _ = lock.isEnabled; return PrivacyShield.coversOnSwitch },
            set: { coverKeyMirror = $0 }
        )
    }
}
