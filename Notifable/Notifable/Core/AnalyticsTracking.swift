import SwiftUI
import SwiftData
import UserNotifications
import WidgetKit
import MetricKit
import Darwin

// MARK: - Catálogo de eventos

/// Todos los eventos que manda la app. El catálogo con sus propiedades está
/// en `supabase/ANALYTICS.md`; si se añade uno aquí, se documenta allá.
enum AnalyticsEvent: String {
    // Uso
    case appOpen = "app_open"
    case screenView = "screen_view"
    case tap
    case tabSelect = "tab_select"
    case sectionSelect = "section_select"
    case periodChange = "period_change"
    case chartMode = "chart_mode"
    case featureUsed = "feature_used"
    case featureFirstUse = "feature_first_use"
    // Motor de correo
    case emailParse = "email_parse"
    case emailSyncRun = "email_sync_run"
    case accountConnectStarted = "account_connect_started"
    case accountConnected = "account_connected"
    case accountConnectFailed = "account_connect_failed"
    case accountDisconnected = "account_disconnected"
    case rangeSync = "range_sync"
    // Clasificación
    case movementCreated = "movement_created"
    case movementClassified = "movement_classified"
    case movementUnclassified = "movement_unclassified"
    case classificationCorrected = "classification_corrected"
    case suggestionShown = "suggestion_shown"
    case suggestionAccepted = "suggestion_accepted"
    case suggestionDismissed = "suggestion_dismissed"
    case ruleCreated = "rule_created"
    // Activación y retención
    case onboardingStep = "onboarding_step"
    case onboardingCompleted = "onboarding_completed"
    case milestone
    case notificationSent = "notification_sent"
    case notificationOpened = "notification_opened"
    case dailySnapshot = "daily_snapshot"
    // Pro
    case paywallShown = "paywall_shown"
    case paywallDismissed = "paywall_dismissed"
    case proTrialStarted = "pro_trial_started"
    case proCancelled = "pro_cancelled"
    case proFeatureUsed = "pro_feature_used"
    case themeChanged = "theme_changed"
    // Calidad
    case perfLaunch = "perf_launch"
    case perfScreen = "perf_screen"
    case mainHang = "main_hang"
    case metrickitDiagnostic = "metrickit_diagnostic"
    case metrickitMetrics = "metrickit_metrics"
    case appError = "app_error"
    case unlockResult = "unlock_result"
}

extension Analytics {
    static func track(_ event: AnalyticsEvent, _ props: [String: Any] = [:]) {
        track(event.rawValue, props)
    }

    /// Un toque en algo concreto: `target` con puntos, «dashboard.eye».
    static func tap(_ target: String, _ props: [String: Any] = [:]) {
        var all = props
        all["target"] = target
        track(.tap, all)
    }

    /// Un error que el usuario ve o que rompe algo. Sólo dominio y código:
    /// nunca el mensaje, que puede traer un correo o un nombre. El mismo error
    /// sale como mucho cada diez minutos: sin red, el sondeo de cada 10 s lo
    /// repetiría sin parar.
    static func error(_ domain: String, code: String, _ props: [String: Any] = [:]) {
        let key = domain + "|" + code + "|" + (props.map { "\($0.key)=\($0.value)" }.sorted().joined())
        let now = Date()
        let throttled: Bool = errorLock.withLock {
            if let last = lastErrors[key], now.timeIntervalSince(last) < 600 { return true }
            lastErrors[key] = now
            return false
        }
        guard !throttled else { return }
        var all = props
        all["domain"] = domain
        all["code"] = code
        track(.appError, all)
    }

    /// El nombre de una categoría sólo si es de fábrica: una propia puede ser
    /// «Regalo para Ana».
    static func categoryLabel(_ name: String) -> String {
        if name == Accounting.unclassified { return "sin_clasificar" }
        return BuiltInCategories.contains(name) ? name : "personalizada"
    }
}

private let errorLock = NSLock()
nonisolated(unsafe) private var lastErrors: [String: Date] = [:]

// MARK: - Tiempo por pantalla

