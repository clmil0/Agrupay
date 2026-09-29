import SwiftUI

/// AgruPay Pro (`2a`/`2b` de «Configuración Pro»).
///
/// Por ahora es un interruptor local: «Probar 7 días gratis» lo enciende y no
/// hay cobro de por medio. Cuando llegue StoreKit, lo único que cambia es
/// quién escribe `enabledKey`; las pantallas sólo leen `isPro`.
///
/// Las vistas lo leen con `@AppStorage(ProStore.enabledKey)` para redibujarse
/// solas al cambiar; el resto del código, con `ProStore.isPro`.
///
/// En el simulador: `-proEnabled YES` o `-proEnabled NO` al arrancar fuerza el
/// plan (el dominio de argumentos de `UserDefaults` manda sobre lo guardado).
enum ProStore {

    static let enabledKey = "proEnabled"
    static let sinceKey = "proMemberSince"
    static let planKey = "proPlan"

    enum Plan: String, CaseIterable, Identifiable {
        case anual, mensual
        var id: String { rawValue }

        var price: String { self == .anual ? "S/ 99.90" : "S/ 12.90" }
        var afterTrial: String { self == .anual ? "Luego S/ 99.90 al año" : "Luego S/ 12.90 al mes" }
        var label: String { self == .anual ? "Anual" : "Mensual" }
    }

    /// Lo que gana quien pasa a Pro, en el orden del paywall.
    enum Feature: String, CaseIterable, Identifiable {
        case history, ai, alerts, cloud, sync, themes
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .history: return "clock.arrow.circlepath"
            case .ai:      return "brain.head.profile"
            case .alerts:  return "bell.badge.fill"
            case .cloud:   return "icloud.and.arrow.up.fill"
            case .sync:    return "laptopcomputer.and.iphone"
            case .themes:  return "paintpalette.fill"
            }
        }

        var tint: Color {
            switch self {
            case .history: return Color(red: 0.039, green: 0.518, blue: 1.0)    // #0A84FF
            case .ai:      return Color(red: 0.749, green: 0.353, blue: 0.949)  // #BF5AF2
            case .alerts:  return Color(red: 1.0, green: 0.271, blue: 0.227)    // #FF453A
            case .cloud:   return Color(red: 0.251, green: 0.784, blue: 0.878)  // #40C8E0
            case .sync:    return Color(red: 0.188, green: 0.820, blue: 0.345)  // #30D158
            case .themes:  return Color(red: 0.949, green: 0.549, blue: 0.157)  // #F28C28
            }
        }

        var title: String {
            switch self {
            case .history: return "Todo tu historial"
            case .ai:      return "Asistente con más memoria"
            case .alerts:  return "Cobros más intensos"
            case .cloud:   return "Respaldo en la nube"
            case .sync:    return "Sincronización entre dispositivos"
            case .themes:  return "Temas premium"
            }
        }

        var detail: String {
            switch self {
            case .history: return "Lee y compara tus gastos más allá de los últimos 3 meses."
            case .ai:      return "Recuerda tus conversaciones y hábitos por más tiempo."
            case .alerts:  return "Una animación más llamativa cuando le recuerdas un pago a un amigo."
            case .cloud:   return "Tus preferencias, categorías y reglas, a salvo si cambias de teléfono."
            case .sync:    return "iPhone, iPad y laptop, siempre al día."
            case .themes:  return "Nebulosa, Obsidiana, Aurora y Atardecer: fondos animados para tu resumen."
            }
        }

        /// La frase de arriba del paywall cuando se abre desde esta función.
        var lead: String {
            switch self {
            case .history: return "Tu historial completo, sin el límite de 3 meses."
            case .ai:      return "Un asistente que recuerda más de ti y de tus gastos."
            case .alerts:  return "Cobros que tus amigos no pasan por alto."
            case .cloud:   return "Tu configuración a salvo en la nube."
            case .sync:    return "AgruPay en todos tus dispositivos."
            case .themes:  return "Temas con fondos animados para tu resumen."
            }
        }
    }

    // MARK: - Estado

    static var isPro: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var memberSince: Date? { UserDefaults.standard.object(forKey: sinceKey) as? Date }

    static var plan: Plan { Plan(rawValue: UserDefaults.standard.string(forKey: planKey) ?? "") ?? .anual }

    /// «Miembro Pro · desde sep 2026».
    static var memberSinceLabel: String {
        guard let since = memberSince else { return "Miembro Pro" }
        // A mano: `es_PE` abrevia septiembre como «set.».
        let months = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]
        let parts = Calendar.current.dateComponents([.year, .month], from: since)
        return "Miembro Pro · desde \(months[(parts.month ?? 1) - 1]) \(parts.year ?? 0)"
    }

    /// «Probar 7 días gratis». Sin StoreKit todavía: enciende Pro en local.
    @MainActor
    static func startTrial(plan: Plan) {
        let defaults = UserDefaults.standard
        if memberSince == nil { defaults.set(Date(), forKey: sinceKey) }
        defaults.set(plan.rawValue, forKey: planKey)
        defaults.set(true, forKey: enabledKey)
        didChange()
    }

    /// Volver al plan Gratis (sólo desde el modo QA por ahora).
    @MainActor
    static func cancel() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        didChange()
    }

    /// Lo que depende del plan y no se entera solo: el respaldo en la nube
    /// retoma lo que dejó pendiente al volver a Pro.
    @MainActor
    private static func didChange() {
        ConfigBackupManager.shared.markDirty()
    }

    // MARK: - Límites del plan Gratis

    /// Gratis lee y compara hasta 3 meses atrás.
    static let freeHistoryMonths = 3

    /// Memoria del asistente: 7 días gratis, 30 con Pro.
    static var assistantMemoryDays: Int { isPro ? 30 : 7 }
}

// MARK: - Piezas compartidas

/// La pastilla dorada «PRO» junto a una opción que lo pide.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 9.5, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(Color(red: 0.965, green: 0.776, blue: 0.294))
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Color(red: 0.965, green: 0.776, blue: 0.294).opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(Color(red: 0.965, green: 0.776, blue: 0.294).opacity(0.45), lineWidth: 0.75))
            .accessibilityLabel("Requiere Pro")
    }
}

extension View {
    /// Presenta el paywall cuando `feature` no es `nil`.
    func proPaywall(_ feature: Binding<ProStore.Feature?>) -> some View {
        sheet(item: feature) { feature in
            ProPaywallSheet(feature: feature)
                .appAppearance()
                .appTextSize()
        }
    }

    /// Presenta el paywall general (desde la pastilla «Pro» del perfil).
    func proPaywall(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            ProPaywallSheet(feature: nil)
                .appAppearance()
                .appTextSize()
        }
    }
}
