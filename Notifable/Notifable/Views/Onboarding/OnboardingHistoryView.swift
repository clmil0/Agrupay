import SwiftUI
import SwiftData

/// Último paso: desde cuándo leer el correo.
///
/// Se pregunta aquí y no después porque la primera lectura define lo que el
/// usuario ve al abrir la app. Leer un año entero en la primera apertura tarda
/// y llena la pantalla de movimientos viejos; leer un mes deja la app útil en
/// segundos. Que lo elija él evita las dos decepciones.
///
/// "No leer mis correos" también es una respuesta válida: la app sirve igual
/// anotando a mano, y forzar la lectura para poder entrar sería cobrar un
/// peaje que no hace falta.
struct OnboardingHistoryView: View {

    /// `false` cuando entró sin cuenta: entonces esta pantalla ni se presenta,
    /// pero el parámetro deja explícito de qué caso viene.
    let usesGmail: Bool
    /// `monthsLabel` es `nil` cuando eligió no leer nada: quien llama sabe así
    /// si tiene que enseñar la pantalla de progreso o entrar directo.
    let onDone: (_ monthsLabel: String?) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    /// La misma clave que usa Gmail y bancos: lo que elija aquí es lo que verá
    /// por defecto la próxima vez que lea correo.
    @AppStorage("readPeriodMonths") private var readPeriodMonths = 3