/// Cuánto rato se pasa en cada pantalla. Una pila: lo de abajo es la pestaña
/// (`setRoot`) y encima se apilan hojas y detalles (`.trackScreen`). Sólo
/// corre el reloj de la de arriba, así el tiempo no se cuenta dos veces.
///
/// Cada pantalla manda un `screen_view` con sus segundos al cerrarse. Al ir
/// a segundo plano se manda lo que lleva la de arriba (con `cont` en las
/// siguientes partes): una app que iOS mata en segundo plano no pierde nada.
@MainActor
final class ScreenTracker {
    static let shared = ScreenTracker()

    private struct Entry {
        let id: UUID
        let name: String
        var seconds: TimeInterval = 0
        var since: Date?
        var continued = false
    }

    private var stack: [Entry] = []
    private var rootID: UUID?
    private var isForeground = true

    func setRoot(_ name: String) {
        if let rootID, let index = stack.firstIndex(where: { $0.id == rootID }) {
            guard stack[index].name != name else { return }
            close(at: index)
        }
        let id = UUID()
        rootID = id
        let entry = Entry(id: id, name: name)
        stack.insert(entry, at: 0)
        if stack.count == 1 { resumeTop() }
    }

    func begin(_ name: String) -> UUID {
        pauseTop()
        let entry = Entry(id: UUID(), name: name)
        stack.append(entry)
        resumeTop()
        return entry.id
    }

    func end(_ id: UUID) {
        guard let index = stack.firstIndex(where: { $0.id == id }) else { return }
        let wasTop = index == stack.count - 1
        close(at: index)
        if wasTop { resumeTop() }
    }

    func appDidEnterBackground() {
        guard isForeground else { return }
        isForeground = false
        pauseTop()
        guard let top = stack.indices.last else { return }
        send(stack[top])
        stack[top].seconds = 0
        stack[top].continued = true
    }

    func appDidBecomeActive() {
        guard !isForeground else { return }
        isForeground = true
        resumeTop()
    }

    private func close(at index: Int) {
        var entry = stack.remove(at: index)
        if let since = entry.since { entry.seconds += Date().timeIntervalSince(since) }
        if entry.id == rootID { rootID = nil }
        send(entry)
    }

    private func pauseTop() {
        guard let top = stack.indices.last, let since = stack[top].since else { return }
        stack[top].seconds += Date().timeIntervalSince(since)
        stack[top].since = nil
    }

    private func resumeTop() {
        guard isForeground, let top = stack.indices.last, stack[top].since == nil else { return }
        stack[top].since = Date()
    }

    private func send(_ entry: Entry) {
        // Un parpadeo (una hoja que se abre y se cierra sola) no es una visita.
        guard entry.seconds >= 0.3 else { return }
        Analytics.track(.screenView, ["screen": entry.name,
                                      "seconds": (entry.seconds * 10).rounded() / 10,
                                      "cont": entry.continued])
    }
}

private struct ScreenTracking: ViewModifier {
    let name: String
    let feature: AppFeature?
    @State private var token: UUID?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard token == nil else { return }
                token = ScreenTracker.shared.begin(name)
                if let feature { Analytics.featureUsed(feature) }
            }
            .onDisappear {
                guard let token else { return }
                ScreenTracker.shared.end(token)
                self.token = nil
            }
    }
}

extension View {
    /// Cuenta esta hoja o detalle como pantalla (`screen_view`) y, si se
    /// pasa, como uso de una función (`feature_used`).
    func trackScreen(_ name: String, feature: AppFeature? = nil) -> some View {
        modifier(ScreenTracking(name: name, feature: feature))
    }
}

// MARK: - De dónde se abre la app

/// `app_open` con su origen: ícono, notificación, widget, enlace o Siri. Quien
/// abre la app por un camino concreto lo anota (`note`) y la apertura se manda
/// un momento después de volver al frente, cuando ya llegaron esos avisos.
@MainActor
enum AppOpenTracker {
    private static var hint: String?
    private static var extra: [String: Any] = [:]
    private static var didLaunch = false
    private static var pending: DispatchWorkItem?

