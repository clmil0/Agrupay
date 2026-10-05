import SwiftUI
import SwiftData

/// Sincronización: un solo interruptor.
///
/// La decisión de diseño es que el usuario no elija una identidad. Si su correo
/// de Google ya está conectado —lo está, si la app lee sus movimientos— activar
/// la sincronización no le pide nada: se guarda con esa cuenta. El código de
/// respaldo es la salida de emergencia de quien no quiere iniciar sesión, no el
/// camino principal.
///
/// Las explicaciones largas no se muestran de entrada: viven detrás de un
/// icono de información en la cabecera de cada tarjeta. Quien ya entendió cómo
/// funciona ve una pantalla de cuatro líneas; quien duda, toca la ⓘ.
struct ConfigBackupView: View {

    @Environment(\.colorScheme) private var scheme
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false

    @State private var manager = ConfigBackupManager.shared

    @State private var isWorking = false
    @State private var showCodeOption = false
    @State private var showCodeField = false
    @State private var restoreCodeDraft = ""
    @State private var showDisableConfirm = false
    @State private var codeCopied = false
    @State private var errorCopied = false
    @State private var feedback: String?

    // Qué explicación está abierta. Una por tarjeta, todas cerradas al entrar.
    @State private var explainSync = false
    @State private var explainIdentity = false
    @State private var explainRestore = false

    // Confirmación antes de sobrescribir lo de este teléfono.
    @State private var pendingRestore: BackupHeader?
    /// Advertencia antes de reemplazar la copia desde la tarjeta de pausa.
    @State private var pendingOverwrite: BackupHeader?
    @State private var pendingRestoreCode: String?

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                statusCard

                if manager.isEnabled {
                    identityCard
                    actionsRow
                } else if manager.isPausedAfterWipe {
                    pausedCard
                } else {
                    activateCard
                }

                restoreCard

