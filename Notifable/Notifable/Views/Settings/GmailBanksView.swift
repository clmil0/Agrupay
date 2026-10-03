import SwiftUI
import SwiftData

/// Correo y bancos: todo lo del correo en una sola pantalla — la cuenta
/// conectada, la lectura, cuánto atrás, los bancos y el acceso.
///
/// Antes eran dos filas en la raíz, «Correo» (en Cuenta) y «Gmail y bancos»
/// (en Captura automática), y las dos repetían «Última lectura» y «Leer
/// ahora»: no se sabía a cuál entrar. Outlook (y Hotmail) va debajo de
/// Gmail; la lectura, el alcance y los bancos son los mismos para los dos.
struct GmailBanksView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    @AppStorage(ProStore.enabledKey) private var isPro = false
    @AppStorage(GmailLookback.allHistoryKey) private var wantsAllHistory = false

    @StateObject private var gmailAuth = GmailAuthService.shared
    @StateObject private var gmailSync = GmailSyncService.shared
    @StateObject private var outlookAuth = OutlookAuthService.shared

    @State private var showRecoveryAlert = false
    @State private var showUnlinkDialog = false
    @State private var showSwitchDialog = false
    @State private var showUnlinkOutlook = false
    @State private var isLinkingOutlook = false
    @State private var paywall: ProStore.Feature?
    /// Se guarda aquí para que los `Toggle` redibujen: `BankSource.isEnabled`
    /// escribe en `UserDefaults` y no publica cambios por sí solo.
    @State private var bankStates: [String: Bool] = [:]
    @State private var monthCounts: [String: Int] = [:]

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    private var palette: Palette { Palette(scheme) }
    private var readsAll: Bool { isPro && wantsAllHistory }
    private var connected: Bool { gmailAuth.isAuthenticated && !gmailAuth.missingGmailScope }

    var body: some View {
        SettingsPage(title: "Correo y bancos") {
            if connected {
                accountCard(email: gmailAuth.accountEmail ?? "Gmail vinculado")
            } else {
                GmailConnectCard()
            }
            if OutlookAuthService.isConfigured { outlookSection }
            if connected || outlookAuth.isAuthenticated { readingSection }
            lookbackSection
            banksSection
            if connected {
                accessSection
                SettingsGroup(footer: "Tus movimientos se quedan en el teléfono. Sólo se detiene la lectura automática.") {
                    SettingsAction(title: "Desvincular Gmail", destructive: true) { showUnlinkDialog = true }
                }
            }
        }
        .confirmationDialog("¿Desvincular Gmail?", isPresented: $showUnlinkDialog, titleVisibility: .visible) {
            Button("Desvincular", role: .destructive) { gmailAuth.signOut() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Los gastos ya registrados se conservan. Dejarán de entrar nuevos.")
        }
        .confirmationDialog("¿Desvincular Outlook?", isPresented: $showUnlinkOutlook, titleVisibility: .visible) {
            Button("Desvincular", role: .destructive) { outlookAuth.signOut() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Los gastos ya registrados se conservan. Dejarán de entrar nuevos desde Outlook.")
        }
        .onReceive(outlookAuth.$isAuthenticated) { if $0 { isLinkingOutlook = false } }
        .confirmationDialog("¿Cambiar de cuenta?", isPresented: $showSwitchDialog, titleVisibility: .visible) {
            Button("Elegir otra cuenta") {
                gmailAuth.signOut()
                gmailAuth.signIn()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se desvincula esta cuenta y Google te pide la nueva. Lo ya registrado se conserva.")
        }
        .onAppear {
            loadBankStates()
            countThisMonth()
            // El resumen es de la última lectura, que pudo ser hace rato.
            if !gmailSync.isSyncing { gmailSync.lastRunSummary = nil }
        }
        .onChange(of: gmailSync.isSyncing) { _, syncing in
            if !syncing { countThisMonth() }
        }
        .gmailRecoveryAlert(isPresented: $showRecoveryAlert) { startSync() }
        .proPaywall($paywall)
    }

    // MARK: - Cuenta

    private func accountCard(email: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.positive)
                .frame(width: 40, height: 40)
                .background(palette.positive.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                // La cuenta concreta: quien tiene varias quiere saber cuál
                // está leyendo la app.
                Text(email)
                    .font(.headline)
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.8)
                Text("Sólo lectura del correo · conectado")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
            }
            Spacer(minLength: 8)
            Circle().fill(palette.positive).frame(width: 8, height: 8)
        }
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
        .padding(.horizontal, 16)
    }

    private var accessSection: some View {
        SettingsGroup(title: "Acceso") {
            SettingsButton(title: "Permisos de Google", value: "Gmail · lectura") {
                if let url = URL(string: "https://myaccount.google.com/permissions") {
                    UIApplication.shared.open(url)
                }
            }
            SettingsDivider(inset: 14)
            SettingsButton(title: "Cambiar de cuenta") { showSwitchDialog = true }
        }
    }

    // MARK: - Outlook

    /// Outlook, Hotmail y Live usan la misma cuenta de Microsoft.
    @ViewBuilder
    private var outlookSection: some View {
        if outlookAuth.isAuthenticated {
            accountCard(email: outlookAuth.accountEmail ?? "Outlook vinculado")
            SettingsGroup(title: "Outlook") {
                SettingsButton(title: "Permisos de Microsoft", value: "Correo · lectura") {
                    if let url = URL(string: "https://account.live.com/consent/Manage") {
                        UIApplication.shared.open(url)
                    }
                }
                SettingsDivider(inset: 14)
                SettingsAction(title: "Desvincular Outlook", destructive: true) { showUnlinkOutlook = true }
            }
        } else {
            SettingsGroup(title: "Outlook",
                          footer: outlookAuth.accessRevoked
                              ? "Microsoft cortó el acceso. Vuelve a vincular para seguir leyendo tus avisos."
                              : "Para correos de Outlook, Hotmail o Live. Se lee igual que Gmail: sólo los avisos de tus bancos.") {
                SettingsButton(icon: "envelope.fill", tint: Color(hex: 0x0078D4),
                               title: isLinkingOutlook ? "Conectando…" : "Vincular Outlook o Hotmail") {
                    isLinkingOutlook = true
                    outlookAuth.signIn()
                    // Cancelar en la ventana de Microsoft no avisa de nada.
                    Task {
                        try? await Task.sleep(for: .seconds(20))
                        isLinkingOutlook = false
                    }
                }
            }
        }
    }

    // MARK: - Lectura

    private var readingSection: some View {
        SettingsGroup(title: "Lectura", footer: readingFooter) {
            if gmailSync.isSyncing {
                GmailSyncProgress()
            } else {
                SettingsItem(icon: "arrow.triangle.2.circlepath", tint: Color(hex: 0x40C8E0),
                             title: "Última lectura") {
                    // Se redibuja sola: la lectura corre cada minuto con la
                    // app abierta y «hace 6 min» no puede quedarse congelado.
                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                        Text(GmailLookback.lastSyncLabel(gmailSync.lastSyncDate))
                            .foregroundStyle(palette.secondaryLabel)
                    }
                }
                SettingsDivider()
                SettingsButton(icon: "bolt.fill", tint: Color(hex: 0x40C8E0), title: "Leer ahora",
                               subtitle: "Busca gastos nuevos en tu correo", action: readNow)
                if gmailSync.failedEmailCount > 0 {
                    SettingsDivider()
                    SettingsButton(icon: "exclamationmark.arrow.triangle.2.circlepath", tint: palette.warning,
                                   title: "Reintentar correos fallidos",
                                   subtitle: gmailSync.failedEmailCount == 1
                                       ? "1 correo no se pudo descargar"
                                       : "\(gmailSync.failedEmailCount) correos no se pudieron descargar") {
                        gmailSync.modelContext = modelContext
                        gmailSync.retryFailedEmails()
                    }
                }
            }
        }
    }

    /// Sin esto una lectura que fallaba o no encontraba nada se veía igual.
    private var readingFooter: String? {
        if let error = gmailSync.lastSyncError { return error }
        return gmailSync.lastRunSummary
            ?? "AgruPay lee sólo los correos de tus bancos. Nunca envía ni borra nada."
    }

    private func readNow() {
        gmailSync.modelContext = modelContext
        if !DeletedEmails.undecided().isEmpty {
            showRecoveryAlert = true
        } else {
            startSync()
        }
    }

    private func startSync() {
        gmailSync.syncEmails(force: true, startDate: GmailLookback.startDate, endDate: Date())
    }

    // MARK: - Cuánto atrás

    private var lookbackSection: some View {
        SettingsGroup(title: "Cuánto atrás") {
            SettingsChoice(title: "Últimos 3 meses", selected: !readsAll) {
                wantsAllHistory = false
            }
            SettingsDivider(inset: 14)
            NavigationLink {
                RangeSyncView()
            } label: {
                SettingsItem(title: "Un rango de fechas",
                             subtitle: isPro ? "Cualquier fecha desde tu primer correo" : "Dentro de los últimos 3 meses") {
                    SettingsValueChevron()
                }
            }
            .buttonStyle(.plain)
            SettingsDivider(inset: 14)
            SettingsChoice(title: "Todo el historial", subtitle: "Desde tu primer correo del banco",
                           pro: !isPro, selected: readsAll, opensMore: !isPro) {
                if isPro { wantsAllHistory = true } else { paywall = .history }
            }
        }
    }

    // MARK: - Bancos

    private var banksSection: some View {
        SettingsGroup(title: "Bancos compatibles · \(activeCount) activos",
                      footer: "El efectivo y los Yape pequeños no llegan por correo. Regístralos con un atajo de un toque, en Recurrentes y atajos.") {
            ForEach(Array(BankSource.all.enumerated()), id: \.element.id) { index, bank in
                bankRow(bank)
                if index < BankSource.all.count - 1 { SettingsDivider() }
            }
        }
    }

    private var activeCount: Int {
        BankSource.all.filter { bankStates[$0.storageKey] ?? $0.isEnabled }.count
    }

    private func bankRow(_ bank: BankSource) -> some View {
        let isOn = bankStates[bank.storageKey] ?? bank.isEnabled
        let count = monthCounts[bank.id] ?? 0

        return HStack(spacing: 12) {
            Image(bank.logoAsset)
                .resizable()
                .scaledToFill()
                .frame(width: 30, height: 30)
                .clipShape(Circle())
                .opacity(isOn ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 2) {
                Text(bank.name)
                    .foregroundStyle(isOn ? palette.label : palette.secondaryLabel)
                Text(count == 0 ? "Sin gastos este mes" : count == 1 ? "1 gasto este mes" : "\(count) gastos este mes")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: binding(for: bank))
                .labelsHidden()
                .tint(accent.color)
                .accessibilityLabel(bank.name)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
    }

    private func binding(for bank: BankSource) -> Binding<Bool> {
        Binding(
            get: { bankStates[bank.storageKey] ?? bank.isEnabled },
            set: { newValue in
                bank.isEnabled = newValue
                bankStates[bank.storageKey] = newValue
            }
        )
    }

    private func loadBankStates() {
        for bank in BankSource.all where bankStates[bank.storageKey] == nil {
            bankStates[bank.storageKey] = bank.isEnabled
        }
    }

    /// Cuántos gastos del mes trajo cada banco, contados una vez al entrar.
    private func countThisMonth() {
        let month = Period(granularity: .mes, reference: Date()).interval
        let start = month.start, end = month.end
        var descriptor = FetchDescriptor<Expense>(predicate: #Predicate { $0.date >= start && $0.date < end })
        descriptor.propertiesToFetch = [\.sourceBank]
        let banks = ((try? modelContext.fetch(descriptor)) ?? []).compactMap { $0.sourceBank?.lowercased() }
        var counts: [String: Int] = [:]
        for bank in BankSource.all {
            counts[bank.id] = banks.filter { $0.contains(bank.id) }.count
        }
        monthCounts = counts
    }
}

// MARK: - Cuánto atrás

/// Desde cuándo lee «Leer ahora». Gratis, los últimos 3 meses; con Pro se
/// puede pedir todo el historial.
enum GmailLookback {

    static let allHistoryKey = "gmailReadsAllHistory"

    /// Sin fecha en el aviso más viejo que se busca: el primer correo de un
    /// banco peruano que lee la app es bastante posterior.
    static let allHistoryStart: Date = {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: 2015, month: 1, day: 1)) ?? .distantPast
    }()

    static var readsAll: Bool {
        ProStore.isPro && UserDefaults.standard.bool(forKey: allHistoryKey)
    }

    static var startDate: Date {
        readsAll ? allHistoryStart : GmailSyncService.smartRangeStart(months: ProStore.freeHistoryMonths)
    }

    /// Lo más atrás que se puede pedir en «Un rango de fechas».
    static var earliestRangeStart: Date {
        guard !ProStore.isPro else { return allHistoryStart }
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .month, value: -ProStore.freeHistoryMonths, to: today) ?? today
    }

    static func lastSyncLabel(_ date: Date?) -> String {
        SettingsStatus(isConnected: true, account: nil, lastSync: date,
                       activeBankCount: 0, totalBankCount: 0, expensesThisMonth: 0,
                       unclassifiedMerchants: 0, pendingRecurring: 0).lastSyncLabel
    }
}

