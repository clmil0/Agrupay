import SwiftUI
import SwiftData

/// La cápsula de la izquierda del header de Movimientos: de qué correo lee la
/// lista y cuándo leyó («Gmail · 9:42»), «Leyendo correo…» mientras lee y en
/// ámbar si algo impide leer (más de dos días sin lectura, sin permiso, sin
/// bancos). Lleva cuántos movimientos nuevos siguen resaltados.
///
/// En la raíz de la pestaña no hay botón de volver y ese lado quedaba vacío;
/// el dato vivía sólo en Ajustes. Tocarla abre esa misma tarjeta en una hoja
/// («Movimientos Propuesta», solución 01).
struct MailStatusChip: View {
    @StateObject private var gmailAuth = GmailAuthService.shared
    @StateObject private var gmailSync = GmailSyncService.shared
    @StateObject private var outlookAuth = OutlookAuthService.shared
    @State private var newMovements = NewMovements.shared
    @State private var showsSheet = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    private var palette: Palette { Palette(scheme).themed(proTheme) }

    var body: some View {
        Button { showsSheet = true } label: {
            // Se redibuja sola: «hace 3 días» o la hora no pueden quedarse
            // congelados con la pestaña abierta.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                label(MailStatus.current(now: context.date))
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showsSheet) {
            MailStatusSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
    }

    private func label(_ status: MailStatus) -> some View {
        HStack(spacing: 7) {
            switch status.kind {
            case .reading:
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 20, height: 20)
            case .disconnected:
                Image(systemName: "envelope")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.secondaryLabel)
                    .frame(width: 20, height: 20)
            case .ok, .attention:
                logo(status)
            }

            Text(status.text)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(textColor(status))
                .lineLimit(1)

            let fresh = newMovements.lit.count
            if fresh > 0 {
                Text(fresh > 99 ? "99+" : "\(fresh)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(palette.expense, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .frame(height: ShellMetrics.headerControl)
        .background(palette.surface, in: Capsule())
        .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
        .contentShape(Capsule())
        .animation(.snappy(duration: 0.25), value: newMovements.lit.count)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.accessibilityText)
        .accessibilityHint("Abre el estado del correo")
    }

    /// El logo del correo con el punto de estado: verde al día, ámbar si
    /// necesita atención.
    private func logo(_ status: MailStatus) -> some View {
        Group {
            if let asset = status.provider.asset {
                Image(asset)
                    .resizable()
                    .scaledToFit()
                    .padding(2)
                    .frame(width: 20, height: 20)
                    .background(Color.white, in: Circle())
            } else {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.secondaryLabel)
                    .frame(width: 20, height: 20)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(status.kind == .attention ? palette.warning : palette.positive)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(palette.surface, lineWidth: 1.5))
                .offset(x: 2, y: 1)
        }
    }

    private func textColor(_ status: MailStatus) -> Color {
        switch status.kind {
        case .attention: return palette.warning
        case .reading, .disconnected: return palette.secondaryLabel
        case .ok: return palette.label
        }
    }
}

/// Lo que dice la cápsula. Las mismas reglas que la tarjeta de Ajustes
/// (`SettingsStatus.level`): ámbar sin permiso, sin bancos o pasadas 48 h.
struct MailStatus {
    enum Kind { case ok, attention, reading, disconnected }

    enum Provider {
        case gmail, outlook, both

        var name: String {
            switch self {
            case .gmail: return "Gmail"
            case .outlook: return "Outlook"
            case .both: return "Correo"
            }
        }

        var asset: String? {
            switch self {
            case .gmail: return "gmail_icon"
            case .outlook: return "outlook_icon"
            case .both: return nil
            }
        }
    }

    let kind: Kind
    let provider: Provider
    let text: String

    var accessibilityText: String {
        switch kind {
        case .ok: return "\(provider.name), leído a las \(text.components(separatedBy: " · ").last ?? "")"
        default: return text
        }
    }