    static func note(_ source: String, _ props: [String: Any] = [:]) {
        // La notificación manda sobre el enlace que ella misma abre.
        if hint == "notification", source == "link" { return }
        hint = source
        extra = props
    }

    /// Desde `NotifableApp` al volver al frente. Volver de un diálogo del
    /// sistema o del Centro de Control no es una apertura.
    static func appDidBecomeActive(fromBackground: Bool) {
        guard fromBackground || !didLaunch else { return }
        let cold = !didLaunch
        didLaunch = true
        pending?.cancel()
        let work = DispatchWorkItem {
            var props = extra
            props["source"] = hint ?? "icon"
            props["cold"] = cold
            props["hour"] = Calendar.current.component(.hour, from: Date())
            Analytics.track(.appOpen, props)
            hint = nil
            extra = [:]
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

// MARK: - Funciones descubiertas

/// Funciones escondidas tras un gesto o un menú: ¿cuánta gente llega a ellas?
/// Cada uso manda `feature_used`; el primero, además, `feature_first_use`.
enum AppFeature: String {
    case dictation
    case micHold = "mic_hold"
    case hideAmounts = "hide_amounts"
    case pendingInbox = "pending_inbox"
    case split
    case assistant
    case bulkClassify = "bulk_classify"
    case tags
    case categories
    case categoryDetail = "category_detail"
    case analysis
    case recurring
    case categoryLimit = "category_limit"
    case rangeSync = "range_sync"
    case friends
    case receivables
    case paymentReminder = "payment_reminder"
    case invite
    case export
    case appLock = "app_lock"
    case proTheme = "pro_theme"
    case statSheet = "stat_sheet"
    case accountFilter = "account_filter"
    case longPressMovement = "long_press_movement"
    case widget
    case siri
}

extension Analytics {
    static func featureUsed(_ feature: AppFeature, _ props: [String: Any] = [:]) {
        var all = props
        all["feature"] = feature.rawValue
        track(.featureUsed, all)
        trackOnce("feature." + feature.rawValue, AnalyticsEvent.featureFirstUse.rawValue,
                  ["feature": feature.rawValue, "days_since_install": daysSinceInstall])
    }

    /// Algo que sólo da Pro y se está usando: una vez al día por función.
    static func proFeatureUsed(_ feature: ProStore.Feature) {
        guard ProStore.isPro else { return }
        trackDaily("pro." + feature.rawValue, AnalyticsEvent.proFeatureUsed.rawValue,
                   ["feature": feature.rawValue])
    }
}

// MARK: - Hitos de activación

enum Milestone: String {
    case firstMovement = "first_movement"
    case firstEmailMovement = "first_email_movement"
    case firstClassification = "first_classification"
    case firstRule = "first_rule"
    case firstFriend = "first_friend"
}

extension Analytics {
    /// Una vez por instalación, con las horas desde que se instaló.
    static func milestone(_ milestone: Milestone) {
        trackOnce("milestone." + milestone.rawValue, AnalyticsEvent.milestone.rawValue,
                  ["name": milestone.rawValue, "hours_since_install": hoursSinceInstall])
    }
}

// MARK: - Clasificación

/// Desde dónde se clasificó a mano.
enum ClassificationVia: String {
    /// La hoja de categoría de un solo gasto (detalle o pulsación larga).
    case detail
    /// «¿Es Comida? Sí» en Pendientes.
    case pendingSuggestion = "pending_suggestion"
    /// «Otra» en Pendientes: la hoja con la lista.
    case pendingSheet = "pending_sheet"
    /// Clasificar en bloque, eligiendo la categoría.
    case bulk
    /// Clasificar en bloque aceptando las sugerencias.
    case bulkSuggestions = "bulk_suggestions"
    /// Una selección en Movimientos o en una categoría.
    case selection
    case assistant
}

/// Quién puso la categoría de un gasto que nadie tocó todavía: la regla del
/// comercio, las palabras clave del lector de correo, la voz o una
/// recurrente. Si luego el usuario la cambia, es una **corrección** de ese
/// motor (`classification_corrected`) y con eso se mide su precisión real.
///
/// Vive aparte del modelo para no migrar SwiftData: un diccionario
/// `id → motor|día` acotado a `capacity`, que pierde lo más viejo.
enum ClassificationLedger {
    enum Engine: String {
        case rule
        case keyword
        case voice
        case recurring
    }

    private static let key = "analyticsAutoClassified"
    private static let capacity = 4000
    private static let lock = NSLock()
    /// En memoria y guardado un momento después: leer seis meses de correo
    /// son cientos de anotaciones seguidas.
    nonisolated(unsafe) private static var map: [String: String]?
    nonisolated(unsafe) private static var saveScheduled = false

    static func record(_ id: UUID, engine: Engine) {
        lock.withLock {
            var current = loaded()
            current[id.uuidString] = engine.rawValue + "|" + String(Int(Date().timeIntervalSince1970 / 86_400))
            if current.count > capacity {
                let sorted = current.sorted { day(of: $0.value) < day(of: $1.value) }
                for (old, _) in sorted.prefix(current.count - capacity) { current.removeValue(forKey: old) }
            }
            map = current
            scheduleSave()
        }
    }

    /// El motor que la puso, sin borrarlo.
    static func peek(_ id: UUID) -> Engine? {
        lock.withLock { engine(in: loaded()[id.uuidString]) }
    }

    /// El motor que la puso, y la entrada se borra: desde ahora la categoría
    /// es del usuario.
    static func take(_ id: UUID) -> Engine? {
        lock.withLock {
            var current = loaded()
            guard let value = current.removeValue(forKey: id.uuidString) else { return nil }
            map = current
            scheduleSave()
            return engine(in: value)
        }
    }

    /// Sólo con `lock` tomado.
    private static func loaded() -> [String: String] {
        if let map { return map }
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        map = stored
        return stored
    }

    /// Sólo con `lock` tomado.
    private static func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            let snapshot: [String: String]? = lock.withLock {
                saveScheduled = false
                return map
            }
            if let snapshot { UserDefaults.standard.set(snapshot, forKey: key) }
        }
    }

    private static func engine(in value: String?) -> Engine? {
        value?.split(separator: "|").first.flatMap { Engine(rawValue: String($0)) }
    }

    private static func day(of value: String) -> Int {
        Int(value.split(separator: "|").last ?? "") ?? 0
    }
}

extension Analytics {

