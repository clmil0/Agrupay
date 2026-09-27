import Foundation
import SwiftUI
import Testing
@testable import Notifable

/// El motor de las animaciones de «Cobros entre amigos» y el «una vez por
/// recordatorio» del modo intenso.
@MainActor
struct CobrosEntreAmigosTests {

    private enum C: Hashable { case y, s }

    @Test("KeyMotion: antes de empezar vale su primer fotograma (fill: backwards)")
    func rellenoHaciaAtras() {
        var m = KeyMotion<C>(rest: [.s: 1])
        m.add([(0, [.y: -440]), (1, [.y: 0])], at: 380, duration: 1100, curve: .linear)
        #expect(m.value(.y, at: 0) == -440)
        #expect(m.value(.y, at: 380 + 550) == -220)
        #expect(m.value(.y, at: 5000) == 0)
        // Un canal que ningún clip toca vale su reposo.
        #expect(m.value(.s, at: 1000) == 1)
    }

    @Test("KeyMotion: manda el clip que empezó más tarde")
    func mandaElUltimo() {
        var m = KeyMotion<C>(rest: [:])
        m.add([(0, [.y: 10]), (1, [.y: 20])], at: 0, duration: 100, curve: .linear)
        m.add([(0, [.y: 50]), (1, [.y: 60])], at: 200, duration: 100, curve: .linear)
        // Entre los dos, el primero ya terminó y se queda en su final.
        #expect(m.value(.y, at: 150) == 20)
        #expect(m.value(.y, at: 250) == 55)
    }

    @Test("KeyMotion: un canal ausente en un fotograma vale su reposo, como un transform")
    func canalAusente() {
        var m = KeyMotion<C>(rest: [.s: 1])
        m.add([(0, [.s: 1.1, .y: 0]), (0.5, [.y: -9]), (1, [:])], at: 0, duration: 100, curve: .linear)
        #expect(abs(m.value(.s, at: 50) - 1) < 0.0001)
        #expect(abs(m.value(.y, at: 50) + 9) < 0.0001)
    }

    @Test("KeyMotion: en bucle alterno vuelve sobre sus pasos")
    func bucleAlterno() {
        var m = KeyMotion<C>(rest: [:])
        m.add([(0, [.y: 0]), (1, [.y: 10])], at: 0, duration: 100, curve: .linear,
              iterations: .infinity, alternate: true)
        #expect(abs(m.value(.y, at: 50) - 5) < 0.0001)
        #expect(abs(m.value(.y, at: 175) - 2.5) < 0.0001)
    }

    @Test("El ojito tapa sólo las cifras de dinero, con cualquier espaciado")
    func mascaraDeMontos() {
        #expect(!AmountPrivacy.mask(Money.format(1571.40)).contains("1"))
        #expect(!AmountPrivacy.mask(Money.format(20, currency: "USD")).contains("20"))
        #expect(AmountPrivacy.mask("S/ 204 · 8 movimientos") == "S/ ••• · 8 movimientos")
        #expect(AmountPrivacy.mask("S/ 1,492 vs. agosto") == "S/ ••• vs. agosto")
        #expect(AmountPrivacy.mask("22 sept") == "22 sept")
        #expect(AmountPrivacy.mask("45%") == "45%")
    }

    @Test("Un recordatorio renovado cuenta como llegada nueva")
    func renovadoEsNuevo() {
        let first = PaymentReminder(id: "r1", fromUser: "a", merchant: "X", occurredOn: nil, amount: 10,
                                    currency: "PEN", message: "", createdAt: Date(timeIntervalSince1970: 1_000))
        let renewed = PaymentReminder(id: "r1", fromUser: "a", merchant: "X", occurredOn: nil, amount: 10,
                                      currency: "PEN", message: "", createdAt: Date(timeIntervalSince1970: 90_000))
        #expect(first.arrivalKey != renewed.arrivalKey)
        #expect(first.intensity == .soft)
    }
}