                if manager.isEnabled { disableRow }
            }
            .padding(.vertical, 16)
        }
        .background(palette.background)
        .navigationTitle("Sincronización")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pendingOverwrite) { header in
            OverwriteBackupSheet(header: header, accent: accent) {
                pendingOverwrite = nil
                Task { await run { await manager.resumeAfterWipe(restoreFirst: true) } }
            } onOverwrite: {
                pendingOverwrite = nil
                Task { await run { await manager.confirmOverwrite() } }
            } onLater: {
                pendingOverwrite = nil
            }
        }
        .sheet(item: $pendingRestore) { header in
            RestoreConfirmSheet(header: header, accent: accent) {
                let code = pendingRestoreCode
                pendingRestore = nil
                Task { await run { await manager.restore(code: code) } }
            } onCancel: {
                pendingRestore = nil
            }
        }
        .alert("¿Desactivar la sincronización?", isPresented: $showDisableConfirm) {
            Button("Cancelar", role: .cancel) {}
            Button("Desactivar", role: .destructive) {
                Task { await run { await manager.disable(deleteRemote: false); return nil } }
            }
            Button("Desactivar y borrar la copia", role: .destructive) {
                Task { await run { await manager.disable(deleteRemote: true); return nil } }
            }
        } message: {
            Text("Este dispositivo no se ve afectado: sólo deja de subir cambios.")
        }
    }

    // MARK: - Tarjeta de estado

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                iconTile(state.icon, tint: state.tint(palette, accent, scheme), spinning: state == .syncing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.label)
                    Text(state.subtitle(manager))
                        .font(.caption)
                        .foregroundStyle(state == .failing ? palette.negative : palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                infoButton($explainSync)
            }

            if explainSync {
                Text("Se guarda sola cada vez que cambias algo: reglas, categorías, límites, presupuesto, atajos, recurrentes, lo que marcaste por cobrar y los movimientos que anotas a mano. Tus gastos del correo no se suben — se vuelven a leer solos.")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
                    .transition(.opacity)
            }

            if state == .failing {
                if let last = manager.lastSyncedAt {
                    Text("Tus cambios siguen guardados en este celular. El último que se subió es del \(last.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryLabel)
                }
                HStack(spacing: 10) {
                    if !manager.canUseAccount {
                        smallButton("Conectar mi correo", icon: "envelope") {
                            GmailAuthService.shared.signIn()
                        }
                    }
                    smallButton("Reintentar", icon: "arrow.clockwise") {
                        Task { await run { _ = await manager.syncNow(); return manager.lastErrorMessage } }
                    }
                    // El mensaje puede traer un client ID que hay que pegar en
                    // el panel de Supabase: copiarlo a mano desde el teléfono
                    // es justo donde se cometen erratas.
                    smallButton(errorCopied ? "Copiado" : "Copiar", icon: errorCopied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = manager.lastErrorMessage
                        withAnimation { errorCopied = true }
                    }
                }
            }

            if let feedback, state != .failing {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
            }
        }
        .surfaceCard()
    }

    fileprivate enum SyncState { case off, paused, syncing, synced, failing }

    private var state: SyncState {
        if manager.lastErrorMessage != nil { return .failing }
        if manager.isSyncing { return .syncing }
        if manager.isEnabled { return .synced }
        return manager.isPausedAfterWipe ? .paused : .off
    }

    // MARK: - Identidad

    @ViewBuilder
    private var identityCard: some View {
        if manager.mode == .account {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    iconTile("person.crop.circle.badge.checkmark", tint: accent.onSurface(scheme))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Guardado en tu cuenta")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.label)
                        Text(manager.accountEmail ?? "Cuenta de Google")
                            .font(.caption)
                            .foregroundStyle(palette.secondaryLabel)
                    }
                    Spacer(minLength: 0)
                    infoButton($explainIdentity)
                }
                if explainIdentity {
                    Text("No tienes que guardar nada. En un celular nuevo, conecta el mismo correo y toca «Restaurar».")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryLabel)
                        .transition(.opacity)
                }
            }
            .surfaceCard()
        } else if let code = manager.backupCode {
            VStack(alignment: .leading, spacing: 10) {
                Text("Tu código de respaldo")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.label)

                HStack {
                    Text(code)
                        .font(.footnote.monospaced())
                        .fontDesign(.monospaced)
                        .foregroundStyle(palette.label)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button {
                        UIPasteboard.general.string = code
                        withAnimation { codeCopied = true }
                    } label: {
                        Image(systemName: codeCopied ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(accent.onSurface(scheme))
                    }
                }
                .padding(12)
                .background(palette.track)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                // Este aviso NO se esconde detrás de la ⓘ: es el riesgo del
                // modo sin cuenta, y verlo tarde es exactamente el fallo.
                Text("Guárdalo fuera de este celular: es la única llave. Si lo pierdes, el respaldo no se puede recuperar.")
                    .font(.caption)
                    .foregroundStyle(palette.negative)

                if manager.canUseAccount {
                    Button("Mejor usar mi cuenta de Google") {
                        Task { await run { await manager.enableWithAccount() } }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent.onSurface(scheme))
                }
            }
            .surfaceCard()
        }
    }

    // MARK: - Activar

    private var activateCard: some View {
        VStack(spacing: 12) {
            Button {
                Task { await run { await manager.enableWithAccount() } }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Activar con mi cuenta de Google")
                            .font(.subheadline.weight(.semibold))
                        if manager.canUseAccount, let email = manager.accountEmail {
                            Text(email).font(.caption2).opacity(0.9)
                        }
                    }
                }
                .foregroundStyle(accent.buttonText)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(accent.buttonFill)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isWorking)

            if !manager.canUseAccount {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "envelope")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryLabel)
                    Text("Para usar tu cuenta, primero conecta tu correo en Configuración → Correo y bancos. Si ya lo conectaste antes de esta versión, vuelve a conectarlo una vez.")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryLabel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(showCodeOption ? "Ocultar" : "No quiero iniciar sesión") {
                withAnimation(.snappy) { showCodeOption.toggle() }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(palette.secondaryLabel)

            if showCodeOption {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sin cuenta, la única llave es un código que tienes que guardar tú. Si lo pierdes, el respaldo se pierde con él.")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryLabel)
                    Button("Activar con un código") {
                        Task { await run { _ = await manager.enableWithCode(); return manager.lastErrorMessage } }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent.onSurface(scheme))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
        .surfaceCard()
    }

    // MARK: - Pausada tras "Empezar de cero"

    private var pausedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tu copia sigue intacta. Elige qué hacer antes de volver a encenderla.")
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)

            Button {
                Task { await run { await manager.resumeAfterWipe(restoreFirst: true) } }
            } label: {
                choiceRow(icon: "arrow.down.circle",
                          title: "Traer la copia a este celular",
                          detail: "Vuelven tus ajustes, atajos, cobros y lo anotado a mano.",
                          tint: accent.onSurface(scheme))
            }
            .buttonStyle(.plain)

            Rectangle().fill(palette.separator).frame(height: 0.5)

            Button {
                // Nunca directo: primero se enseña qué se va a perder.
                Task { await askBeforeOverwrite() }
            } label: {
                choiceRow(icon: "trash",
                          title: "Empezar de cero también en la copia",
                          detail: "Se borra lo guardado y no se puede recuperar.",
                          tint: palette.negative)
            }
            .buttonStyle(.plain)
        }
        .surfaceCard()
    }

    // MARK: - Acciones

    private var actionsRow: some View {
        HStack(spacing: 10) {
            secondaryButton("Sincronizar ahora", icon: "arrow.triangle.2.circlepath") {
                Task { await run { _ = await manager.syncNow(); return manager.lastErrorMessage } }
            }
            secondaryButton("Restaurar aquí", icon: "arrow.down.circle") {
                Task { await askRestore(code: nil) }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Restaurar

    private var restoreCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Restaurar en este dispositivo")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.label)
                Spacer(minLength: 0)
                infoButton($explainRestore)
            }

            if explainRestore {
                Text("Trae la configuración guardada y la aplica aquí. Los movimientos que anotaste a mano en este celular no se borran.")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
                    .transition(.opacity)
            }

            if manager.canUseAccount {
                Button {
                    Task { await askRestore(code: nil) }
                } label: {
                    Label("Restaurar desde mi cuenta", systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accent.onSurface(scheme))
                }
                .disabled(isWorking)
            }

            Button {
                withAnimation(.snappy) { showCodeField.toggle() }
            } label: {
                HStack {
                    Text("Tengo un código de respaldo")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondaryLabel)
                    Spacer(minLength: 0)
                    Image(systemName: showCodeField ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.secondaryLabel)
                }
            }
            .buttonStyle(.plain)

            if showCodeField {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("xxxx-xxxx-xxxx-xxxx-xxxx-xxxx", text: $restoreCodeDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.subheadline.monospaced())
                        .fontDesign(.monospaced)
                        .padding(12)
                        .background(palette.track)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                    Button("Restaurar con el código") {
                        let code = restoreCodeDraft
                        Task { await askRestore(code: code) }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent.onSurface(scheme))
                    .disabled(restoreCodeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .transition(.opacity)
            }

            Rectangle().fill(palette.separator).frame(height: 0.5).padding(.vertical, 2)

            Text("QUÉ VUELVE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.tertiaryLabel)
            returnsRow("slider.horizontal.3", "Ajustes, reglas y categorías")
            returnsRow("bolt.fill", "Atajos y gastos recurrentes")
            returnsRow("square.and.pencil", "Cobros y lo que anotaste a mano")
        }
        .surfaceCard()
    }

    private func returnsRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .frame(width: 18)
                .foregroundStyle(accent.onSurface(scheme))
            Text(text)
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)
        }
    }

    private var disableRow: some View {
        Button(role: .destructive) {
            showDisableConfirm = true
        } label: {
            HStack {
                Image(systemName: "icloud.slash")
                Text("Desactivar la sincronización")
                Spacer(minLength: 0)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(palette.negative)
            .padding(16)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(palette.negative.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .padding(.horizontal, 16)
    }

    // MARK: - Acciones auxiliares

    /// Nunca se restaura a ciegas: primero se pregunta al servidor de cuándo es
    /// la copia y de qué teléfono salió, y eso es lo que se enseña.
    private func askRestore(code: String?) async {
        isWorking = true
        feedback = nil
        let clean = code?.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = await manager.peek(code: clean)
        isWorking = false
        guard let header else {
            feedback = manager.lastErrorMessage ?? "No se encontró ningún respaldo."
            return
        }
        pendingRestoreCode = (clean?.isEmpty == false) ? clean : nil
        pendingRestore = header
    }

    /// La copia está vacía: no hay nada que perder y se reanuda sin más. Si
    /// tiene datos, la advertencia. Sin respuesta del servidor no se toca nada.
    private func askBeforeOverwrite() async {
        isWorking = true
        feedback = nil
        let header = await manager.pausedBackupHeader()
        isWorking = false
        guard let header else {
            feedback = manager.lastErrorMessage ?? "No se pudo revisar la copia. Inténtalo de nuevo."
            return
        }
        if header.hasData {
            pendingOverwrite = header
        } else {
            await run { await manager.confirmOverwrite() }
        }
    }

    /// Un solo sitio donde se enciende el spinner y se traduce el resultado:
    /// la operación devuelve el motivo del fallo, o `nil` si salió bien.
    private func run(_ operation: () async -> String?) async {
        isWorking = true
        feedback = nil
        let error = await operation()
        isWorking = false
        feedback = error ?? "Listo."
    }

    // MARK: - Piezas

    private func infoButton(_ isOpen: Binding<Bool>) -> some View {
        Button {
            withAnimation(.snappy) { isOpen.wrappedValue.toggle() }
        } label: {
            Image(systemName: isOpen.wrappedValue ? "info.circle.fill" : "info.circle")
                .font(.system(size: 17))
                .foregroundStyle(isOpen.wrappedValue ? accent.onSurface(scheme) : palette.tertiaryLabel)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen.wrappedValue ? "Ocultar explicación" : "Qué significa esto")
    }

    private func iconTile(_ symbol: String, tint: Color, spinning: Bool = false) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.18))
                .frame(width: 40, height: 40)
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(tint)
                .symbolEffect(.rotate, options: spinning ? .repeating : .default, isActive: spinning)
        }
    }

    private func choiceRow(icon: String, title: String, detail: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func smallButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title).lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(accent.onSurface(scheme))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(palette.track)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }

    private func secondaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title).lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(accent.onSurface(scheme))
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }
}