    /// Un cambio de categoría hecho por el usuario. `changes` lleva la
    /// categoría que tenía cada gasto **antes**.
    ///
    /// Manda `movement_classified` (lo que salió de Pendientes y lo que se
    /// reclasificó) y un `classification_corrected` por cada motor automático
    /// al que se le enmendó la plana.
    static func classified(_ changes: [(id: UUID, from: String)], to category: String,
                           via: ClassificationVia, ruleCreated: Bool = false) {
        guard isEnabled else { return }
        var fromPending = 0
        var reclassified = 0
        var corrected: [ClassificationLedger.Engine: Int] = [:]
        for change in changes {
            let engine = ClassificationLedger.take(change.id)
            guard change.from != category else { continue }
            if change.from == Accounting.unclassified {
                fromPending += 1
            } else {
                reclassified += 1
                if let engine { corrected[engine, default: 0] += 1 }
            }
        }
        guard fromPending + reclassified > 0 else { return }
        track(.movementClassified, ["via": via.rawValue,
                                    "category": categoryLabel(category),
                                    "count": fromPending + reclassified,
                                    "from_pending": fromPending,
                                    "reclassified": reclassified,
                                    "rule_created": ruleCreated])
        for (engine, count) in corrected {
            track(.classificationCorrected, ["engine": engine.rawValue, "count": count,
                                             "via": via.rawValue, "category": categoryLabel(category)])
        }
        if fromPending > 0 { milestone(.firstClassification) }
    }

    static func ruleCreated(origin: String, count: Int = 1) {
        guard count > 0 else { return }
        track(.ruleCreated, ["origin": origin, "count": count])
        milestone(.firstRule)
    }

