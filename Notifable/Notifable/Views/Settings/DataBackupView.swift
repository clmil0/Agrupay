import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Datos y respaldo (`4l`): lo que hay en el teléfono, el respaldo en archivo
/// (gratis), la nube (Pro), el diagnóstico y borrar.
///
/// El respaldo en archivo y la nube guardan lo mismo: ajustes, categorías,
/// reglas, atajos, recurrentes y lo anotado a mano. Los gastos del correo no
/// viajan en ninguno de los dos: se vuelven a leer solos.
struct DataBackupView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @AppStorage(ProStore.enabledKey) private var isPro = false

    @StateObject private var gmailSync = GmailSyncService.shared
    @State private var syncManager = ConfigBackupManager.shared
    @State private var counts = (movements: 0, categories: 0, rules: 0)
    @State private var paywall: ProStore.Feature?

    @State private var exportDocument: ExportDocument?
    @State private var showsExporter = false
    @State private var showsImporter = false
    @State private var outcome: String?

    private var palette: Palette { Palette(scheme) }

    var body: some View {
        SettingsPage(title: "Datos y respaldo") {
            inventory

            SettingsGroup(title: "Respaldo", footer: outcome) {
                SettingsButton(icon: "square.and.arrow.down.fill", tint: Color(white: 0.4),
                               title: "Guardar un respaldo", subtitle: "Archivo en Archivos o iCloud Drive") {
                    guard let data = syncManager.fileBackupData() else {
                        outcome = "No se pudo armar el respaldo. Inténtalo de nuevo."
                        return
                    }
                    exportDocument = ExportDocument(data: data, type: .json,
                                                    filename: "AgruPay respaldo " + Self.fileDate())
                    showsExporter = true
                }
                SettingsDivider()
                SettingsButton(icon: "clock.arrow.circlepath", tint: Color(white: 0.4),
                               title: "Restaurar desde archivo") { showsImporter = true }
                SettingsDivider()
                SettingsButton(icon: "tablecells.fill", tint: Color(white: 0.4), title: "Exportar a CSV") {
                    exportDocument = ExportDocument(data: csvData(), type: .commaSeparatedText,
                                                    filename: "AgruPay movimientos " + Self.fileDate())
                    showsExporter = true
                }
            }

            SettingsGroup(title: "En la nube") {
                if isPro {
                    SettingsLink(icon: "icloud.and.arrow.up.fill", tint: Color(hex: 0x40C8E0),
                                 title: "Respaldo automático", subtitle: cloudSubtitle) {
                        ConfigBackupView()
                    }
                } else {
                    SettingsButton(icon: "icloud.and.arrow.up.fill", tint: Color(hex: 0x40C8E0),
                                   title: "Respaldo automático",
                                   subtitle: syncManager.isEnabled
                                    ? "En pausa: tu copia sigue en la nube y se retoma con Pro"
                                    : "Preferencias, categorías y reglas, cada día",
                                   pro: true) { paywall = .cloud }
                }
            }

            SettingsGroup(title: "Ayuda") {
                SettingsLink(icon: "stethoscope", tint: Color(white: 0.4), title: "Diagnóstico",
                             subtitle: "Para enviar un informe si algo falla") {
                    DiagnosticsView()
                }
            }

            SettingsGroup(footer: "Elige qué borrar por grupos o por fechas.", destructive: true) {
                NavigationLink {
                    DeleteDataView()
                } label: {
                    HStack {
                        Text("Borrar datos").foregroundStyle(palette.negative)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            debugSection
        }
        .onAppear(perform: refreshCounts)
        .fileExporter(isPresented: $showsExporter, document: exportDocument,
                      contentType: exportDocument?.type ?? .json,
                      defaultFilename: exportDocument?.filename) { result in
            if case .failure(let error) = result { outcome = "No se pudo guardar: \(error.localizedDescription)" }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json]) { result in
            restore(result)
        }
        .proPaywall($paywall)
        .sheet(isPresented: $gmailSync.showDiagnostic) {
            NavigationStack {
                ScrollView {
                    Text(gmailSync.diagnosticResult)
                        .padding()
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .navigationTitle("Diagnóstico")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cerrar") { gmailSync.showDiagnostic = false }
                    }
                }
            }
        }
    }

    // MARK: - En este dispositivo

    /// El contexto que hace comprensible el resto: sin saber cuánto hay,
    /// «borrar» o «respaldar» no significan nada.
    private var inventory: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EN ESTE DISPOSITIVO")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(palette.secondaryLabel)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                stat(counts.movements, "movimientos")
                stat(counts.categories, "categorías")
                stat(counts.rules, "reglas")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
        .padding(.horizontal, 16)
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.system(size: 20, weight: .bold).monospacedDigit())
                .foregroundStyle(palette.label)
            Text(label)
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refreshCounts() {
        let movements = ((try? modelContext.fetchCount(FetchDescriptor<Expense>())) ?? 0)
            + ((try? modelContext.fetchCount(FetchDescriptor<Income>())) ?? 0)
        var all = FetchDescriptor<Expense>()
        all.propertiesToFetch = [\.category]
        let categories = Set(((try? modelContext.fetch(all)) ?? []).map(\.category))
            .union(CategoryCatalog.shared.entries.keys)
            .subtracting([Accounting.unclassified]).count
        counts = (movements, categories, MerchantRules.all().count)
    }

    // MARK: - Nube

    private var cloudSubtitle: String {
        if let error = syncManager.lastErrorMessage { return error }
        if syncManager.isSyncing { return "Sincronizando…" }
        guard syncManager.isEnabled else {
            return syncManager.isPausedAfterWipe ? "En pausa" : "Preferencias, categorías y reglas, cada día"
        }
        guard let last = syncManager.lastSyncedAt else { return "Activado" }
        return "Activado · " + Self.relative.localizedString(for: last, relativeTo: Date())
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_PE")
        f.unitsStyle = .short
        return f
    }()

    // MARK: - Archivos

    private static func fileDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func restore(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            outcome = "No se pudo abrir el archivo: \(error.localizedDescription)"
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                outcome = "No se pudo leer el archivo."
                return
            }
            if let error = syncManager.restoreFromFile(data) {
                outcome = error
            } else {
                outcome = "Listo: se restauró tu configuración. Tus movimientos del correo no se tocaron."
                refreshCounts()
            }
        }
    }

    /// Todos los movimientos, del más nuevo al más viejo.
    private func csvData() -> Data {
        let expenses = (try? modelContext.fetch(FetchDescriptor<Expense>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        let incomes = (try? modelContext.fetch(FetchDescriptor<Income>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        func field(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        func amount(_ value: Double) -> String { String(format: "%.2f", value) }

        var rows = ["Fecha,Tipo,Comercio,Categoría,Monto,Moneda,Banco,Notas"]
        for e in expenses {
            rows.append([f.string(from: e.date), "Gasto", field(Accounting.displayName(e.merchant)),
                         field(e.category), amount(e.amount), e.currency,
                         field(e.sourceBank ?? ""), field(e.notes ?? "")].joined(separator: ","))
        }
        for i in incomes {
            rows.append([f.string(from: i.date), "Ingreso", field(i.source), field("Ingreso"),
                         amount(i.amount), i.currency, field(""), field(i.notes ?? "")].joined(separator: ","))
        }
        // BOM para que Excel abra bien las tildes.
        return Data(("\u{FEFF}" + rows.joined(separator: "\n")).utf8)
    }

    // MARK: - Debug

    @ViewBuilder
    private var debugSection: some View {
        #if DEBUG
        SettingsGroup(title: "Debug") {
            SettingsToggle(title: "Pro (QA)", subtitle: "Cambia entre Gratis y Pro sin pasar por el paywall",
                           isOn: Binding(get: { isPro }, set: { $0 ? ProStore.startTrial(plan: .anual) : ProStore.cancel() }))
            SettingsDivider(inset: 14)
            SettingsButton(title: "Diagnóstico BBVA Pago", chevron: false) { gmailSync.diagnosticBBVA() }
            SettingsDivider(inset: 14)
            SettingsButton(title: "Diagnóstico BBVA Transf", chevron: false) { gmailSync.diagnosticBBVATransfer() }
            SettingsDivider(inset: 14)
            SettingsButton(title: "Diagnóstico Apple", chevron: false) { gmailSync.diagnosticApple() }
            SettingsDivider(inset: 14)
            SettingsButton(title: "Añadir gasto de prueba", chevron: false, action: addRandomExpense)
        }
        #endif
    }

    #if DEBUG
    private func addRandomExpense() {
        let options = [
            ("Apple Store", "Entretenimiento"),
            ("Starbucks", "Comida"),
            ("Uber", "Transporte"),
            ("Wong", "Supermercado"),
            ("Netflix", "Entretenimiento"),
            ("Oxxo 123", Accounting.unclassified)
        ]
        let selected = options.randomElement()!
        let days = Int.random(in: 0...20)
        let date = Period.calendar.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        let expense = Expense(
            amount: Double.random(in: 10.0...150.0),
            merchant: selected.0,
            date: date,
            category: selected.1,
            isSubscription: selected.0 == "Netflix"
        )
        modelContext.insert(expense)
        try? modelContext.save()
        refreshCounts()
    }
    #endif
}

/// Un archivo ya armado para `fileExporter`: el respaldo (JSON) o el CSV.
struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }

    let data: Data
    var type: UTType = .json
    var filename: String = "AgruPay"

    init(data: Data, type: UTType, filename: String) {
        self.data = data
        self.type = type
        self.filename = filename
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
