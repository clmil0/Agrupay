import SwiftUI

/// La puerta.
///
/// Dos pantallas en una. Lo que decide cuál se ve **no** es si hubo un fallo,
/// sino si hay algo que arreglar fuera de la app (ver `guidance`):
///
/// - **En reposo (2b)** — la biometría está configurada y funciona. Una sola
///   cosa que tocar: el sello a 96 pt con dos anillos que respiran mientras el
///   sistema busca, y el texto en una línea. Aquí caen también los tropiezos
///   que no hay que explicar —cancelar el diálogo, o que no te reconozca—:
///   lo único que hay que hacer es volver a mirar el teléfono, y el sello ya
///   dice "Toca para entrar". Si iOS no muestra nada —pasa— tocarlo vuelve a
///   pedirlo, que es lo que el usuario intentaría igual.
/// - **Guiada (1b)** — hace falta configurar o desbloquear algo: sin Face ID,
///   sin permiso, bloqueado por intentos, o sin código en el iPhone. El motivo
///   es el titular, los pasos numerados dicen cómo salir y el botón primario es
///   la acción que de verdad desbloquea. Un mensaje de error no es una salida:
///   "Face ID quedó bloqueado" deja al dueño mirando sus datos desde fuera sin
///   saber que se arregla desbloqueando el iPhone con su código.
///
/// No enseña **nada** del contenido: ni el total del mes, ni el último
/// movimiento. Una pantalla de bloqueo que filtra la cifra que protege no
/// protege nada.
struct LockScreenView: View {

    @ObservedObject var lock: AppLock
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false

    @State private var isWorking = false
    /// `true` mientras se espera al sistema. Al agotarse, el sello deja de
    /// respirar y el texto pasa a "Toca para entrar": si iOS no llegó a mostrar
    /// nada, seguir animando sería mentir sobre lo que está pasando.
    @State private var isScanning = true
    @State private var scanTimer: Task<Void, Never>?

    private var palette: Palette { Palette(scheme) }
    /// El ícono de la puerta usa el acento elegido en Apariencia, no el azul
    /// de marca fijo: quien cambió su tema debe reconocerlo también aquí, ya
    /// que esta es la pantalla que iOS fotografía para el conmutador de apps.
    private var accent: Color { AppThemeColor(rawValue: appAccentColor)?.color ?? AppBrand.accent }

    /// Cuál de las dos pantallas toca, y con qué motivo.
    ///
    /// `nil` = la de reposo (2b). Un valor = la guiada (1b).
    ///
    /// Dos reglas, y en este orden:
    ///
    /// 1. Un fallo sólo lleva a 1b si `needsGuidance`: cancelar o no ser
    ///    reconocido son tropiezos con la biometría **ya configurada**, y ahí lo
    ///    único que hay que hacer es volver a mirar el teléfono. Antes cualquier
    ///    fallo saltaba a la pantalla guiada, así que cerrar el diálogo de Face
    ///    ID sacaba tres pasos y dos botones para decir "vuelve a intentarlo".
    /// 2. Sin biometría disponible no se pasa por 2b **en ningún momento**: esa
    ///    pantalla dice "Mira tu iPhone" junto a un sello de Face ID, y sin Face
    ///    ID configurado señala un sensor que no va a mirar nada. Se entra
    ///    directo a la pantalla guiada, sin el parpadeo de 2b que había mientras
    ///    el sistema devolvía el error.
    private var guidance: AppLockFailure? {
        if let failure = lock.lastFailure {
            return failure.needsGuidance ? failure : nil
        }
        guard AppLock.biometry == .none else { return nil }
        // Todavía no se ha intentado nada, así que el motivo exacto lo dirá el
        // sistema; esta es la mejor conjetura hasta que llegue.
        return AppLock.canLock ? .notEnrolled : .noPasscode
    }

