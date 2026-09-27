import SwiftUI

/// Animaciones por fotogramas clave con la semántica de la Web Animations API
/// que usa el diseño `Cobros entre amigos.dc.html`: retraso, duración, curva
/// de la iteración entera, curva por tramo entre fotogramas y `fill: both`.
///
/// Así los tiempos y curvas del diseño se copian tal cual (milisegundos,
/// `offset` de 0 a 1) en vez de reinterpretarlos con resortes de SwiftUI. Se
/// evalúa en cada fotograma de un `TimelineView(.animation)`.
struct KeyMotion<Channel: Hashable> {

    struct Frame {
        let offset: Double
        let values: [Channel: Double]
        /// Curva hasta el fotograma siguiente.
        var curve: UnitCurve = .linear
    }

    struct Clip {
        let channels: Set<Channel>
        let frames: [Frame]
        /// Milisegundos desde el inicio de la línea de tiempo.
        let start: Double
        let duration: Double
        var curve: UnitCurve = .ease
        var iterations: Double = 1
        var alternate = false
    }

    private(set) var clips: [Clip] = []
    /// El valor de reposo de cada canal (lo que se ve sin animación).
    let rest: [Channel: Double]

    init(rest: [Channel: Double]) {
        self.rest = rest
    }

    /// - Parameter frames: `(offset, valores, curva del tramo)`. Un canal que
    ///   falte en un fotograma vale su reposo, como un `transform` ausente.
    mutating func add(_ frames: [(Double, [Channel: Double], UnitCurve)],
                      at start: Double, duration: Double,
                      curve: UnitCurve = .ease, iterations: Double = 1, alternate: Bool = false) {
        let channels = Set(frames.flatMap(\.1.keys))
        let built = frames.map { Frame(offset: $0.0, values: $0.1, curve: $0.2) }
        clips.append(Clip(channels: channels, frames: built, start: start, duration: duration,
                          curve: curve, iterations: iterations, alternate: alternate))
    }

    /// Lo mismo con tramos lineales: el caso común.
    mutating func add(_ frames: [(Double, [Channel: Double])],
                      at start: Double, duration: Double,
                      curve: UnitCurve = .ease, iterations: Double = 1, alternate: Bool = false) {
        add(frames.map { ($0.0, $0.1, UnitCurve.linear) }, at: start, duration: duration,
            curve: curve, iterations: iterations, alternate: alternate)
    }

    mutating func removeAll() { clips.removeAll() }

    /// El final del último clip finito.
    var end: Double {
        clips.filter { $0.iterations.isFinite }.map { $0.start + $0.duration * $0.iterations }.max() ?? 0
    }

    /// Manda el clip que empezó más tarde; antes de que empiece ninguno, el
    /// primer fotograma del primero (`fill: backwards`).
    func value(_ channel: Channel, at time: Double) -> Double {
        let owning = clips.filter { $0.channels.contains(channel) }
        guard !owning.isEmpty else { return rest[channel] ?? 0 }
        let started = owning.filter { $0.start <= time }
        let clip = started.max { $0.start < $1.start } ?? owning.min { $0.start < $1.start }!
        return evaluate(clip, channel, at: time)
    }

    private func evaluate(_ clip: Clip, _ channel: Channel, at time: Double) -> Double {
        let base = rest[channel] ?? 0
        let local = max(0, time - clip.start) / max(clip.duration, 1)
        var progress: Double
        if clip.iterations.isFinite && local >= clip.iterations {
            progress = 1
            if clip.alternate && Int(clip.iterations) % 2 == 0 { progress = 0 }
        } else {
            let iteration = floor(local)
            progress = local - iteration
            if clip.alternate && Int(iteration) % 2 == 1 { progress = 1 - progress }
        }
        progress = clip.curve.value(at: progress)

        let frames = clip.frames
        guard let first = frames.first else { return base }
        if progress <= first.offset { return first.values[channel] ?? base }
        for index in 0..<(frames.count - 1) {
            let a = frames[index], b = frames[index + 1]
            guard progress <= b.offset else { continue }
            let span = max(b.offset - a.offset, 0.0001)
            let t = a.curve.value(at: (progress - a.offset) / span)
            let from = a.values[channel] ?? base
            let to = b.values[channel] ?? base
            return from + (to - from) * t
        }
        return frames.last?.values[channel] ?? base
    }
}

extension UnitCurve {
    /// `ease` de CSS.
    static let ease = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.25, y: 0.1),
                                       endControlPoint: UnitPoint(x: 0.25, y: 1))

    /// `cubic-bezier(x1, y1, x2, y2)` de CSS.
    static func css(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> UnitCurve {
        .bezier(startControlPoint: UnitPoint(x: x1, y: y1), endControlPoint: UnitPoint(x: x2, y: y2))
    }

    /// `ease-in-out` y `ease-out` de CSS, que no son los de SwiftUI.
    static let cssEaseInOut = UnitCurve.css(0.42, 0, 0.58, 1)
    static let cssEaseOut = UnitCurve.css(0, 0, 0.58, 1)
    static let cssEaseIn = UnitCurve.css(0.42, 0, 1, 1)
}
