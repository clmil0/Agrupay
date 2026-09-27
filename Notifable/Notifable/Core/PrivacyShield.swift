import SwiftUI
import UIKit
import UserNotifications

/// Ventana de UIKit aparte, sólo para blindar la app en el instante exacto de
/// perder el primer plano.
///
/// Por qué no basta con lo que ya cubre esto en `ContentView` (la capa
/// siempre montada + `LockScreenView`): esas viven dentro de la jerarquía de
/// SwiftUI de la app, y cualquier cambio ahí pasa por el reconciliador antes
/// de dibujarse — un fotograma de más que alcanza cuando minimizas del todo,
/// pero no cuando mantienes presionado el gesto de subir para entrar directo
/// al selector de apps: ahí iOS congela lo que hay en pantalla en el instante
/// en que el dedo empieza a moverse, no cuando la app termina de reaccionar.
///
/// Una `UIWindow` nueva, ajena del todo a esa jerarquía, no tiene ese trabajo
/// pendiente: se monta y se pinta por su cuenta, en el mismo callback
/// (`applicationWillResignActive`) que UIKit expone justamente para esto.
@MainActor
enum PrivacyShield {

    private static var window: UIWindow?

    static func show() {
        guard AppLock.shared.isEnabled, window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState != .background })
        else { return }

        let accent = AppThemeColor(rawValue: UserDefaults.standard.string(forKey: "appAccentColor") ?? "")?.color
            ?? AppBrand.accent
        let dark = isDark()

        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.isUserInteractionEnabled = false
        w.overrideUserInterfaceStyle = dark ? .dark : .light
        w.backgroundColor = dark ? .black : .white
        w.rootViewController = UIHostingController(rootView: ShieldContent(accent: accent, dark: dark))
        w.rootViewController?.view.backgroundColor = .clear
        w.isHidden = false
        w.layoutIfNeeded()
        window = w
    }

    static func hide() {
        window?.isHidden = true
        window = nil
    }

    static func isDark() -> Bool {
        let raw = UserDefaults.standard.string(forKey: AppAppearance.storageKey)
        switch AppAppearance(rawValue: raw ?? "") ?? .dark {
        case .dark: return true
        case .light: return false
        case .system: return UIScreen.main.traitCollection.userInterfaceStyle == .dark
        }
    }
}

private struct ShieldContent: View {
    let accent: Color
    let dark: Bool

    var body: some View {
        ZStack {
            (dark ? Color.black : Color.white).ignoresSafeArea()
            AppIconTile(size: 64, accent: accent, coinFace: .white, detail: false)
        }
    }
}

/// Puente a `UIApplicationDelegate` sólo para `PrivacyShield`: es el único
/// punto que UIKit garantiza que corre **antes** de que el sistema capture la
/// pantalla para el selector de apps, algo que `scenePhase` de SwiftUI no
/// puede prometer.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Lo más temprano posible: un cuelgue en el arranque también debe quedar.
        Diagnostics.shared.start()
        // Antes de que termine el arranque, como pide `UNUserNotificationCenter`,
        // para que los avisos también se vean con la app abierta.
        UNUserNotificationCenter.current().delegate = NotificationManager.shared
        // Con el permiso ya dado, el token se pide en cada arranque: iOS puede
        // cambiarlo (restaurar el teléfono, reinstalar) sin avisar.
        PaymentReminders.registerForPushIfAllowed()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await PaymentReminders.shared.store(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Diagnostics.shared.log("Push: no se pudo registrar (\(error.localizedDescription))")
    }

    // Los cierres por watchdog que ha tenido la app son de "scene-update": iOS
    // pide un cambio de escena y la app no contesta. Marcar la entrada y la
    // salida de estos callbacks dice si el atasco empieza aquí.
    func applicationWillResignActive(_ application: UIApplication) {
        Diagnostics.shared.log("willResignActive: inicio")
        PrivacyShield.show()
        Diagnostics.shared.log("willResignActive: fin")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Diagnostics.shared.log("didBecomeActive: inicio")
        PrivacyShield.hide()
        Diagnostics.shared.log("didBecomeActive: fin")
    }
}