    var body: some View {
        let guidance = self.guidance

        return ZStack {
            palette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                if let guidance {
                    failureBody(guidance)
                } else {
                    idleBody
                }

                footer(guidance)
            }
        }
        // Se pide la cara sola al aparecer: obligar a tocar un botón para que
        // salga el diálogo del sistema es un paso que no aporta nada. Pero
        // sólo con la app al frente: la pantalla se monta al pasar a segundo
        // plano, y ahí pedirla sería para una app que no se ve. Al volver se
        // pide; tras un fallo o una cancelación del usuario, no se insiste
        // sola (el propio diálogo de Face ID hace pasar la app por
        // `.inactive` → `.active`).
        .task(id: scenePhase) {
            guard scenePhase == .active, lock.lastFailure == nil else { return }
            await attempt()
        }
        .onDisappear { scanTimer?.cancel() }
        .animation(.snappy, value: lock.lastFailure)
        .animation(.snappy, value: isScanning)
    }

    // MARK: - Cabecera

    private var header: some View {
        VStack(spacing: 8) {
            AppIconTile(size: 64, accent: accent, coinFace: .white, detail: false)
            Text("AgruPay")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(palette.label)
            Text("Bloqueado")
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryLabel)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    // MARK: - 2b · en reposo

    private var idleBody: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            Button {
                Task { await attempt() }
            } label: {
                ZStack {
                    if isScanning {
                        breathingRing(delay: 0)
                        breathingRing(delay: 0.7)
                    }
                    Circle()
                        .fill(palette.surface)
                        .frame(width: 72, height: 72)
                        .overlay(Circle().stroke(palette.hairline, lineWidth: 0.5))
                        .overlay(
                            Image(systemName: AppLock.biometryIcon)
                                .font(.system(size: 30, weight: .light))
                                .foregroundStyle(palette.label)
                        )
                }
                .frame(width: 96, height: 96)
            }
            .buttonStyle(.plain)
            .disabled(isWorking)

            Text(isScanning ? "Desbloquea con " + AppLock.biometryName : "Toca para entrar")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.label)
                .padding(.top, 14)

            if !isScanning {
                Text(idleSubtitle)
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
                    .padding(.top, 6)
            }

            // La salida al código, junto a la acción y no al pie (`5l`).
            Button { run(.usePasscode) } label: {
                Text("Usar código")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.label)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(palette.surface, in: Capsule())
                    .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
            .padding(.top, 18)

            Spacer(minLength: 20)
        }
        .padding(.horizontal, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Mientras se busca, para qué sirve la cara. Al agotarse, **qué pasó**:
    /// un "no respondió" genérico después de cancelar a propósito suena a
    /// avería del teléfono cuando fue una decisión del usuario.
    private var idleSubtitle: String {
        if isScanning {
            return "\(AppLock.biometryName) abre tus movimientos, deudas y sueldo."
        }
        if let failure = lock.lastFailure, !failure.needsGuidance {
            return failure.idleSubtitle
        }
        return "\(AppLock.biometryName) no respondió. Toca el sello y vuelve a mirar."
    }

    /// Los anillos: nacen pegados al sello y se van abriendo hasta desaparecer.
    private func breathingRing(delay: Double) -> some View {
        Circle()
            .stroke(accent, lineWidth: 2)
            .frame(width: 72, height: 72)
            .scaleEffect(isScanning ? 1.45 : 1)
            .opacity(isScanning ? 0 : 0.55)
            .animation(.easeOut(duration: 2.1).repeatForever(autoreverses: false).delay(delay),
                       value: isScanning)
    }

    // MARK: - 1b · tras un fallo

    private func failureBody(_ failure: AppLockFailure) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)

            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(tint(failure.tone).opacity(0.16))
                        .frame(width: 58, height: 58)
                    Image(systemName: failure.icon)
                        .font(.system(size: 24))
                        .foregroundStyle(tint(failure.tone))
                }

                Text(failure.headline)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(palette.label)
                    .multilineTextAlignment(.center)

                Text(failure.body)
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                // Los pasos son lo que convierte el aviso en una salida.
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(failure.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(palette.secondaryLabel)
                                .frame(width: 20, height: 20)
                                .background(palette.track, in: Circle())
                            Text(step)
                                .font(.footnote)
                                .foregroundStyle(palette.label)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(18)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5)
            )

            Spacer(minLength: 16)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tint(_ tone: AppLockFailure.Tone) -> Color {
        switch tone {
        case .neutral: return palette.secondaryLabel
        case .warning: return palette.warning
        case .error: return palette.negative
        }
    }

    // MARK: - Pie

    private func footer(_ guidance: AppLockFailure?) -> some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock")
                    .font(.system(size: 11))
                Text(privacyLine)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(palette.secondaryLabel)

            if let failure = guidance {
                let primary = failure.primary
                filledButton(primary.label) { run(primary.action) }
                if let secondary = failure.secondary {
                    Button(secondary.label) { run(secondary.action) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.secondaryLabel)
                        .disabled(isWorking)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 46)
    }

    /// La frase del cifrado, verdadera según el caso. «No los sube a ningún
    /// servidor» sólo es cierto sin respaldo: con él, los movimientos anotados
    /// a mano viajan a tu copia en la nube (los del correo nunca, se rearman
    /// releyéndolo). Ver `ConfigBackupManager.buildSnapshot`.
    private var privacyLine: String {
        ConfigBackupManager.shared.isEnabled
            ? "Tus movimientos siguen cifrados en el iPhone. Sólo los que anotas a mano viajan a tu respaldo."
            : "Tus movimientos siguen cifrados en el iPhone. AgruPay no los sube a ningún servidor."
    }

    private func filledButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isWorking { ProgressView().tint(accent.readableText) }
                Text(isWorking ? "Verificando…" : title)
            }
            .font(.headline)
            .foregroundStyle(accent.readableText)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(accent.readableFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }

    // MARK: - Acciones

    private func run(_ action: AppLockFailure.Action) {
        switch action {
        case .retryBiometrics:
            Task { await attempt() }
        case .usePasscode:
            Task { await attempt(preferPasscode: true) }
        case .openSettings:
            lock.openSystemSettings()
        case .turnOffLock:
            lock.disableBecauseNoPasscode()
        }
    }

    private func attempt(preferPasscode: Bool = false) async {
        guard !isWorking else { return }
        isWorking = true
        startScanning()
        await lock.unlock(preferPasscode: preferPasscode)
        isWorking = false
        if lock.lastFailure != nil { stopScanning() }
    }

    private func startScanning() {
        scanTimer?.cancel()
        isScanning = true
        scanTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_200_000_000)
            guard !Task.isCancelled else { return }
            isScanning = false
        }
    }

    private func stopScanning() {
        scanTimer?.cancel()
        isScanning = false
    }
}
