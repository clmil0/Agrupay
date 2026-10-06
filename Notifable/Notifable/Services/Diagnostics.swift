import Foundation
import MetricKit
import Darwin
import MachO

/// Registro de cuelgues y crashes que sobrevive a que la app muera.
///
/// Tres fuentes, todas en `Application Support/Diagnostics`:
/// - **Bitácora por sesión** (`session-*.log`): marcas cortas de qué estaba
///   haciendo la app. Si se congela, la última línea dice dónde. Se guardan
///   las últimas `keptSessions` aperturas.
/// - **Vigilante del hilo principal**: si main no responde en
///   `hangThreshold` segundos, lo anota en la bitácora (y cuándo se recupera).
///   Funciona también con el depurador de Xcode conectado, donde iOS no mata
///   la app y MetricKit no informa nada.
/// - **MetricKit** (`metrickit-*.json`): los informes de crash y cuelgue que
///   arma iOS, con la pila de llamadas. Llegan en la apertura siguiente.
final class Diagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = Diagnostics()

    static let hangThreshold: TimeInterval = 2
    private static let keptSessions = 8

    let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let queue = DispatchQueue(label: "clmilo.Notifable.diagnostics")
    private var handle: FileHandle?
    private var started = false

    // Estado del vigilante; sólo se toca desde `queue`.
    private var timer: DispatchSourceTimer?
    private var lastPong = Date()
    private var lastTick = Date()
    private var hangStartedAt: Date?
    private var samplesInThisHang = 0

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    /// Llamar lo antes posible en el arranque. Idempotente.
    func start() {
        queue.sync {
            guard !started else { return }
            started = true
            openSessionFile()
        }
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))"
        log("Apertura · versión \(version)")
        MXMetricManager.shared.add(self)
        MainStackSampler.install()
        startWatchdog()
    }

    /// Anota una marca en la bitácora. Barato y seguro desde cualquier hilo.
    func log(_ message: String, file: String = #fileID, line: Int = #line) {
        let now = Date()
        let thread = Thread.isMainThread ? "main" : "bg"
        queue.async {
            self.write("\(Self.stamp.string(from: now)) [\(thread)] \(message)  ‹\(file):\(line)›")
        }
    }

    // MARK: - Bitácora

    private func openSessionFile() {
        let url = directory.appendingPathComponent("session-\(Self.fileStamp.string(from: Date())).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        pruneSessions()
    }

    private func pruneSessions() {
        let sessions = files(prefix: "session-")
        for old in sessions.dropFirst(Self.keptSessions) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    /// Cada línea va directo al kernel: si iOS mata la app un instante después,
    /// la línea ya está en disco.
    private func write(_ line: String) {
        guard let handle, let data = (line + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    /// Archivos del directorio con ese prefijo, del más nuevo al más viejo.
    func files(prefix: String) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func deleteAll() {
        queue.sync {
            let current = files(prefix: "session-").first
            for url in files(prefix: "") where url != current {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Vigilante del hilo principal

    private func startWatchdog() {
        queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    private func tick() {
        let now = Date()
        // Si el propio vigilante estuvo detenido (app suspendida en segundo
        // plano), el silencio de main no es un cuelgue: se reinicia la cuenta.
        if now.timeIntervalSince(lastTick) > Self.hangThreshold {
            lastPong = now
            hangStartedAt = nil
        }
        lastTick = now

        let silence = now.timeIntervalSince(lastPong)
        if silence >= Self.hangThreshold, hangStartedAt == nil {
            hangStartedAt = lastPong
            write("\(Self.stamp.string(from: now)) [watchdog] ⚠️ CUELGUE: el hilo principal no responde desde \(Self.stamp.string(from: lastPong))")
            samplesInThisHang = 0
        }

        // Dónde está atascado main, no sólo cuándo: una muestra al detectarlo
        // y otra cada segundo más, hasta tres. Si las tres coinciden, esa es
        // la función culpable.
        if let started = hangStartedAt, samplesInThisHang < 3,
           now.timeIntervalSince(started) >= Self.hangThreshold + Double(samplesInThisHang) {
            samplesInThisHang += 1
            if let frames = MainStackSampler.sample() {
                write("\(Self.stamp.string(from: now)) [watchdog] pila de main (muestra \(samplesInThisHang)):\n" + frames)
            }
        }

        DispatchQueue.main.async { [weak self] in
            let pong = Date()
            self?.queue.async { self?.pong(at: pong) }
        }
    }

    private func pong(at date: Date) {
        if let started = hangStartedAt {
            write("\(Self.stamp.string(from: date)) [watchdog] ✅ el hilo principal volvió tras \(String(format: "%.1f", date.timeIntervalSince(started))) s")
            Analytics.track(.mainHang, ["seconds": date.timeIntervalSince(started)])
            hangStartedAt = nil
        }
        lastPong = max(lastPong, date)
    }

    // MARK: - MetricKit

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            var kinds: [String] = []
            if !(payload.crashDiagnostics ?? []).isEmpty { kinds.append("crash") }
            if !(payload.hangDiagnostics ?? []).isEmpty { kinds.append("hang") }
            if !(payload.cpuExceptionDiagnostics ?? []).isEmpty { kinds.append("cpu") }
            if !(payload.diskWriteExceptionDiagnostics ?? []).isEmpty { kinds.append("disk") }
            let kind = kinds.isEmpty ? "otro" : kinds.joined(separator: "+")
            let name = "metrickit-\(Self.fileStamp.string(from: payload.timeStampEnd))-\(kind).json"
            try? payload.jsonRepresentation().write(to: directory.appendingPathComponent(name))
            log("MetricKit entregó un informe: \(kind)")
        }
        AnalyticsMetricKit.forward(payloads)
    }

    /// El informe diario de rendimiento (arranque, memoria, cuelgues): sólo
    /// para la analítica, la bitácora no lo guarda.
    func didReceive(_ payloads: [MXMetricPayload]) {
        AnalyticsMetricKit.forward(payloads)
    }
}

// MARK: - Muestra de la pila del hilo principal

/// Globales y no propiedades: el manejador de señal es una función C sin
/// contexto. Se reservan una vez en `install()`, antes de armar la señal, así
/// que el manejador sólo escribe en memoria que ya existe.
private let samplerCapacity: Int32 = 48
nonisolated(unsafe) private var samplerFrames: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
nonisolated(unsafe) private var samplerCount: Int32 = 0
nonisolated(unsafe) private var samplerDone: Int32 = 0

/// Pide al hilo principal su propia pila con una señal (`SIGUSR2`).
///
/// El manejador sólo llama a `backtrace()` sobre un búfer ya reservado —nada
/// de `malloc` ni de símbolos—, así que es seguro aunque main esté atascado
/// dentro de un lock. La traducción a nombres se hace después, en la cola del
/// vigilante. Cada línea lleva imagen, dirección y base de carga, de modo que
/// lo que `dladdr` no nombre (funciones internas de la app) se puede
/// simbolizar luego con `atos -o <binario> -l <base> <dirección>`.
enum MainStackSampler {

    nonisolated(unsafe) private static var mainThread: pthread_t?

    /// Llamar desde el hilo principal.
    ///
    /// **No se arma con el depurador conectado:** LLDB se detiene en
    /// `SIGUSR2`, así que el cuelgue del arranque pausaba la app con la
    /// pantalla en negro. Ahí tampoco hace falta: Xcode ya enseña la pila al
    /// pausar. El vigilante sigue anotando los cuelgues igual.
    static func install() {
        guard mainThread == nil, !isDebuggerAttached else { return }
        mainThread = pthread_self()
        samplerFrames = .allocate(capacity: Int(samplerCapacity))
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in
            guard let frames = samplerFrames else { return }
            samplerCount = backtrace(frames, samplerCapacity)
            samplerDone = 1
        }
        action.sa_flags = SA_RESTART
        sigemptyset(&action.sa_mask)
        sigaction(SIGUSR2, &action, nil)
    }

    /// `P_TRACED` en los flags del propio proceso: lo marca cualquier
    /// depurador (Xcode, `lldb`) al conectarse.
    private static var isDebuggerAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// Desde cualquier hilo que no sea main. `nil` si main no contesta en 0.5 s
    /// (p. ej. bloqueado en una llamada al kernel que no atiende señales).
    static func sample() -> String? {
        guard let mainThread, let frames = samplerFrames else { return nil }
        samplerDone = 0
        guard pthread_kill(mainThread, SIGUSR2) == 0 else { return nil }
        for _ in 0..<50 where samplerDone == 0 { usleep(10_000) }
        guard samplerDone == 1 else { return nil }

        var lines: [String] = []
        // Las dos primeras son el propio manejador y la trampa de la señal.
        for i in 2..<Int(samplerCount) {
            guard let address = frames[i] else { continue }
            lines.append("    " + describe(address))
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ address: UnsafeMutableRawPointer) -> String {
        var info = Dl_info()
        let hex = String(format: "0x%lx", UInt(bitPattern: address))
        guard dladdr(address, &info) != 0 else { return hex }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        let base = imageBase(containing: address).map { String(format: "0x%lx", $0) } ?? "?"
        if let name = info.dli_sname, let start = info.dli_saddr {
            let symbol = String(cString: name)
            let offset = UInt(bitPattern: address) - UInt(bitPattern: start)
            return "\(image) \(hex) (base \(base)) \(symbol) + \(offset)"
        }
        return "\(image) \(hex) (base \(base))"
    }

    /// Cabecera Mach-O de la imagen que contiene la dirección: la mayor que
    /// quede por debajo de ella.
    private static func imageBase(containing address: UnsafeMutableRawPointer) -> UInt? {
        let target = UInt(bitPattern: address)
        var best: UInt?
        for i in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(i) else { continue }
            let base = UInt(bitPattern: header)
            if base <= target, base > (best ?? 0) { best = base }
        }
        return best
    }
}