    @State private var showsCustom = false
    @State private var isStarting = false
    @State private var showNoReadConfirm = false
    /// Igual que en Gmail y bancos: `BankSource.isEnabled` escribe en
    /// `UserDefaults` y no publica cambios por sí solo, así que la grilla
    /// necesita este caché para redibujarse al tocar una tarjeta.
    @State private var bankStates: [String: Bool] = [:]

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .blue }
    private var palette: Palette { Palette(scheme) }

    private static let standardPeriods = [1, 3, 6, 12]
    /// Gratis, la primera lectura llega hasta 3 meses (lo mismo que Gmail y
    /// bancos): más atrás es «Todo el historial», de Pro.
    private static let freePeriods = [1, 2, 3]

    @AppStorage(ProStore.enabledKey) private var isPro = false
    private var periods: [Int] { isPro ? Self.standardPeriods : Self.freePeriods }
    private var maxMonths: Int { isPro ? 36 : ProStore.freeHistoryMonths }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(accent.color.opacity(0.16))
                        .frame(width: 78, height: 78)
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(accent.onSurface(scheme))
                }
                .padding(.top, 56)

                Text("¿Cuánto correo miramos?")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(palette.label)
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)

                Text("AgruPay leerá los avisos de tu banco desde la fecha que elijas para armar tu historial. Puedes cambiarlo o ampliarlo cuando quieras.")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .padding(.horizontal, 30)

                periodCard
                    .padding(.top, 24)
                    .padding(.horizontal, 20)

                banksCard
                    .padding(.top, 12)
                    .padding(.horizontal, 20)

                buttons
                    .padding(.top, 26)
                    .padding(.bottom, 36)
            }
        }
        .background(palette.background)
        .onAppear {
            loadBankStates()
            // Un valor guardado de antes (6 meses, un año) se baja al límite.
            if readPeriodMonths > maxMonths { readPeriodMonths = maxMonths }
        }
        .confirmationDialog("¿No leer tus correos?", isPresented: $showNoReadConfirm, titleVisibility: .visible) {
            Button("No leer", role: .destructive) { onDone(nil) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("AgruPay entrará vacío y tendrás que anotar tus gastos a mano. Puedes leerlos después en Ajustes → Gmail y bancos.")
        }
    }

    // MARK: - El rango

    private var periodCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DESDE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.tertiaryLabel)

            HStack(spacing: 8) {
                ForEach(periods, id: \.self) { months in
                    chip(label: chipLabel(months),
                         isActive: !showsCustom && readPeriodMonths == months) {
                        showsCustom = false
                        readPeriodMonths = months
                    }
                }
                if isPro {
                    chip(label: "Otro", isActive: showsCustom) { showsCustom = true }
                }
            }

            if showsCustom {
                HStack {
                    Text("Cuánto atrás")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryLabel)
                    Spacer()
                    HStack(spacing: 0) {
                        stepper("minus") { readPeriodMonths = min(maxMonths, readPeriodMonths + 1) }
                        Text("\(readPeriodMonths)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(palette.label)
                            .frame(minWidth: 28)
                        stepper("plus") { readPeriodMonths = max(1, readPeriodMonths - 1) }
                    }
                    .padding(.horizontal, 4)
                    .background(palette.track)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }

            Text(rangeLabel)
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)

            if readPeriodMonths >= 12 {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.tertiaryLabel)
                    Text("Un año tarda un poco más; puedes seguir usando la app mientras lee.")
                        .font(.caption2)
                        .foregroundStyle(palette.tertiaryLabel)
                }
            }
        }
        .padding(16)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.5)
        )
    }

    // MARK: - Qué bancos leemos

    /// Los mismos `BankSource` de Gmail y bancos: lo que se elige aquí es lo
    /// que se lee en el siguiente paso, y lo que queda marcado en Ajustes.
    private var banksCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("QUÉ BANCOS LEEMOS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.tertiaryLabel)
                Spacer()
                Text(banksSummary)
                    .font(.caption2)
                    .foregroundStyle(palette.tertiaryLabel)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                ForEach(BankSource.all) { bank in
                    bankCard(bank)
                }
            }

            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.tertiaryLabel)
                Text("Tarda unos segundos. Puedes ampliarlo después en Ajustes → Gmail y bancos.")
                    .font(.caption2)
                    .foregroundStyle(palette.tertiaryLabel)
            }
        }
        .padding(16)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.5)
        )
    }

    private func bankCard(_ bank: BankSource) -> some View {
        let isOn = bankStates[bank.storageKey] ?? bank.isEnabled

        return Button {
            let newValue = !isOn
            bank.isEnabled = newValue
            bankStates[bank.storageKey] = newValue
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(isOn ? accent.color : .clear)
                        .frame(width: 16, height: 16)
                    Circle()
                        .strokeBorder(isOn ? accent.color : palette.tertiaryLabel.opacity(0.4), lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                Image(bank.logoAsset)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(bank.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(isOn ? accent.color.opacity(0.09) : palette.background)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(isOn ? accent.color : palette.hairline, lineWidth: isOn ? 1 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func loadBankStates() {
        for bank in BankSource.all where bankStates[bank.storageKey] == nil {
            bankStates[bank.storageKey] = bank.isEnabled
        }
    }

    private var banksSummary: String {
        let active = BankSource.all.filter { bankStates[$0.storageKey] ?? $0.isEnabled }.count
        return "\(active) de \(BankSource.all.count)"
    }

    /// Abreviado igual que en Gmail y bancos: cinco opciones tienen que caber
    /// en una fila. El botón de abajo dice el periodo completo.
    private func chipLabel(_ months: Int) -> String {
        if months > 0, months % 12 == 0 { return "\(months / 12) A" }
        return "\(months) M"
    }

    private func periodLabel(_ months: Int) -> String {
        if months == 12 { return "1 año" }
        if months > 0, months % 12 == 0 { return "\(months / 12) años" }
        return months == 1 ? "1 mes" : "\(months) meses"
    }

    private var rangeStartDate: Date {
        GmailSyncService.smartRangeStart(months: readPeriodMonths)
    }

    private var rangeLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "d MMM yyyy"
        return "Desde el \(f.string(from: rangeStartDate)) hasta hoy."
    }

    private func chip(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isActive ? .white : palette.label)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(isActive ? accent.color : palette.track)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func stepper(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(palette.label)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Acciones

    private var buttons: some View {
        VStack(spacing: 12) {
            Button {
                startReading()
            } label: {
                HStack(spacing: 8) {
                    if isStarting { ProgressView().tint(.white) }
                    Text("Leer " + periodLabel(readPeriodMonths))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(accent.color)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isStarting)

            Button("No leer mis correos · empezar de cero") { showNoReadConfirm = true }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.secondaryLabel)
                .disabled(isStarting)
        }
        .padding(.horizontal, 24)
    }

    /// Se lanza la lectura y se entra a la app sin esperarla: el progreso ya se
    /// ve en el Resumen, y quedarse en una pantalla de carga durante un año de
    /// correo sería la peor primera impresión posible.
    /// Lanza la lectura y cede el paso a la pantalla de progreso. Entrar a la
    /// app aquí era el error: SwiftData sigue insertando gastos y el Resumen se
    /// siente trabado — la app no va lenta, se entraba demasiado pronto.
    private func startReading() {
        isStarting = true
        GmailSyncService.shared.modelContext = modelContext
        GmailSyncService.shared.syncEmails(force: true, startDate: rangeStartDate, endDate: Date())
        onDone(periodLabel(readPeriodMonths))
    }
}
