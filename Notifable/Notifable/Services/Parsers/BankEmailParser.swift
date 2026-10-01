import Foundation

protocol BankEmailParser {
    var bankName: String { get }
    
    /// Devuelve las direcciones de correo electrónico que envía este banco (ej. procesos@bbva.com.pe)
    var senderEmails: [String] { get }
    
    /// Analiza el texto limpio de un correo y devuelve un `Expense` si logra interpretarlo
    func parse(cleanText: String) -> Expense?

    /// Analiza el texto limpio de un correo y devuelve un `Income` si logra interpretarlo
    /// (ej. una constancia de recepción de Yapeo/Plin: dinero que entra, no que sale).
    /// La mayoría de bancos no mandan este tipo de correo, así que el default de abajo
    /// evita que cada parser existente tenga que declarar el método sin usarlo.
    func parseIncome(cleanText: String) -> Income?
}

extension BankEmailParser {
    func parseIncome(cleanText: String) -> Income? { nil }
}

/// La hora que escriben los bancos en sus correos es siempre la de Perú.
/// Leerla en la zona del teléfono corría cada gasto las horas de diferencia
/// cuando el usuario viajaba: los de cerca de medianoche cambiaban de día, y
/// a fin de mes, de mes.
enum BankEmailTime {
    static let zone = TimeZone(identifier: "America/Lima") ?? .current
}