// MARK: - Estado de la tarjeta

/// `@MainActor` porque `subtitle(_:)` lee el estado de `ConfigBackupManager`,
/// que sí lo está: sin esto la extensión es un contexto no aislado y no puede
/// tocar `lastSyncedAt` ni `lastErrorMessage`.
@MainActor
fileprivate extension ConfigBackupView.SyncState {

    var icon: String {
        switch self {
        case .off: return "icloud.slash"
        case .paused: return "pause.circle.fill"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .synced: return "checkmark.icloud.fill"
        case .failing: return "exclamationmark.icloud.fill"
        }
    }

    var title: String {
        self == .paused ? "Pausada tras borrar todo" : "Sincronización automática"
    }

    func tint(_ palette: Palette, _ accent: AppThemeColor, _ scheme: ColorScheme) -> Color {
        switch self {
        case .failing: return palette.negative
        case .paused: return palette.secondaryLabel
        default: return accent.onSurface(scheme)
        }
    }

    func subtitle(_ manager: ConfigBackupManager) -> String {
        switch self {
        case .failing:
            return manager.lastErrorMessage ?? "Algo falló."
        case .syncing:
            return "Sincronizando…"
        case .paused:
            if let last = manager.lastSyncedAt {
                return "No se ha subido nada desde el \(last.formatted(date: .abbreviated, time: .shortened))."
            }
            return "No se está subiendo nada."
        case .off:
            return "Desactivada. Si formateas el celular, esto se pierde."
        case .synced:
            if let last = manager.lastSyncedAt {
                return "Última sincronización: \(last.formatted(date: .abbreviated, time: .shortened))"
            }
            return manager.hasPendingChanges ? "Cambios pendientes de subir." : "Activada."
        }
    }
}