    /// Cuán segura era una sugerencia y de dónde salió, sin el comercio.
    static func suggestionProps(_ hint: CategorySuggestion) -> [String: Any] {
        let kind: String
        if hint.confidence >= 1 { kind = "rule" } else if hint.confidence >= 0.8 { kind = "root" } else { kind = "catalog" }
        return ["kind": kind, "confidence": (hint.confidence * 100).rounded() / 100,
                "category": categoryLabel(hint.category)]
    }

    /// `suggestion_shown` una vez al día por grupo: dibujar la tarjeta diez
    /// veces no son diez sugerencias.
    static func suggestionShown(_ hint: CategorySuggestion, merchant: String, screen: String) {
        var props = suggestionProps(hint)
        props["screen"] = screen
        // El comercio sólo sirve de llave local: no sale del teléfono.
        trackDaily("suggest." + screen + "." + stableHash(merchant), AnalyticsEvent.suggestionShown.rawValue, props)
    }

    /// `hashValue` cambia en cada arranque; esta llave no.
    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 5381
        for byte in text.utf8 { hash = (hash &<< 5) &+ hash &+ UInt64(byte) }
        return String(hash, radix: 36)
    }
}

// MARK: - Resumen diario

/// Una foto del estado una vez al día: el atasco de Pendientes, qué está
/// conectado y qué ajustes se usan. Los estados no se pueden contar con
/// eventos sueltos («¿cuántos tienen Face ID?»), por eso esta foto.
@MainActor
enum AnalyticsSnapshot {
    private static let key = "analyticsSnapshotDay"

    static func runIfNeeded(container: ModelContainer) {
        guard Analytics.isEnabled else { return }
        let today = Analytics.dayKey(Date())
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: key) != today else { return }
        defaults.set(today, forKey: key)

        let context = container.mainContext
        let unclassified = Accounting.unclassified
        let pendingAll = (try? context.fetchCount(FetchDescriptor<Expense>(predicate: #Predicate {
            $0.category == unclassified && !$0.isTransfer && !$0.isVoided && !$0.isReversal && !$0.isSplit
        }))) ?? 0
        let month = Period(granularity: .mes, reference: Date()).interval
        let start = month.start
        let end = month.end
        let monthExpenses = (try? context.fetch(FetchDescriptor<Expense>(predicate: #Predicate {
            $0.date >= start && $0.date < end && !$0.isTransfer && !$0.isVoided && !$0.isReversal
        }))) ?? []
        let monthPending = monthExpenses.filter { $0.category == unclassified && !$0.isSplit }.count
        let fromEmail = monthExpenses.filter { $0.emailID != nil }.count
        let totalMovements = (try? context.fetchCount(FetchDescriptor<Expense>())) ?? 0
        let recurring = (try? context.fetchCount(FetchDescriptor<RecurringExpense>())) ?? 0

        var props: [String: Any] = [
            "pending_total": pendingAll,
            "pending_month": monthPending,
            "movements_month": monthExpenses.count,
            "movements_month_email": fromEmail,
            "movements_total": totalMovements,
            "categories_used_month": Set(monthExpenses.map(\.category)).subtracting([unclassified]).count,
            "rules": MerchantRules.all().count,
            "recurring_rules": recurring,
            "gmail": GmailAuthService.hasStoredSession,
            "outlook": OutlookAuthService.hasStoredSession,
            "pro": ProStore.isPro,
            "pro_theme": ProTheme.current?.rawValue ?? "none",
            "app_lock": defaults.bool(forKey: AppLock.enabledKey),
            "hide_amounts_on_launch": defaults.bool(forKey: AmountPrivacy.hideOnLaunchKey),
            "budget": defaults.bool(forKey: BudgetStore.enabledKey),
            "friends": FriendsManager.shared.friends.count,
            "cloud_backup": ConfigBackupManager.shared.isEnabled,
            "days_since_install": Analytics.daysSinceInstall
        ]
        // Lo Pro que se usa con sólo tenerlo puesto: el tema y el respaldo.
        if ProTheme.current != nil { Analytics.proFeatureUsed(.themes) }
        if ConfigBackupManager.shared.isEnabled { Analytics.proFeatureUsed(.cloud) }
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            props["notifications"] = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            let widgets = (try? await WidgetCenter.shared.currentConfigurations()) ?? []
            props["widgets"] = widgets.count
            Analytics.track(.dailySnapshot, props)
        }
    }
}

