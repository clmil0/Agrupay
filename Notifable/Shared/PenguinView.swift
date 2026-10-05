import SwiftUI

/// La cara del pingüino. En los widgets dice el estado del presupuesto sin
/// leer cifras (diseño `Widgets AgruPay.dc.html`).
enum PenguinMood: Equatable {
    /// Ojos redondos: vas bien.
    case ok
    /// Ojos entrecerrados: vas por encima del ritmo.
    case warning
    /// Ojos en X: pasaste el presupuesto.
    case over
    /// Ojos en arco: «¡Gracias!» cuando le pagan (`1c` de «Cobros entre amigos»).
    case happy
}

/// Una postura del personaje, para animarlo por partes: alas, copete y cara
/// se mueven cada uno sobre su bisagra, como las capas del diseño
/// `Cobros entre amigos.dc.html`. Las medidas van en unidades del `viewBox`
/// (470 de ancho); lo que mueve al personaje entero —caer, aplastarse,
/// inclinarse— lo pone la vista con modificadores de SwiftUI.
///
/// Sólo los pingüinos tienen alas y copete sueltos; en un animal se usan la
/// cara y el parpadeo.
struct PenguinPose: Equatable {
    /// Grados; positivo, en el sentido del reloj.
    var wingLeft: Double = 0
    var wingRight: Double = 0
    var tuft: Double = 0
    var tuftLift: CGFloat = 0
    var tuftStretch: CGFloat = 1
    /// Ojos, cresta y pico juntos: mirar a un lado o bajar la cabeza.
    var face: CGSize = .zero
    /// Alto de los ojos abiertos: 1 abiertos, ~0 cerrados.
    var blink: CGFloat = 1

    static let rest = PenguinPose()
}

/// Dibuja un `PenguinLook` —pingüino o animal, con sus objetos— con los
/// mismos trazos del kit en SVG (`output/pinguinos`, `output/animales`).
/// Vectorial: se ve nítido de 38 a 120 pt sin assets.
/// Compartido con los widgets: el personaje de la pantalla de inicio es el tuyo.
struct PenguinView: View {
    let look: PenguinLook
    var mood: PenguinMood = .ok
    /// Silueta de un solo color (el de primer plano) con ojos y nariz
    /// recortados: pantalla bloqueada, StandBy y modos teñidos.
    var monochrome = false
    var pose: PenguinPose = .rest

    /// El `viewBox` del SVG original, común a pingüinos, animales y objetos.
    static let viewBox = CGRect(x: 140, y: 170, width: 470, height: 460)

