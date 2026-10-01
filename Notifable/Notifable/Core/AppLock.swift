import Foundation
import LocalAuthentication
import SwiftUI
import UIKit

/// Bloqueo de la app con Face ID / Touch ID.
///
/// Lo que protege: la app enseña sueldo, deudas, comercios y en qué se va el
/// dinero. Con el teléfono desbloqueado en la mano de otro, todo eso está a un
/// toque. El bloqueo no cifra nada —los datos siguen protegidos por el cifrado
/// del propio iPhone—; lo que hace es poner una puerta delante de la pantalla.
///
/// Dos decisiones que importan:
/// - Se evalúa `.deviceOwnerAuthentication`, no
///   `.deviceOwnerAuthenticationWithBiometrics`: si Face ID falla (mascarilla,
///   gafas de sol, tres intentos) iOS ofrece el código del teléfono. Con la
///   variante sólo-biométrica el usuario se quedaría fuera de sus propios datos
///   sin salida, y la única forma de recuperarlos sería reinstalar.
/// - Activarlo exige autenticarse **antes**: así nadie deja el bloqueo puesto
///   en un teléfono cuyo Face ID no reconoce a su dueño.
@MainActor
final class AppLock: ObservableObject {

    static let shared = AppLock()

    static let enabledKey = "appLockEnabled"
    static let graceKey = "appLockGraceSeconds"