// MARK: - Arranque y MetricKit

enum AnalyticsPerformance {
    private static var initAt = Date()
    private static var reported = false

    /// Desde `NotifableApp.init`.
    static func markInit() { initAt = Date() }

    /// El primer dibujo de la pantalla principal: `perf_launch` con lo que
    /// tardó desde que se tocó el ícono (o desde `init` si iOS precalentó el
    /// proceso, que lo arranca mucho antes de que nadie toque nada).
    @MainActor
    static func markFirstFrame() {
        guard !reported else { return }
        reported = true
        let prewarmed = ProcessInfo.processInfo.environment["ActivePrewarm"] == "1"
        let start = (prewarmed ? nil : processStart) ?? initAt
        let ms = Date().timeIntervalSince(start) * 1000
        // Abierta en segundo plano (Siri, lectura de fondo) y vista mucho
        // después: no es un arranque que alguien esperó.
        guard ms > 0, ms < 60_000 else { return }
        Analytics.track(.perfLaunch, ["ms": Int(ms), "prewarmed": prewarmed])
    }

    private static var processStart: Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    /// Lo que tarda una pantalla pesada en tener sus datos.
    static func screenReady(_ screen: String, since start: Date) {
        let ms = Date().timeIntervalSince(start) * 1000
        guard ms >= 0, ms < 60_000 else { return }
        Analytics.track(.perfScreen, ["screen": screen, "ms": Int(ms)])
    }
}

enum AnalyticsMetricKit {

    /// Crashes, cuelgues y excepciones que iOS entrega en la apertura
    /// siguiente. Sólo el tipo y la señal: la pila se queda en Diagnóstico.
    static func forward(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let version = payload.crashDiagnostics?.first?.metaData.applicationBuildVersion
                ?? payload.hangDiagnostics?.first?.metaData.applicationBuildVersion ?? "?"
            for crash in payload.crashDiagnostics ?? [] {
                var props: [String: Any] = ["kind": "crash", "build": version]
                if let type = crash.exceptionType { props["exception_type"] = type.intValue }
                if let signal = crash.signal { props["signal"] = signal.intValue }
                if let reason = crash.terminationReason { props["reason"] = String(reason.prefix(60)) }
                Analytics.track(.metrickitDiagnostic, props)
            }
            for hang in payload.hangDiagnostics ?? [] {
                Analytics.track(.metrickitDiagnostic, ["kind": "hang", "build": version,
                                                       "seconds": hang.hangDuration.converted(to: .seconds).value])
            }
            if let cpu = payload.cpuExceptionDiagnostics, !cpu.isEmpty {
                Analytics.track(.metrickitDiagnostic, ["kind": "cpu", "build": version, "count": cpu.count])
            }
            if let disk = payload.diskWriteExceptionDiagnostics, !disk.isEmpty {
                Analytics.track(.metrickitDiagnostic, ["kind": "disk", "build": version, "count": disk.count])
            }
        }
    }

    /// El informe diario de rendimiento: arranque, memoria y cuelgues.
    static func forward(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            var props: [String: Any] = ["build": payload.metaData?.applicationBuildVersion ?? "?"]
            if let launch = payload.applicationLaunchMetrics {
                if let ms = mean(launch.histogrammedTimeToFirstDraw) { props["launch_ms"] = Int(ms) }
                if let ms = mean(launch.histogrammedApplicationResumeTime) { props["resume_ms"] = Int(ms) }
            }
            if let responsiveness = payload.applicationResponsivenessMetrics,
               let ms = mean(responsiveness.histogrammedApplicationHangTime) {
                props["hang_ms"] = Int(ms)
            }
            if let memory = payload.memoryMetrics {
                props["peak_memory_mb"] = Int(memory.peakMemoryUsage.converted(to: .megabytes).value)
            }
            if let time = payload.applicationTimeMetrics {
                props["foreground_min"] = Int(time.cumulativeForegroundTime.converted(to: .minutes).value)
            }
            if let exits = payload.applicationExitMetrics {
                let fg = exits.foregroundExitData
                props["fg_abnormal_exits"] = fg.cumulativeAbnormalExitCount + fg.cumulativeAppWatchdogExitCount
                    + fg.cumulativeMemoryResourceLimitExitCount + fg.cumulativeBadAccessExitCount
                    + fg.cumulativeIllegalInstructionExitCount
                props["fg_normal_exits"] = fg.cumulativeNormalAppExitCount
            }
            Analytics.track(.metrickitMetrics, props)
        }
    }

    /// Media en milisegundos de un histograma de duraciones: el punto medio
    /// de cada balde por su cantidad.
    private static func mean(_ histogram: MXHistogram<UnitDuration>) -> Double? {
        var total = 0.0
        var count = 0
        let buckets = histogram.bucketEnumerator
        while let bucket = buckets.nextObject() as? MXHistogramBucket<UnitDuration> {
            let start = bucket.bucketStart.converted(to: .milliseconds).value
            let end = bucket.bucketEnd.converted(to: .milliseconds).value
            total += (start + end) / 2 * Double(bucket.bucketCount)
            count += bucket.bucketCount
        }
        return count > 0 ? total / Double(count) : nil
    }
}