    static func current(now: Date = Date()) -> MailStatus {
        let sync = GmailSyncService.shared
        let gmail = GmailSyncService.qaToken != nil || GmailAuthService.shared.isAuthenticated
        let outlook = OutlookAuthService.shared.isAuthenticated
        let provider: Provider = gmail && outlook ? .both : outlook ? .outlook : .gmail

        guard gmail || outlook else {
            return MailStatus(kind: .disconnected, provider: .gmail, text: "Conectar correo")
        }
        if sync.isSyncing {
            return MailStatus(kind: .reading, provider: provider, text: "Leyendo correo…")
        }
        if gmail && GmailAuthService.shared.missingGmailScope && GmailSyncService.qaToken == nil {
            return MailStatus(kind: .attention, provider: provider, text: "Falta el permiso")
        }
        if BankSource.activeCount == 0 {
            return MailStatus(kind: .attention, provider: provider, text: "Sin bancos activos")
        }
        guard let last = sync.lastSyncDate else {
            return MailStatus(kind: .ok, provider: provider, text: provider.name + " · sin leer aún")
        }
        let elapsed = now.timeIntervalSince(last)
        if elapsed > 60 * 60 * 48 {
            let days = Int(elapsed / 86_400)
            return MailStatus(kind: .attention, provider: provider, text: "Leído hace \(days) días")
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = Period.calendar.isDateInToday(last) ? "H:mm" : "'ayer' H:mm"
        return MailStatus(kind: .ok, provider: provider, text: provider.name + " · " + f.string(from: last))
    }
}

/// La tarjeta de estado de Ajustes en una hoja, con «Leer ahora»: se
/// comprueba el correo sin salir de Movimientos.
struct MailStatusSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @StateObject private var gmailAuth = GmailAuthService.shared
    @StateObject private var gmailSync = GmailSyncService.shared
    @StateObject private var outlookAuth = OutlookAuthService.shared
    @State private var expensesThisMonth = 0

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }
    private var isConnected: Bool {
        GmailSyncService.qaToken != nil || gmailAuth.isAuthenticated || outlookAuth.isAuthenticated
    }

    private var status: SettingsStatus {
        let gmailOn = GmailSyncService.qaToken != nil || gmailAuth.isAuthenticated
        return SettingsStatus(
            isConnected: isConnected,
            missingGmailScope: gmailOn && GmailSyncService.qaToken == nil && gmailAuth.missingGmailScope,
            account: [gmailOn ? gmailAuth.accountEmail : nil,
                      outlookAuth.isAuthenticated ? outlookAuth.accountEmail : nil]
                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "Sólo lectura del correo",
            lastSync: gmailSync.lastSyncDate,
            activeBankCount: BankSource.activeCount,
            totalBankCount: BankSource.all.count,
            expensesThisMonth: expensesThisMonth,
            unclassifiedMerchants: 0,
            pendingRecurring: 0
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                        SettingsStatusCard(status: status, accent: accent.color) {
                            gmailAuth.signIn()
                        }
                    }

                    if isConnected { readNow }

                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12.5))
                        Text(footnote)
                            .font(.system(size: 12.5))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(palette.secondaryLabel)
                    .padding(.horizontal, 20)
                }
                .padding(.top, 12)
            }
            .navigationTitle("Correo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
        .onAppear(perform: countThisMonth)
        .onChange(of: gmailSync.isSyncing) { _, syncing in
            if !syncing { countThisMonth() }
        }
    }

    @ViewBuilder
    private var readNow: some View {
        if gmailSync.isSyncing {
            GmailSyncProgress()
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
                .padding(.horizontal, 16)
        } else {
            Button {
                gmailSync.modelContext = modelContext
                gmailSync.syncEmails(force: true)
            } label: {
                Label("Leer ahora", systemImage: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent.buttonText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(accent.buttonFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
        }
    }

    /// Lo que pasó en la última lectura, o qué hace la lista.
    private var footnote: String {
        if let error = gmailSync.lastSyncError { return error }
        if let summary = gmailSync.lastRunSummary { return summary }
        return isConnected
            ? "Lo que llega de tus bancos activos entra solo a esta lista. También puedes jalarla hacia abajo para leer."
            : "AgruPay lee sólo los avisos de tus bancos. Nunca envía ni borra nada."
    }

    private func countThisMonth() {
        let month = Period(granularity: .mes, reference: Date()).interval
        let start = month.start, end = month.end
        expensesThisMonth = (try? modelContext.fetchCount(FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= start && $0.date < end }))) ?? 0
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
