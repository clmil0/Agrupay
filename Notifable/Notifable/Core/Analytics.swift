import Foundation
import UIKit

/// Analítica de uso: qué se usa, cuánto y si el motor funciona.
///
/// **Qué sale del teléfono:** el nombre del evento y unas pocas propiedades
/// genéricas (pantalla, banco, categoría, cuántos movimientos…). Nunca montos,
/// comercios, textos de correos, nombres de amigos ni lo que se dicta. Quien
/// manda es un identificador aleatorio de esta instalación (`installID`), que
/// no es el de la cuenta de Google ni el de Amigos: no se puede cruzar.
///
/// **Cómo viaja:** cada `track` va a una cola en memoria que se guarda en
/// disco y se envía por lotes a `ingest_analytics` (Supabase, SQL v16): al
/// juntar `batchThreshold` eventos, cada `flushInterval` con la app abierta y
/// al pasar a segundo plano. Sin red, la cola espera; con más de `maxQueued`,
/// lo más viejo sobra.
///
/// Se apaga en Configuración › Ayuda › «Compartir estadísticas de uso»
/// (`enabledKey`) y nunca corre en modo QA (`-qaFakeData`). Los builds de
/// desarrollo y TestFlight mandan `channel` para filtrarlos en el panel.
///
/// Seguro desde cualquier hilo: todo el estado vive en `queue`.
final class Analytics: @unchecked Sendable {

    static let shared = Analytics()

    static let enabledKey = "analyticsEnabled"
    private static let installIDKey = "analyticsInstallID"
    private static let installedAtKey = "analyticsInstalledAt"
    private static let onceKey = "analyticsOnce"
    private static let dailyKey = "analyticsDaily"
    private static let preexistingKey = "analyticsPreexisting"

    private static let batchThreshold = 25
    private static let batchSize = 100
    private static let maxQueued = 2000
    private static let flushInterval: TimeInterval = 90
    /// Más de esto en segundo plano y la vuelta es una sesión nueva.
    private static let sessionTimeout: TimeInterval = 30 * 60

    private let projectURL = "https://zxfeixwrruclypwjuhnl.supabase.co"
    private let apiKey = "sb_publishable_wJE6quWd2Lu_4rgYvF39CA_iur9-VeT"

    private let queue = DispatchQueue(label: "clmilo.Notifable.analytics", qos: .utility)
    private var events: [[String: Any]] = []
    private var unsavedCount = 0
    private var isFlushing = false
    private var timer: DispatchSourceTimer?
    private var sessionID = UUID().uuidString
    private var backgroundedAt: Date?
    private var context: [String: Any] = [:]
    private var started = false