    /// Cuánto puede estar la app en segundo plano sin volver a pedir la cara.
    /// Sin margen, cada vez que se sale a copiar un dato del banco y se vuelve
    /// hay que autenticarse otra vez, y el ajuste acaba desactivado.
    enum Grace: Int, CaseIterable, Identifiable {
        case immediately = 0
        case oneMinute = 60
        case fiveMinutes = 300

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .immediately: return "Enseguida"
            case .oneMinute: return "Tras 1 minuto"
            case .fiveMinutes: return "Tras 5 minutos"
            }
        }
    }

    /// `true` mientras la pantalla de bloqueo debe tapar la app.
    @Published private(set) var isLocked: Bool
    /// Motivo del último intento fallido, con sus pasos y sus botones. No es
    /// un texto: la pantalla necesita saber **qué** falló para ofrecer la
    /// salida que corresponde (ver `AppLockFailure`).
    @Published private(set) var lastFailure: AppLockFailure?

    /// Texto llano del último fallo, para los sitios que sólo quieren mostrarlo
    /// (los ajustes, por ejemplo).
    var lastError: String? { lastFailure?.headline }

    /// El propio diálogo de Face ID manda la escena a `.inactive`. Sin esta
    /// marca, salir de él volvería a bloquear la app y el desbloqueo no
    /// terminaría nunca.
    private var isAuthenticating = false
    private var leftForegroundAt: Date?
    /// El diálogo de Face ID en curso, para poder retirarlo si llega un
    /// registro rápido desde el widget.
    private var currentContext: LAContext?

    /// Registro rápido desde el widget con la app bloqueada: el formulario se
    /// abre sin pedir la cara (anotar un gasto no enseña nada) y la puerta se
    /// aplaza hasta que el formulario baja. Mientras tanto la app sigue
    /// bloqueada: detrás del formulario sólo está el blindaje.
    @Published private(set) var defersForQuickEntry = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Si el ajuste está puesto, la app arranca bloqueada. Nunca al revés:
        // desbloquear es siempre una acción explícita.
        self.isLocked = defaults.bool(forKey: Self.enabledKey)
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    var grace: Grace {
        Grace(rawValue: defaults.integer(forKey: Self.graceKey)) ?? .immediately
    }

    // MARK: - Disponibilidad

    /// `nonisolated` las cuatro: sólo preguntan a un `LAContext` recién creado
    /// y no tocan estado de la clase, así que exigir el actor principal para
    /// leer el nombre de la biometría sería una atadura sin motivo — y las usan
    /// tipos que no están aislados, como `AppLockFailure`.
    ///
    /// Qué biometría tiene este teléfono. `.none` si no hay ninguna disponible
    /// —sin sensor, sin códigos registrados o con Face ID denegado a la app—.
    nonisolated static var biometry: LABiometryType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                        error: &error) else { return .none }
        return context.biometryType
    }

    /// `false` en un teléfono sin código: ahí no hay nada con qué desbloquear,
    /// así que el ajuste ni se ofrece.
    nonisolated static var canLock: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// "Face ID", "Touch ID"… El nombre real, no uno inventado: el usuario tiene
    /// que reconocer en el ajuste lo mismo que le pedirá el sistema.
    nonisolated static var biometryName: String {
        switch biometry {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "el código del iPhone"
        }
    }

    nonisolated static var biometryIcon: String {
        switch biometry {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.fill"
        }
    }

    // MARK: - Activar y desactivar

    /// Enciende el bloqueo, pero sólo si el usuario se autentica primero.
    /// Devuelve `nil` si quedó activado, o el motivo si no.
    func enable() async -> String? {
        if let error = await authenticate(reason: "Confirma que eres tú para activar el bloqueo.") {
            return error
        }
        defaults.set(true, forKey: Self.enabledKey)
        isLocked = false
        objectWillChange.send()
        return nil
    }

    /// Apagarlo también se autentica: si no, a quien tenga el teléfono en la
    /// mano le bastaría con entrar a Ajustes para quitar la puerta.
    func disable() async -> String? {
        if let error = await authenticate(reason: "Confirma que eres tú para quitar el bloqueo.") {
            return error
        }
        defaults.set(false, forKey: Self.enabledKey)
        isLocked = false
        objectWillChange.send()
        return nil
    }

    func setGrace(_ value: Grace) {
        defaults.set(value.rawValue, forKey: Self.graceKey)
        objectWillChange.send()
    }

    // MARK: - Bloquear y desbloquear

    /// El intento de desbloqueo de la pantalla de bloqueo.
    /// El intento de desbloqueo de la pantalla de bloqueo.
    ///
    /// `preferPasscode` es para el botón "Usar código del iPhone": cuando la
    /// biometría está bloqueada o sin configurar, iOS va directo al teclado del
    /// código, que es justo la salida que el usuario acaba de pedir.
    func unlock(preferPasscode: Bool = false) async {
        guard isLocked, !defersForQuickEntry else { return }
        let failure = await attempt(reason: "Desbloquea AgruPay para ver tus movimientos.",
                                    preferPasscode: preferPasscode)
        // Retirado por un registro rápido: no es un fallo que enseñar.
        guard !defersForQuickEntry else { return }
        lastFailure = failure
        if lastFailure == nil {
            isLocked = false
            leftForegroundAt = nil
        }
    }

    /// Abre el paréntesis del registro rápido. Si el diálogo de Face ID ya
    /// estaba en pantalla (la app volvía bloqueada), se retira: el usuario
    /// tocó el widget para anotar, no para entrar.
    func beginQuickEntry() {
        guard isLocked else { return }
        defersForQuickEntry = true
        currentContext?.invalidate()
    }

    /// El formulario bajó: vuelve la puerta y, con ella, Face ID.
    func endQuickEntry() {
        guard defersForQuickEntry else { return }
        lastFailure = nil
        defersForQuickEntry = false
    }

    /// Quitar el bloqueo **sin** autenticarse. Sólo cuando el iPhone no tiene
    /// código: en ese estado no hay nada con qué demostrar quién eres, y exigir
    /// una prueba imposible dejaría al dueño encerrado fuera de sus propios
    /// datos para siempre. Con código, `disable()` sigue exigiéndola.
    func disableBecauseNoPasscode() {
        guard !Self.canLock else { return }
        defaults.set(false, forKey: Self.enabledKey)
        isLocked = false
        lastFailure = nil
        objectWillChange.send()
    }

    /// Abre Ajustes de iOS en la ficha de AgruPay.
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// La app deja de estar activa. Se bloquea **aquí** y no al volver, porque
    /// esta es la pantalla que iOS fotografía para el conmutador de apps: si se
    /// esperara al regreso, el saldo quedaría a la vista en la vista de tarjetas.
    func sceneWillResignActive() {
        guard isEnabled, !isAuthenticating, !isLocked else { return }
        leftForegroundAt = Date()
        isLocked = true
    }

    /// La app vuelve. Si el margen elegido todavía no se ha agotado, se
    /// devuelve el acceso sin preguntar nada.
    func sceneDidBecomeActive() {
        guard isEnabled, !isAuthenticating, isLocked else { return }
        guard grace != .immediately, let left = leftForegroundAt else { return }
        if Date().timeIntervalSince(left) < Double(grace.rawValue) {
            isLocked = false
            leftForegroundAt = nil
        }
    }

    // MARK: - LocalAuthentication

    /// `nil` si el usuario se autenticó; si no, el fallo con su salida.
    private func attempt(reason: String, preferPasscode: Bool = false) async -> AppLockFailure? {
        guard Self.canLock else { return .noPasscode }

        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        currentContext = context
        defer { currentContext = nil }
        context.localizedCancelTitle = "Cancelar"
        // Sin título de reserva, iOS espera a los tres intentos fallidos antes
        // de ofrecer el código. Nombrarlo lo pone desde el primer segundo.
        context.localizedFallbackTitle = preferPasscode ? "" : "Usar código"

        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                      localizedReason: reason)
            return ok ? nil : .other("No se pudo verificar tu identidad.")
        } catch {
            return AppLockFailure.from(error)
        }
    }

    /// `nil` si se autenticó; si no, el motivo en texto (activar/desactivar el
    /// ajuste sólo necesita decirlo, no ofrecer pasos).
    private func authenticate(reason: String) async -> String? {
        await attempt(reason: reason).map { failure in
            failure == .cancelled ? "Verificación cancelada." : failure.headline
        }
    }
}
