import SwiftUI
import SwiftData

/// Leer un rango de fechas (`4g` › Cuánto atrás). Gratis llega hasta 3 meses
/// atrás; con Pro, hasta el primer correo del banco.
struct RangeSyncView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false

    @StateObject private var gmailSync = GmailSyncService.shared
    @AppStorage(ProStore.enabledKey) private var isPro = false
    @State private var paywall: ProStore.Feature?

    @State private var startDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var endDate: Date = Date()
    @State private var showRecoveryAlert = false

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    private var palette: Palette { Palette(scheme) }

    /// Dice exactamente qué va a pasar antes de tocar el botón.
    private var explanation: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "d MMM"
        let range = f.string(from: startDate) + " – " + f.string(from: endDate)
        var text = "Se revisa " + range + " completo. Los gastos que ya tienes no se duplican; sólo se añade lo que falte."
        if !GmailSyncService.reachesNow(endDate) {
            text += " La sincronización automática seguirá cubriendo desde ahí hasta hoy."
        }
        return text
    }

    var body: some View {
        Form {
            if gmailSync.isSyncing {
                Section {
                    HStack {
                        ProgressView().padding(.trailing, 8)
                        Text("Leyendo… (\(gmailSync.emailsProcessed)/\(gmailSync.totalEmailsToProcess))")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    DatePicker("Desde", selection: $startDate,
                               in: GmailLookback.earliestRangeStart...endDate, displayedComponents: .date)
                    DatePicker("Hasta", selection: $endDate,
                               in: startDate...Date(), displayedComponents: .date)
                } footer: {
                    Text(explanation)
                }

                if !isPro {
                    Section {
                        Button {
                            paywall = .history
                        } label: {
                            HStack(spacing: 8) {
                                Text("Leer más atrás de 3 meses")
                                    .foregroundStyle(accent.onSurface(scheme))
                                ProBadge()
                            }
                        }
                    }
                }

                if let error = gmailSync.lastSyncError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } else if let summary = gmailSync.lastRunSummary {
                    Section {
                        Label(summary, systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        gmailSync.modelContext = modelContext
                        if !DeletedEmails.undecided().isEmpty {
                            showRecoveryAlert = true
                        } else {
                            gmailSync.syncEmails(force: true, startDate: startDate, endDate: endDate)
                        }
                    } label: {
                        Label("Leer este rango", systemImage: "envelope.arrow.triangle.branch")
                            .foregroundStyle(accent.onSurface(scheme))
                    }
                }
            }
        }
        .onAppear {
            // Gratis no puede empezar antes de 3 meses atrás; si venía una
            // fecha más vieja (se quitó Pro), se sube al límite.
            if startDate < GmailLookback.earliestRangeStart { startDate = GmailLookback.earliestRangeStart }
            // El resumen es de la última lectura, que pudo ser hace rato y con
            // otros datos («3 ya estaban» después de borrar esos 3 confunde).
            if !gmailSync.isSyncing { gmailSync.lastRunSummary = nil }
        }
        .navigationTitle("Un rango de fechas")
        .navigationBarTitleDisplayMode(.inline)
        .gmailRecoveryAlert(isPresented: $showRecoveryAlert) {
            gmailSync.syncEmails(force: true, startDate: startDate, endDate: endDate)
        }
        .proPaywall($paywall)
    }
}
