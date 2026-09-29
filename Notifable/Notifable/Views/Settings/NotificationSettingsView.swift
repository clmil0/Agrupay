import SwiftUI
import SwiftData

/// Notificaciones (`4j`): agrupadas por origen —lo que llega del correo y
/// los avisos de la app— y, al final, qué tan fuerte cobras a un amigo.
/// Cada interruptor dice **cuándo** suena, no sólo qué activa.
struct NotificationSettingsView: View {

    @Environment(\.colorScheme) private var scheme
    @Query private var expenses: [Expense]
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    @AppStorage(ProStore.enabledKey) private var isPro = false

    @AppStorage(NotificationSettings.budgetKey) private var notificationsEnabled = true
    @AppStorage(NotificationSettings.recurringKey) private var remindRecurring = true
    @AppStorage(NotificationSettings.debtEnabledKey) private var debtReminderEnabled = true
    @AppStorage(NotificationSettings.debtHourKey) private var debtHour = 10
    @AppStorage(NotificationSettings.debtMinuteKey) private var debtMinute = 0
    @AppStorage(NotificationSettings.debtFrequencyKey) private var debtFrequency = "Diario"
    @AppStorage(NotificationSettings.debtWeekdayKey) private var debtWeekday = 2
    @AppStorage(NotificationSettings.debtMonthDayKey) private var debtMonthDay = 1
    @AppStorage(NotificationSettings.reminderIntensityKey) private var reminderIntensity = PaymentReminder.Intensity.soft.rawValue
    @AppStorage(NotificationManager.categoryLimitEnabledKey) private var limitAlertsEnabled = true
    @AppStorage(NotificationManager.importedEnabledKey) private var importedAlertsEnabled = true

    @State private var paywall: ProStore.Feature?

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    private var intense: Bool { isPro && reminderIntensity == PaymentReminder.Intensity.intense.rawValue }

    var body: some View {
        SettingsPage(title: "Notificaciones") {
            SettingsGroup(title: "Del correo",
                          footer: "Un aviso por cada gasto o ingreso que la app registra de tu correo. Con la app cerrada, el iPhone decide cada cuánto mirar el correo, así que puede tardar unos minutos.") {
                SettingsToggle(icon: "doc.text.fill", tint: Color(hex: 0x40C8E0),
                               title: "Cada pago registrado", isOn: $importedAlertsEnabled)
            }

            SettingsGroup(title: "Avisos",
                          footer: isPro ? nil : "La frecuencia y la hora de los recordatorios de deudas se eligen gratis.") {
                SettingsToggle(icon: "chart.bar.fill", tint: Color(hex: 0x0A84FF), title: "Presupuesto",
                               subtitle: "Cuando pases el 80% de tu meta o el ritmo esperado.",
                               isOn: $notificationsEnabled)
                SettingsDivider()
                SettingsToggle(icon: "tag.fill", tint: Color(hex: 0xFF9F0A), title: "Límites por categoría",
                               subtitle: "Al llegar al umbral de cada categoría y al pasarte de su límite.",
                               isOn: $limitAlertsEnabled)
                SettingsDivider()
                SettingsToggle(icon: "arrow.triangle.2.circlepath", tint: Color(hex: 0x5E5CE6), title: "Gastos recurrentes",
                               subtitle: "El día que hay gastos programados esperando confirmación.",
                               isOn: $remindRecurring)
                SettingsDivider()
                SettingsToggle(icon: "person.2.fill", tint: Color(hex: 0x30D158), title: "Recordatorio de deudas",
                               subtitle: "Lo que te deben y lo que debes a tus amigos",
                               isOn: $debtReminderEnabled)
                if debtReminderEnabled {
                    SettingsDivider()
                    debtSchedule
                }
                SettingsDivider(inset: 14)
                intensityBlock
            }
        }
        .onChange(of: debtReminderEnabled) { _, _ in refresh() }
        .onChange(of: debtFrequency) { _, _ in refresh() }
        .onChange(of: debtWeekday) { _, _ in refresh() }
        .onChange(of: debtMonthDay) { _, _ in refresh() }
        .proPaywall($paywall)
    }

    // MARK: - Deudas

    @ViewBuilder
    private var debtSchedule: some View {
        Menu {
            Picker("Frecuencia", selection: $debtFrequency) {
                ForEach(["Diario", "Semanal", "Mensual"], id: \.self) { Text($0).tag($0) }
            }
        } label: {
            SettingsItem(title: "Frecuencia") { SettingsValueChevron(value: debtFrequency) }
                .padding(.leading, 42)
        }
        .buttonStyle(.plain)

        if debtFrequency == "Semanal" {
            SettingsDivider()
            Menu {
                Picker("Día", selection: $debtWeekday) {
                    ForEach(NotificationSettings.weekdayOrder, id: \.self) { day in
                        Text(NotificationSettings.weekdayName(day)).tag(day)
                    }
                }
            } label: {
                SettingsItem(title: "Día") { SettingsValueChevron(value: NotificationSettings.weekdayName(debtWeekday)) }
                    .padding(.leading, 42)
            }
            .buttonStyle(.plain)
        } else if debtFrequency == "Mensual" {
            SettingsDivider()
            Menu {
                Picker("Día", selection: $debtMonthDay) {
                    ForEach(1...28, id: \.self) { Text("Día \($0)").tag($0) }
                }
            } label: {
                SettingsItem(title: "Día") { SettingsValueChevron(value: "Día \(debtMonthDay)") }
                    .padding(.leading, 42)
            }
            .buttonStyle(.plain)
        }

        SettingsDivider()
        SettingsItem(title: "Hora") {
            // Sólo hora y minuto: guardar un `timeIntervalSince1970` completo
            // dejaba el recordatorio anclado al día en que se configuró.
            DatePicker("Hora", selection: timeBinding, displayedComponents: .hourAndMinute)
                .labelsHidden()
        }
        .padding(.leading, 42)
    }