// MARK: - Confirmación antes de restaurar

/// Restaurar reemplaza los ajustes de este teléfono. La hoja dice de cuándo es
/// la copia y de qué dispositivo salió: sin eso, aceptar es una apuesta.
struct RestoreConfirmSheet: View {

    let header: BackupHeader
    let accent: AppThemeColor
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .fill(palette.tertiaryLabel.opacity(0.5))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            Text("¿Traer esta copia a este celular?")
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.label)
                .multilineTextAlignment(.center)

            VStack(spacing: 0) {
                row("Guardada el", header.updatedAt?.formatted(date: .long, time: .shortened) ?? "—")
                divider
                row("Desde", header.deviceLabel ?? header.accountEmail ?? "Otro dispositivo")
                if let rules = header.ruleCount, let categories = header.categoryCount {
                    divider
                    row("Reglas y categorías", "\(rules) · \(categories)")
                }
                if let manual = header.manualCount, manual > 0 {
                    divider
                    row("Cobros y anotado a mano", "\(manual)")
                }
            }
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text("Se reemplazan tus ajustes actuales por los de esa fecha. Los movimientos que anotaste a mano en este celular no se borran.")
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)
                .multilineTextAlignment(.center)

            Button(action: onConfirm) {
                Text("Restaurar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent.buttonText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(accent.buttonFill)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Button("Cancelar", action: onCancel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.secondaryLabel)

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(palette.background)
        .presentationDetents([.height(440)])
    }

    private var divider: some View {
        Rectangle().fill(palette.separator).frame(height: 0.5).padding(.leading, 16)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(palette.secondaryLabel)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(palette.label).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
    }
}