    var body: some View {
        Canvas { context, size in
            let box = Self.viewBox
            let scale = min(size.width / box.width, size.height / box.height)
            context.translateBy(x: (size.width - box.width * scale) / 2, y: (size.height - box.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            let drawing = AvatarDrawing(look: look, mood: mood, pose: pose)
            if monochrome {
                drawing.drawMonochrome(in: context)
            } else {
                drawing.draw(in: context)
            }
        }
        .aspectRatio(Self.viewBox.width / Self.viewBox.height, contentMode: .fit)
        .accessibilityLabel(look.speciesName)
    }
}

/// El personaje dentro de un círculo, con el cuerpo cortado abajo como en la
/// tarjeta de Amigos: la cabeza asoma entera y el círculo recorta la panza.
struct PenguinAvatar: View {
    let look: PenguinLook
    let size: CGFloat
    var background: Color
    /// Un fondo que no es un color liso (el degradado del perfil Pro). Manda
    /// sobre `background`.
    var fill: AnyShapeStyle? = nil

    /// Orejas de gato o un gorro de mago sobresalen de la cabeza: se aleja un
    /// poco el encuadre para que no los corte el círculo.
    private var isTall: Bool { !look.isPenguin || look.item(in: .cabeza) != nil }

    var body: some View {
        ZStack(alignment: .bottom) {
            Circle().fill(fill ?? AnyShapeStyle(background))
            PenguinView(look: look)
                .frame(width: size * (isTall ? 1.04 : 1.15), height: size * (isTall ? 1.02 : 1.13))
                .offset(y: size * (isTall ? 0.1 : 0.02))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Pingüino o animal, con los objetos por delante y por detrás.
private struct AvatarDrawing {
    let look: PenguinLook
    let mood: PenguinMood
    var pose: PenguinPose = .rest

    /// Las capas de los objetos puestos, de atrás hacia delante.
    private func layers(behind: Bool, includeFace: Bool = true) -> [(scene: SVGScene, item: AvatarItem)] {
        look.equipped
            .filter { includeFace || $0.zone != .cara }
            .flatMap { item in item.layers.map { (layer: $0, item: item) } }
            .filter { ($0.layer.z < 0) == behind }
            .sorted { $0.layer.z < $1.layer.z }
            .compactMap { entry in AvatarCatalog.scene(entry.layer.svg).map { ($0, entry.item) } }
    }

    /// Los objetos siguen al pingüino, que se dibuja un poco más chico o más
    /// grande según la edad; los animales van a escala 1.
    private func objectContext(_ context: GraphicsContext) -> GraphicsContext {
        guard look.isPenguin else { return context }
        return PenguinFace.scaled(context, around: CGPoint(x: 379, y: 430), by: look.age == 0 ? 0.94 : 1.03)
    }

    func draw(in context: GraphicsContext) {
        let objects = objectContext(context)
        for layer in layers(behind: true) { layer.scene.draw(in: objects, colors: layer.item.colors) }

        if let scene = look.animal?.scene {
            if mood == .ok && pose.blink >= 1 && pose.face == .zero {
                scene.draw(in: context, colors: look.animalColors)
            } else {
                scene.draw(in: context, colors: look.animalColors, skipping: ["ojos"])
                var face = context
                face.translateBy(x: pose.face.width, y: pose.face.height)
                for eye in PenguinFace.eyes {
                    if let ring = scene.eyeRing { face.fill(PenguinFace.circle(eye, ring), with: .color(.white)) }
                    if mood == .ok {
                        face.fill(PenguinFace.circle(eye, 24, squash: pose.blink), with: .color(PenguinFace.navy))
                    } else {
                        PenguinFace.drawMoodEye(mood, at: eye, in: face, color: PenguinFace.navy)
                    }
                }
            }
        } else {
            PenguinDrawing(look: look, mood: mood, pose: pose).draw(in: context)
        }

        for layer in layers(behind: false) { layer.scene.draw(in: objects, colors: layer.item.colors) }
    }

    /// La silueta en `.foreground` con la cara recortada, como `pin-mono-w`:
    /// así el sistema la tiñe en la pantalla bloqueada sin perder la expresión.
    /// Los lentes se omiten: taparían los ojos, que son lo que dice el ánimo.
    func drawMonochrome(in context: GraphicsContext) {
        let ink = GraphicsContext.Shading.foreground
        let clear = GraphicsContext.Shading.color(.black)
        context.drawLayer { layer in
            let objects = objectContext(layer)
            for item in layers(behind: true) { item.scene.drawSilhouette(in: objects, shading: ink) }

            let penguin = PenguinDrawing(look: look, mood: mood)
            let scene = look.animal?.scene
            if let scene {
                scene.drawSilhouette(in: layer, shading: ink)
            } else {
                penguin.fillSilhouette(in: layer)
            }

            for item in layers(behind: false, includeFace: false) {
                item.scene.drawSilhouette(in: objects, shading: ink)
            }

            layer.blendMode = .destinationOut
            if let scene {
                for eye in PenguinFace.eyes {
                    PenguinFace.drawMoodEye(mood, at: eye, in: layer, color: .black)
                }
                scene.drawSilhouette(in: layer, shading: clear, only: "pico", outlineOnly: true)
            } else {
                penguin.cutFace(in: layer)
            }
        }
    }
}

/// Medidas y trazos de la cara compartidos por pingüinos y animales: los dos
/// kits ponen los ojos en el mismo sitio.
enum PenguinFace {
    static let navy = RGBColor(hex: "#1e1a6b").color
    static let eyes = [CGPoint(x: 318, y: 352), CGPoint(x: 440, y: 355)]

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// Un círculo aplastado en vertical sobre su centro: el parpadeo.
    static func circle(_ center: CGPoint, _ radius: CGFloat, squash: CGFloat) -> Path {
        let height = radius * 2 * max(0.04, min(1, squash))
        return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - height / 2, width: radius * 2, height: height))
    }

    /// Gira `context` `degrees` sobre `pivot`.
    static func rotated(_ context: GraphicsContext, around pivot: CGPoint, degrees: Double) -> GraphicsContext {
        guard degrees != 0 else { return context }
        var copy = context
        copy.translateBy(x: pivot.x, y: pivot.y)
        copy.rotate(by: .degrees(degrees))
        copy.translateBy(x: -pivot.x, y: -pivot.y)
        return copy
    }

    static func scaled(_ context: GraphicsContext, around point: CGPoint, by factor: CGFloat) -> GraphicsContext {
        var copy = context
        copy.translateBy(x: point.x, y: point.y)
        copy.scaleBy(x: factor, y: factor)
        copy.translateBy(x: -point.x, y: -point.y)
        return copy
    }

    /// Entrecerrado: media luna bajo un párpado. En X: dos trazos cruzados.
    /// Mismas medidas que `pin-warn` y `pin-over` del diseño.
    static func drawMoodEye(_ mood: PenguinMood, at eye: CGPoint, in context: GraphicsContext, color: Color) {
        switch mood {
        case .ok:
            context.fill(circle(eye, 24), with: .color(color))
        case .happy:
            var arc = Path()
            arc.move(to: CGPoint(x: eye.x - 19, y: eye.y + 7))
            arc.addCurve(to: CGPoint(x: eye.x + 19, y: eye.y + 7),
                         control1: CGPoint(x: eye.x - 10, y: eye.y - 14),
                         control2: CGPoint(x: eye.x + 10, y: eye.y - 14))
            context.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: 9, lineCap: .round))
        case .warning:
            var half = Path()
            half.addArc(center: CGPoint(x: eye.x, y: eye.y + 2), radius: 24,
                        startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            half.closeSubpath()
            context.fill(half, with: .color(color))
            var lid = Path()
            lid.move(to: CGPoint(x: eye.x - 26, y: eye.y - 4))
            lid.addCurve(to: CGPoint(x: eye.x + 26, y: eye.y - 4),
                         control1: CGPoint(x: eye.x - 16, y: eye.y - 16),
                         control2: CGPoint(x: eye.x + 16, y: eye.y - 16))
            context.stroke(lid, with: .color(color), style: StrokeStyle(lineWidth: 8, lineCap: .round))
        case .over:
            var cross = Path()
            cross.move(to: CGPoint(x: eye.x - 15, y: eye.y - 15))
            cross.addLine(to: CGPoint(x: eye.x + 15, y: eye.y + 15))
            cross.move(to: CGPoint(x: eye.x + 15, y: eye.y - 15))
            cross.addLine(to: CGPoint(x: eye.x - 15, y: eye.y + 15))
            context.stroke(cross, with: .color(color), style: StrokeStyle(lineWidth: 9, lineCap: .round))
        }
    }
}

// MARK: - Pingüino

private struct PenguinDrawing {
    let look: PenguinLook
    let mood: PenguinMood
    var pose: PenguinPose = .rest

    /// Bisagras de las capas, con los `transform-origin` del diseño sobre la
    /// caja de cada forma: el ala izquierda gira desde el hombro (94 % 67 %),
    /// la derecha desde arriba (4 % 17 %) y el copete desde su base.
    private static let wingLeftPivot = pivot(P.wingLeft, 0.94, 0.67)
    private static let wingRightPivot = pivot(P.wingRight, 0.04, 0.17)
    private static let tuftLeafPivot = pivot(P.tuftLeaf, 0.5, 1)
    private static let tuftSpikesPivot = pivot(P.tuftSpikes, 0.5, 1)

    private static func pivot(_ path: Path, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let box = path.boundingRect
        return CGPoint(x: box.minX + box.width * x, y: box.minY + box.height * y)
    }

    private static let navy = PenguinFace.navy
    private static let round = StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)

    private enum P {
        static let body = SVGPath.parse("M215 560 C205 470 200 390 222 320 C245 250 310 228 370 228 C440 228 500 250 515 320 C530 390 525 470 520 560 C520 600 460 616 370 616 C280 616 215 600 215 560 Z")
        static let faceHigh = SVGPath.parse("M370 302 C350 270 298 262 264 290 C236 316 232 380 236 450 C240 520 242 580 246 630 L496 630 C498 580 500 520 502 450 C504 380 500 316 476 290 C442 262 390 270 370 302 Z")
        static let faceLow = SVGPath.parse("M240 480 C262 436 320 420 370 420 C420 420 478 436 500 480 C502 540 500 590 496 630 L246 630 C242 590 238 540 240 480 Z")
        static let tuftLeaf = SVGPath.parse("M386 238 C368 228 352 212 362 202 C372 193 390 206 398 220 C406 204 426 196 436 206 C444 218 428 232 410 238 Z")
        static let tuftSpikes = SVGPath.parse("M356 240 L346 196 L372 222 L382 182 L398 220 L424 190 L416 240 Z")
        static let wingLeft = SVGPath.parse("M248 445 C212 428 172 385 166 342 C162 318 180 310 202 322 C238 342 258 372 264 402 Z")
        static let wingLeftShine = SVGPath.parse("M200 332 C222 350 240 380 246 420 C226 400 204 370 196 340 C195 333 197 330 200 332 Z")
        static let wingRight = SVGPath.parse("M502 448 C540 468 576 508 586 544 C591 566 576 574 554 563 C530 550 512 532 500 522 Z")
        static let wingRightShine = SVGPath.parse("M520 480 C545 500 566 526 574 550 C556 540 536 520 522 500 Z")
        static let headShine = SVGPath.parse("M268 272 C310 246 432 240 488 272 C440 260 320 260 268 272 Z")
        static let emperorWash = SVGPath.parse("M262 452 C300 428 440 428 478 452 C440 440 300 440 262 452 Z")
        static let emperorPatches = SVGPath.parse("M226 360 C250 370 268 410 262 452 C250 440 236 420 228 400 Z M514 360 C490 370 472 410 478 452 C490 440 504 420 512 400 Z")
        static let chinstrap = SVGPath.parse("M250 392 C298 452 452 456 500 394")
        static let gentoo = SVGPath.parse("M282 322 C290 300 322 294 344 310 C328 314 312 318 294 328 Z M476 322 C468 300 436 294 414 310 C430 314 446 318 464 328 Z")
        static let magellanicWide = SVGPath.parse("M232 500 C290 566 450 566 508 500")
        static let magellanicThin = SVGPath.parse("M236 548 C290 600 450 600 504 548")
        static let crests = SVGPath.parse("M336 326 C308 314 268 300 214 286 C238 300 236 302 206 310 C236 314 240 318 214 334 C258 326 290 330 334 338 Z M422 326 C450 314 490 300 544 286 C520 300 522 302 552 310 C522 314 518 318 544 334 C500 326 468 330 424 338 Z")
        static let beak = SVGPath.parse("M346 374 C348 360 408 358 412 374 C414 394 396 408 379 408 C361 408 344 394 346 374 Z")
        static let beakShade = SVGPath.parse("M352 390 C362 402 396 402 406 390 C400 402 390 405 379 405 C366 405 356 400 352 390 Z")
        static let mouth = SVGPath.parse("M368 386 C374 380 386 380 392 386 C388 395 372 395 368 386 Z")
    }

    private static let eyes = PenguinFace.eyes

    private func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        PenguinFace.circle(center, radius)
    }