// MARK: - Nombres estables de pestañas y secciones

extension RootTab {
    /// En inglés y fijo: el título que se ve puede cambiar de idioma o de
    /// texto, y el panel agrupa por esto.
    var analyticsName: String {
        switch self {
        case .summary:   return "summary"
        case .movements: return "movements"
        case .goals:     return "goals"
        case .friends:   return "friends"
        case .add:       return "add"
        }
    }
}

extension AppSection {
    var analyticsName: String {
        switch self {
        case .movements:   return "movements"
        case .analysis:    return "analysis"
        case .categories:  return "categories"
        case .tags:        return "tags"
        case .pending:     return "pending"
        case .social:      return "friends"
        case .profile:     return "profile"
        case .receivables: return "receivables"
        }
    }

    /// La función que cuenta como descubierta al entrar aquí.
    var analyticsFeature: AppFeature? {
        switch self {
        case .pending:     return .pendingInbox
        case .analysis:    return .analysis
        case .categories:  return .categories
        case .tags:        return .tags
        case .social:      return .friends
        case .receivables: return .receivables
        case .movements, .profile: return nil
        }
    }
}

extension Analytics {
    /// Meses completos entre el mes de `date` y el actual: 0 es este mes.
    static func monthsBack(from date: Date, now: Date = Date()) -> Int {
        let cal = Period.calendar
        let a = cal.dateComponents([.year, .month], from: date)
        let b = cal.dateComponents([.year, .month], from: now)
        return max(0, ((b.year ?? 0) - (a.year ?? 0)) * 12 + (b.month ?? 0) - (a.month ?? 0))
    }

    /// Un periodo elegido en una pantalla: cuántos meses hacia atrás queda su
    /// inicio, y con qué granularidad.
    static func periodChanged(screen: String, period: Period, extra: [String: Any] = [:]) {
        var props = extra
        props["screen"] = screen
        props["granularity"] = period.granularity.analyticsName
        props["months_back"] = monthsBack(from: period.interval.start)
        track(.periodChange, props)
        if props["months_back"] as? Int ?? 0 >= ProStore.freeHistoryMonths {
            proFeatureUsed(.history)
        }
    }
}

extension PeriodGranularity {
    var analyticsName: String {
        switch self {
        case .dia:    return "day"
        case .semana: return "week"
        case .mes:    return "month"
        case .anio:   return "year"
        case .rango:  return "range"
        }
    }
}

extension AppLockFailure {
    /// Sin el texto del sistema de `.other`, que no aporta y puede variar.
    var analyticsName: String {
        switch self {
        case .cancelled:     return "cancelled"
        case .notRecognized: return "not_recognized"
        case .notEnrolled:   return "not_enrolled"
        case .notAvailable:  return "not_available"
        case .lockout:       return "lockout"
        case .noPasscode:    return "no_passcode"
        case .other:         return "other"
        }
    }
}
