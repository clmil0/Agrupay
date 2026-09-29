import SwiftUI

/// Configuración › Correo (`4b`): qué cuenta de Gmail lee la app, cuándo leyó
/// por última vez y qué hacer con el acceso. Los bancos y el periodo viven
/// en Gmail y bancos.
struct EmailSettingsView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @StateObject private var gmailAuth = GmailAuthService.shared
    @StateObject private var gmailSync = GmailSyncService.shared

    @State private var showUnlinkDialog = false
    @State private var showSwitchDialog = false
    @State private var showRecoveryAlert = false

    private var palette: Palette { Palette(scheme) }
    private var connected: Bool { gmailAuth.isAuthenticated && !gmailAuth.missingGmailScope }

    var body: some View {
        SettingsPage(title: "Correo") {
            if connected {
                accountCard
                readingSection
                accessSection
                SettingsGroup(footer: "Tus movimientos se quedan en el teléfono. Sólo se detiene la lectura automática.") {
                    SettingsAction(title: "Desvincular Gmail", destructive: true) { showUnlinkDialog = true }
                }
            } else {
                GmailConnectCard()
            }
        }
        .confirmationDialog("¿Desvincular Gmail?", isPresented: $showUnlinkDialog, titleVisibility: .visible) {
            Button("Desvincular", role: .destructive) { gmailAuth.signOut() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Los gastos ya registrados se conservan. Dejarán de entrar nuevos.")
        }
        .confirmationDialog("¿Cambiar de cuenta?", isPresented: $showSwitchDialog, titleVisibility: .visible) {
            Button("Elegir otra cuenta") {
                gmailAuth.signOut()
                gmailAuth.signIn()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se desvincula esta cuenta y Google te pide la nueva. Lo ya registrado se conserva.")
        }
        .gmailRecoveryAlert(isPresented: $showRecoveryAlert) { startSync() }
    }

    private var accountCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.positive)
                .frame(width: 40, height: 40)
                .background(palette.positive.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                // La cuenta concreta: quien tiene varias quiere saber cuál
                // está leyendo la app.
                Text(gmailAuth.accountEmail ?? "Gmail vinculado")
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

    private var readingSection: some View {
        SettingsGroup(title: "Lectura", footer: "AgruPay lee sólo los correos de tus bancos. Nunca envía ni borra nada.") {
            if gmailSync.isSyncing {
                GmailSyncProgress()
            } else {
                SettingsItem(title: "Última lectura") {
                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                        Text(GmailLookback.lastSyncLabel(gmailSync.lastSyncDate))
                            .foregroundStyle(palette.secondaryLabel)
                    }
                }
                SettingsDivider(inset: 14)
                SettingsAction(title: "Leer ahora") {
                    gmailSync.modelContext = modelContext
                    if !DeletedEmails.undecided().isEmpty { showRecoveryAlert = true } else { startSync() }
                }
            }
        }
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

    private func startSync() {
        gmailSync.syncEmails(force: true, startDate: GmailLookback.startDate, endDate: Date())
    }
}