    private func scaled(_ context: GraphicsContext, around point: CGPoint, by factor: CGFloat) -> GraphicsContext {
        PenguinFace.scaled(context, around: point, by: factor)
    }

    private func scaled(_ context: GraphicsContext, around point: CGPoint, by x: CGFloat, y: CGFloat) -> GraphicsContext {
        var copy = context
        copy.translateBy(x: point.x, y: point.y)
        copy.scaleBy(x: x, y: y)
        copy.translateBy(x: -point.x, y: -point.y)
        return copy
    }

    func draw(in context: GraphicsContext) {
        let breed = look.breedStyle
        let young = look.age == 0
        let coatRGB = RGBColor(hex: look.coatHex)
        let beakRGB = RGBColor(hex: look.beakHex)
        let accentRGB = RGBColor(hex: look.accentHex)
        let coat = coatRGB.color
        let coatLight = coatRGB.mixed(with: .white, amount: 0.65).color
        let accent = accentRGB.color
        let navy = Self.navy

        // Un joven es un poco más bajo; sus ojos, más grandes.
        let body = scaled(context, around: CGPoint(x: 379, y: 430), by: young ? 0.94 : 1.03)

        let ctx = body
        let tuftPath = breed.tuft == .leaf ? P.tuftLeaf : P.tuftSpikes
        let tuftPivot = breed.tuft == .leaf ? Self.tuftLeafPivot : Self.tuftSpikesPivot
        var tuft = PenguinFace.rotated(ctx, around: tuftPivot, degrees: pose.tuft)
        if pose.tuftLift != 0 || pose.tuftStretch != 1 {
            tuft.translateBy(x: 0, y: pose.tuftLift)
            tuft = scaled(tuft, around: tuftPivot, by: 1, y: pose.tuftStretch)
        }
        tuft.fill(tuftPath, with: .color(coat))
        tuft.stroke(tuftPath, with: .color(navy), style: Self.round)

        for (wing, shine, pivot, angle) in [(P.wingLeft, P.wingLeftShine, Self.wingLeftPivot, pose.wingLeft),
                                            (P.wingRight, P.wingRightShine, Self.wingRightPivot, pose.wingRight)] {
            let wingCtx = PenguinFace.rotated(ctx, around: pivot, degrees: angle)
            wingCtx.fill(wing, with: .color(coat))
            wingCtx.stroke(wing, with: .color(navy), style: Self.round)
            wingCtx.fill(shine, with: .color(coatLight))
        }

        ctx.fill(P.body, with: .color(coat))
        ctx.drawLayer { inner in
            inner.clip(to: P.body)
            inner.fill(P.headShine, with: .color(coatLight))
            inner.fill(breed.face == .high ? P.faceHigh : P.faceLow, with: .color(.white))
            switch breed.extra {
            case .emperor:
                inner.fill(P.emperorWash, with: .color(accentRGB.mixed(with: .white, amount: 0.4).color))
                inner.fill(P.emperorPatches, with: .color(accent))
            case .chinstrap:
                inner.stroke(P.chinstrap, with: .color(coat), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            case .gentoo:
                inner.fill(P.gentoo, with: .color(.white))
            case .magellanic:
                inner.stroke(P.magellanicWide, with: .color(coat), style: StrokeStyle(lineWidth: 18, lineCap: .round))
                inner.stroke(P.magellanicThin, with: .color(coat), style: StrokeStyle(lineWidth: 8, lineCap: .round))
            case .none, .rockhopper:
                break
            }
            inner.fill(Path(ellipseIn: CGRect(x: 200, y: 588, width: 340, height: 60)),
                       with: .color(RGBColor(hex: "#e2e2ee").color))
        }
        ctx.stroke(P.body, with: .color(navy), style: Self.round)

        // Ojos, cresta y pico se mueven juntos: es la cabeza la que mira.
        var faceCtx = body
        faceCtx.translateBy(x: pose.face.width, y: pose.face.height)
        let eyeCtx = scaled(faceCtx, around: CGPoint(x: 379, y: 353), by: young ? 1.16 : 0.94)
        let blink = pose.blink
        for eye in Self.eyes {
            switch breed.eyes {
            case .ring27: eyeCtx.fill(circle(eye, 27), with: .color(.white))
            case .ring34: eyeCtx.fill(circle(eye, 34), with: .color(.white))
            default: break
            }
            if mood != .ok {
                // El iris rojo va sobre el manto oscuro: sin él, la X no se ve.
                if breed.eyes == .iris { eyeCtx.fill(circle(eye, 27), with: .color(.white)) }
                PenguinFace.drawMoodEye(mood, at: eye, in: eyeCtx, color: navy)
            } else if blink < 1 {
                // A medio parpadeo sólo se ve la pupila aplastada.
                eyeCtx.fill(PenguinFace.circle(eye, 24, squash: blink), with: .color(navy))
            } else if breed.eyes == .iris {
                eyeCtx.fill(circle(eye, 24), with: .color(RGBColor(hex: "#d62839").color))
                eyeCtx.stroke(circle(eye, 24), with: .color(navy), lineWidth: 3)
                eyeCtx.fill(circle(CGPoint(x: eye.x + 1, y: eye.y + 2), 13), with: .color(navy))
                eyeCtx.fill(circle(CGPoint(x: eye.x - 9, y: eye.y - 9), 8), with: .color(.white))
                eyeCtx.fill(circle(CGPoint(x: eye.x + 9, y: eye.y + 10), 3.5), with: .color(.white))
            } else {
                eyeCtx.fill(circle(eye, 24), with: .color(navy))
                eyeCtx.fill(circle(CGPoint(x: eye.x - 9, y: eye.y - 9), 8), with: .color(.white))
                eyeCtx.fill(circle(CGPoint(x: eye.x + 9, y: eye.y + 10), 3.5), with: .color(.white))
            }
        }

        if breed.extra == .rockhopper {
            faceCtx.fill(P.crests, with: .color(accent))
            faceCtx.stroke(P.crests, with: .color(navy), style: StrokeStyle(lineWidth: 4, lineJoin: .round))
        }

        let beakCtx = scaled(faceCtx, around: CGPoint(x: 379, y: 384), by: young ? 0.9 : 1.04)
        beakCtx.fill(P.beak, with: .color(beakRGB.color))
        beakCtx.stroke(P.beak, with: .color(navy), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        beakCtx.fill(P.beakShade, with: .color(beakRGB.mixed(with: .black, amount: 0.78).color))
        beakCtx.fill(P.mouth, with: .color(RGBColor(hex: "#f06a7a").color))
        beakCtx.stroke(P.mouth, with: .color(navy), style: StrokeStyle(lineWidth: 3, lineJoin: .round))
    }
}

// MARK: - Monocromo

private extension PenguinDrawing {

    /// El contorno entero en `.foreground`; `cutFace` le recorta después la
    /// cara, cuando ya están encima los objetos.
    func fillSilhouette(in layer: GraphicsContext) {
        let breed = look.breedStyle
        let body = scaled(layer, around: CGPoint(x: 379, y: 430), by: look.age == 0 ? 0.94 : 1.03)
        let ink = GraphicsContext.Shading.foreground
        let tuft = breed.tuft == .leaf ? P.tuftLeaf : P.tuftSpikes
        for shape in [tuft, P.wingLeft, P.wingRight, P.body] {
            body.fill(shape, with: ink)
            body.stroke(shape, with: ink, style: Self.round)
        }
    }

    /// Ojos de ánimo y pico, en una capa con `.destinationOut`.
    func cutFace(in layer: GraphicsContext) {
        let young = look.age == 0
        let body = scaled(layer, around: CGPoint(x: 379, y: 430), by: young ? 0.94 : 1.03)
        let clear = Color.black
        let face = scaled(body, around: CGPoint(x: 379, y: 353), by: young ? 1.16 : 0.94)
        for eye in Self.eyes {
            PenguinFace.drawMoodEye(mood, at: eye, in: face, color: clear)
        }
        let beak = scaled(body, around: CGPoint(x: 379, y: 384), by: young ? 0.9 : 1.04)
        beak.stroke(P.beak, with: .color(clear), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        beak.fill(P.mouth, with: .color(clear))
    }
}

/// Lector mínimo de `d` de SVG: sólo `M`, `L`, `C` y `Z` absolutos, que es
/// todo lo que usa el kit de pingüinos.
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var numbers: [CGFloat] = []
        var command: Character = "M"

        func flush() {
            switch command {
            case "M":
                var i = 0
                while i + 1 < numbers.count {
                    let point = CGPoint(x: numbers[i], y: numbers[i + 1])
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    i += 2
                }
            case "L":
                var i = 0
                while i + 1 < numbers.count {
                    path.addLine(to: CGPoint(x: numbers[i], y: numbers[i + 1])); i += 2
                }
            case "C":
                var i = 0
                while i + 5 < numbers.count {
                    path.addCurve(to: CGPoint(x: numbers[i + 4], y: numbers[i + 5]),
                                  control1: CGPoint(x: numbers[i], y: numbers[i + 1]),
                                  control2: CGPoint(x: numbers[i + 2], y: numbers[i + 3]))
                    i += 6
                }
            case "Z":
                path.closeSubpath()
            default:
                break
            }
            numbers.removeAll()
        }

        var token = ""
        func endToken() {
            if let value = Double(token) { numbers.append(CGFloat(value)) }
            token = ""
        }

        for char in d {
            if char.isLetter {
                endToken()
                flush()
                command = char
                if char == "Z" || char == "z" { flush(); command = " " }
            } else if char == " " || char == "," {
                endToken()
            } else if char == "-" && !token.isEmpty {
                endToken(); token = "-"
            } else {
                token.append(char)
            }
        }
        endToken()
        flush()
        return path
    }
}