// MARK: - Piezas compartidas

/// Sin cuenta, o sin el permiso de Gmail: la única acción es conectar.
struct GmailConnectCard: View {
    @StateObject private var gmailAuth = GmailAuthService.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var isLinking = false

    private var lacksPermission: Bool { gmailAuth.isAuthenticated && gmailAuth.missingGmailScope }

    var body: some View {
        let palette = Palette(scheme)
        let accent = AppThemeColor.current
        VStack(spacing: 14) {
            SettingsItem(icon: "envelope.fill", tint: lacksPermission || gmailAuth.accessRevoked ? palette.negative : Color(white: 0.45),
                         title: lacksPermission ? "Falta el permiso de Gmail"
                            : gmailAuth.accessRevoked ? "Google cortó el acceso" : "Gmail sin vincular",
                         subtitle: lacksPermission
                            ? "Vuelve a conectar y marca la casilla de Gmail."
                            : gmailAuth.accessRevoked
                                ? "Vuelve a vincular para seguir leyendo tus avisos."
                                : "AgruPay lee los avisos de tu banco para registrar gastos solo.") {
                EmptyView()
            }
            Button {
                isLinking = true
                gmailAuth.signIn()
            } label: {
                Text(isLinking ? "Conectando…" : lacksPermission ? "Volver a conectar" : "Vincular Gmail")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(accent.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 12)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
        .padding(.horizontal, 16)
        .onReceive(gmailAuth.$isAuthenticated) { if $0 { isLinking = false } }
        // Cancelar en la pantalla de Google no avisa de nada: si al volver
        // seguimos sin cuenta, el botón se destraba solo.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, isLinking else { return }
            Task {
                try? await Task.sleep(for: .seconds(5))
                if !gmailAuth.isAuthenticated || gmailAuth.missingGmailScope { isLinking = false }
            }
        }
    }
}

/// La barra de progreso mientras se lee el correo.
struct GmailSyncProgress: View {
    @StateObject private var gmailSync = GmailSyncService.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        VStack(alignment: .leading, spacing: 8) {
            Text("Buscando gastos nuevos…")
                .foregroundStyle(palette.label)
            ProgressView(value: Double(gmailSync.emailsProcessed),
                         total: Double(max(1, gmailSync.totalEmailsToProcess)))
                .animation(.easeInOut, value: gmailSync.emailsProcessed)
            Text("\(gmailSync.emailsProcessed) de \(gmailSync.totalEmailsToProcess) correos")
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)
        }
        .padding(14)
    }
}

extension View {
    /// Antes de leer: si borraste movimientos que venían del correo, se
    /// pregunta si recuperarlos, porque leer su periodo no los trae de vuelta.
    func gmailRecoveryAlert(isPresented: Binding<Bool>, onDecline: @escaping () -> Void) -> some View {
        alert("Recuperación de Gastos", isPresented: isPresented) {
            Button("Sí, recuperar") {
                GmailSyncService.shared.recoverExpenses(ids: DeletedEmails.all())
            }
            Button("No, seguir sin ellos") {
                DeletedEmails.decline()
                onDecline()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Borraste movimientos que venían del correo. Si no los recuperas, seguirán borrados aunque leas su periodo.")
        }
    }
}