    private lazy var queueFile: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Analytics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.json")
    }()

    private init() {}

    // MARK: - Estado

    /// Encendido por defecto; el usuario lo apaga en Ayuda.
    static var isEnabled: Bool {
        guard !isQA else { return false }
        return UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private static var isQA: Bool {
        ProcessInfo.processInfo.arguments.contains("-qaFakeData")
    }

    /// Aleatorio, de esta instalación. Reinstalar es una instalación nueva.
    static var installID: String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: installIDKey) { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: installIDKey)
        defaults.set(Date(), forKey: installedAtKey)
        return id
    }

    /// Ya usaba la app cuando llegó la analítica: sus «horas desde que
    /// instaló» no son las de alguien nuevo. Se decide una vez, la primera
    /// vez que se crea el `installID`.
    static var preexisting: Bool {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: installIDKey) == nil {
            let used = defaults.bool(forKey: "hasSeenOnboarding")
                || !(defaults.stringArray(forKey: "processedEmailIDs") ?? []).isEmpty
            defaults.set(used, forKey: preexistingKey)
        }
        return defaults.bool(forKey: preexistingKey)
    }

    static var installedAt: Date {
        _ = installID
        return UserDefaults.standard.object(forKey: installedAtKey) as? Date ?? Date()
    }

    /// Horas desde la instalación, para los hitos de activación.
    static var hoursSinceInstall: Double {
        (Date().timeIntervalSince(installedAt) / 3600 * 10).rounded() / 10
    }

    static var daysSinceInstall: Int {
        Int(Date().timeIntervalSince(installedAt) / 86_400)
    }

    /// `debug` (simulador), `development` (un iPhone de verdad con un build
    /// de Xcode), `testflight` o `appstore`. El panel deja fuera sólo `debug`:
    /// el teléfono de quien desarrolla sí cuenta y se puede filtrar aparte.
    static var channel: String {
        #if targetEnvironment(simulator)
        return "debug"
        #elseif DEBUG
        return "development"
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" ? "testflight" : "appstore"
        #endif
    }

    // MARK: - Arranque

    /// Desde `NotifableApp.init`, en el hilo principal: lee lo que sólo se
    /// puede leer ahí (`UIDevice`) y recupera la cola guardada.
    @MainActor
    func start() {
        guard !started else { return }
        started = true
        let info = Bundle.main.infoDictionary
        let ctx: [String: Any] = [
            "app_version": info?["CFBundleShortVersionString"] as? String ?? "?",
            "build": info?["CFBundleVersion"] as? String ?? "?",
            "os": UIDevice.current.systemVersion,
            "device": Self.deviceModel,
            "locale": Locale.current.identifier,
            "tz": TimeZone.current.identifier,
            "channel": Self.channel,
            "preexisting": Self.preexisting
        ]
        _ = Self.installID
        queue.async {
            self.context = ctx
            self.loadQueue()
        }
    }

    private static var deviceModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    // MARK: - Registrar

    /// Registra un evento. `props` admite `String`, `Int`, `Double` y `Bool`;
    /// lo demás se descarta.
    static func track(_ name: String, _ props: [String: Any] = [:]) {
        guard isEnabled else { return }
        let clean = sanitize(props)
        let now = Date()
        let isPro = ProStore.isPro
        shared.queue.async { shared.enqueue(name: name, props: clean, at: now, isPro: isPro) }
    }

    /// Una sola vez por instalación (`key` la identifica). Devuelve si salió.
    @discardableResult
    static func trackOnce(_ key: String, _ name: String, _ props: [String: Any] = [:]) -> Bool {
        guard isEnabled else { return false }
        let defaults = UserDefaults.standard
        var fired = Set(defaults.stringArray(forKey: onceKey) ?? [])
        guard fired.insert(key).inserted else { return false }
        defaults.set(Array(fired), forKey: onceKey)
        track(name, props)
        return true
    }

    /// Una vez al día por `key`: para estados («usa un tema Pro») y no para
    /// acciones, que se cuentan todas.
    static func trackDaily(_ key: String, _ name: String, _ props: [String: Any] = [:]) {
        guard isEnabled else { return }
        let defaults = UserDefaults.standard
        let today = dayKey(Date())
        var fired = defaults.dictionary(forKey: dailyKey) as? [String: String] ?? [:]
        guard fired[key] != today else { return }
        fired[key] = today
        // Sólo lo de hoy: el diccionario no crece sin fin.
        fired = fired.filter { $0.value == today }
        defaults.set(fired, forKey: dailyKey)
        track(name, props)
    }

    static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    private static func sanitize(_ props: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in props.prefix(24) {
            switch value {
            case let v as Bool:   out[key] = v
            case let v as Int:    out[key] = v
            case let v as Double: out[key] = v.isFinite ? (v * 1000).rounded() / 1000 : nil
            case let v as String: out[key] = String(v.prefix(80))
            default: continue
            }
        }
        return out
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func enqueue(name: String, props: [String: Any], at date: Date, isPro: Bool) {
        var event: [String: Any] = [
            "e": name,
            "t": Self.iso.string(from: date),
            "s": sessionID,
            "pro": isPro
        ]
        if !props.isEmpty { event["p"] = props }
        events.append(event)
        if events.count > Self.maxQueued { events.removeFirst(events.count - Self.maxQueued) }
        unsavedCount += 1
        if unsavedCount >= 10 { saveQueue() }
        if events.count >= Self.batchThreshold { flushLocked() }
    }

    // MARK: - Ciclo de vida

    /// La app vuelve al frente: sesión nueva si estuvo fuera mucho rato, envía
    /// lo pendiente y arma el envío periódico.
    func appDidBecomeActive() {
        queue.async {
            if let left = self.backgroundedAt, Date().timeIntervalSince(left) > Self.sessionTimeout {
                self.sessionID = UUID().uuidString
            }
            self.backgroundedAt = nil
            self.startTimer()
            self.flushLocked()
        }
    }

    /// A segundo plano: se guarda y se intenta enviar con el tiempo que iOS
    /// concede antes de suspender la app.
    @MainActor
    func appDidEnterBackground() {
        let app = UIApplication.shared
        var task: UIBackgroundTaskIdentifier = .invalid
        task = app.beginBackgroundTask(withName: "analytics-flush") {
            app.endBackgroundTask(task)
            task = .invalid
        }
        queue.async {
            self.backgroundedAt = Date()
            self.timer?.cancel()
            self.timer = nil
            self.saveQueue()
            self.flushLocked(drain: true) { _ in
                DispatchQueue.main.async {
                    guard task != .invalid else { return }
                    app.endBackgroundTask(task)
                    task = .invalid
                }
            }
        }
    }

    /// El usuario apagó las estadísticas: lo pendiente no se manda.
    func discardPending() {
        queue.async {
            self.events.removeAll()
            self.saveQueue()
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        source.setEventHandler { [weak self] in self?.flushLocked() }
        source.resume()
        timer = source
    }

    // MARK: - Envío

    /// Lo que pasó al vaciar la cola: para el botón «Enviar estadísticas».
    struct SendReport {
        var sent = 0
        /// Rechazados por el servidor (4xx): no se reintentan.
        var dropped = 0
        /// Lo que sigue en la cola al terminar.
        var pending = 0
        /// Por qué se detuvo, si no terminó.
        var failure: String?
    }

    func flush() { queue.async { self.flushLocked() } }

    /// Manda todo lo pendiente, lote a lote, y cuenta cómo fue.
    func sendNow() async -> SendReport {
        await withCheckedContinuation { continuation in
            queue.async {
                self.flushLocked(drain: true) { continuation.resume(returning: $0) }
            }
        }
    }

    /// Cuántos eventos esperan en la cola.
    func pendingCount() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.events.count) }
        }
    }

    /// Sólo desde `queue`. Con `drain`, sigue lote tras lote hasta vaciar la
    /// cola o fallar; sin él, manda uno (y otro sólo si sobran muchos).
    private func flushLocked(drain: Bool = false, report: SendReport = SendReport(),
                             completion: ((SendReport) -> Void)? = nil) {
        var report = report
        func finish(_ failure: String? = nil) {
            report.failure = report.failure ?? failure
            report.pending = events.count
            completion?(report)
        }
        guard Self.isEnabled else { return finish("Las estadísticas están apagadas.") }
        guard !events.isEmpty else { return finish() }
        // Ya hay un lote en camino (el envío periódico): se espera a que
        // termine en vez de mandar el mismo dos veces.
        if isFlushing {
            guard drain else { return finish() }
            queue.asyncAfter(deadline: .now() + 0.3) {
                self.flushLocked(drain: drain, report: report, completion: completion)
            }
            return
        }
        guard let url = URL(string: "\(projectURL)/rest/v1/rpc/ingest_analytics") else { return finish() }
        isFlushing = true
        let batch = Array(events.prefix(Self.batchSize))
        let body: [String: Any] = [
            "p_install_id": Self.installID,
            "p_context": context,
            "p_events": batch
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            // Un lote que no se puede serializar no se va a poder nunca.
            events.removeFirst(batch.count)
            report.dropped += batch.count
            isFlushing = false
            return finish("Un lote no se pudo armar y se descartó.")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "apikey")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        #if DEBUG
        // Para revisar a mano lo que sale: `Application Support/Analytics`.
        try? data.write(to: queueFile.deletingLastPathComponent().appendingPathComponent("last-batch.json"))
        #endif

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            self.queue.async {
                self.isFlushing = false
                Diagnostics.shared.log("Analítica: lote de \(batch.count) eventos → HTTP \(status)")
                if error == nil, (200..<300).contains(status) {
                    self.events.removeFirst(min(batch.count, self.events.count))
                    self.saveQueue()
                    report.sent += batch.count
                    // Quedó más: el siguiente lote, ya.
                    if drain || self.events.count >= Self.batchThreshold, !self.events.isEmpty {
                        self.flushLocked(drain: drain, report: report, completion: completion)
                        return
                    }
                    finish()
                } else if (400..<500).contains(status), status != 429 {
                    // El servidor lo rechaza (SQL v16 sin correr, lote mal
                    // formado): reintentar no lo arregla y la cola crecería.
                    Diagnostics.shared.log("Analítica: el servidor rechazó un lote (HTTP \(status)); se descarta")
                    self.events.removeFirst(min(batch.count, self.events.count))
                    self.saveQueue()
                    report.dropped += batch.count
                    finish("El servidor rechazó \(batch.count) eventos (HTTP \(status)).")
                } else if let error {
                    finish("Sin conexión: \(error.localizedDescription)")
                } else {
                    finish("El servidor no respondió bien (HTTP \(status)). Se reintenta luego.")
                }
            }
        }.resume()
    }

    // MARK: - Disco

    private func loadQueue() {
        guard let data = try? Data(contentsOf: queueFile),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        events = stored + events
    }

    private func saveQueue() {
        unsavedCount = 0
        guard let data = try? JSONSerialization.data(withJSONObject: events) else { return }
        try? data.write(to: queueFile, options: .atomic)
    }
}