    // MARK: - Al cobrarle a un amigo

    private var intensityBlock: some View {
        VStack(spacing: 0) {
            Text("AL COBRARLE A UN AMIGO")
                .font(.caption2.weight(.semibold))
                .tracking(0.3)
                .foregroundStyle(palette.secondaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 2)
            SettingsChoice(title: "Normal", subtitle: "Aviso con la animación de siempre", selected: !intense) {
                reminderIntensity = PaymentReminder.Intensity.soft.rawValue
            }
            SettingsDivider(inset: 14)
            SettingsChoice(title: "Intensa", subtitle: "Una animación más llamativa en su pantalla",
                           pro: !isPro, selected: intense, opensMore: !isPro) {
                if isPro {
                    reminderIntensity = PaymentReminder.Intensity.intense.rawValue
                } else {
                    paywall = .alerts
                }
            }
        }
    }

    /// El `DatePicker` necesita una `Date`; se compone y se descompone en el
    /// momento, y lo que se guarda son dos enteros.
    private var timeBinding: Binding<Date> {
        Binding(
            get: { NotificationSettings.date(hour: debtHour, minute: debtMinute) },
            set: { newValue in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                debtHour = comps.hour ?? 10
                debtMinute = comps.minute ?? 0
                refresh()
            }
        )
    }

    private func refresh() {
        let hasDebts = expenses.contains { $0.isDebt }
        NotificationManager.shared.updateDebtNotification(hasDebts: hasDebts && debtReminderEnabled)
    }
}

/// Claves y formato del bloque de notificaciones, en un solo sitio para que la
/// pantalla y `NotificationManager` no interpreten lo mismo de dos maneras.
enum NotificationSettings {

    static let budgetKey = "notificationsEnabled"
    static let recurringKey = "remindRecurring"
    static let debtEnabledKey = "debtReminderEnabled"
    static let debtHourKey = "debtReminderHour"
    static let debtMinuteKey = "debtReminderMinute"
    static let debtFrequencyKey = "debtNotificationFrequency"
    /// `Calendar` (1 = domingo … 7 = sábado), para la frecuencia semanal.
    static let debtWeekdayKey = "debtReminderWeekday"
    /// Día del mes (1–28), para la frecuencia mensual.
    static let debtMonthDayKey = "debtReminderMonthDay"
    /// Con qué intensidad sale un cobro nuevo: `PaymentReminder.Intensity`.
    /// «Intensa» pide Pro; sin Pro se usa siempre la normal.
    static let reminderIntensityKey = "reminderDefaultIntensity"

    /// Lunes primero, como se lee la semana en Perú.
    static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    static func weekdayName(_ weekday: Int) -> String {
        let names = ["Domingo", "Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado"]
        return names[(max(1, min(7, weekday)) - 1)]
    }

    static func weekday(_ defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: debtWeekdayKey) as? Int ?? 2
    }

    static func monthDay(_ defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: debtMonthDayKey) as? Int ?? 1
    }

    /// La intensidad con la que arranca un cobro nuevo, ya filtrada por Pro.
    static var defaultIntensity: PaymentReminder.Intensity {
        guard ProStore.isPro,
              let raw = UserDefaults.standard.string(forKey: reminderIntensityKey),
              let value = PaymentReminder.Intensity(rawValue: raw) else { return .soft }
        return value
    }

    /// Migración del `timeIntervalSince1970` anterior: se conserva la hora que
    /// el usuario había elegido y se descarta la fecha, que era el problema.
    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: debtHourKey) == nil else { return }
        let legacy = defaults.double(forKey: "debtNotificationTimeInterval")
        let date = legacy > 0 ? Date(timeIntervalSince1970: legacy) : nil
        let comps = date.map { Calendar.current.dateComponents([.hour, .minute], from: $0) }
        defaults.set(comps?.hour ?? 10, forKey: debtHourKey)
        defaults.set(comps?.minute ?? 0, forKey: debtMinuteKey)
        defaults.removeObject(forKey: "debtNotificationTimeInterval")
    }

    static func hour(_ defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: debtHourKey) as? Int ?? 10
    }

    static func minute(_ defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: debtMinuteKey) as? Int ?? 0
    }

    static func date(hour: Int, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    static func timeLabel(hour: Int, minute: Int) -> String {
        String(format: "%d:%02d", hour, minute)
    }

    /// Cuántos avisos hay encendidos, para la fila de la raíz.
    static func activeCount(_ defaults: UserDefaults = .standard) -> Int {
        var count = 0
        if defaults.object(forKey: budgetKey) as? Bool ?? true { count += 1 }
        if defaults.object(forKey: recurringKey) as? Bool ?? true { count += 1 }
        if defaults.object(forKey: debtEnabledKey) as? Bool ?? true { count += 1 }
        if defaults.object(forKey: NotificationManager.categoryLimitEnabledKey) as? Bool ?? true { count += 1 }
        if defaults.object(forKey: NotificationManager.importedEnabledKey) as? Bool ?? true { count += 1 }
        return count
    }
}
