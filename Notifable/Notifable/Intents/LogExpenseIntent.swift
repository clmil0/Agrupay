import AppIntents
import SwiftData
import Foundation

struct LogExpenseIntent: AppIntent {
    // Título y descripción visibles en la app "Atajos"
    static var title: LocalizedStringResource = "Log Apple Pay Expense"
    static var description: IntentDescription = "Logs a new expense captured from a transaction notification."
    
    // El texto crudo de la notificación (opcional, para notificaciones de SMS/Push)
    @Parameter(title: "Notification Text", default: nil)
    var notificationText: String?
    
    // El monto estructurado (opcional, provisto por Apple Pay Wallet)
    @Parameter(title: "Amount", default: nil)
    var amount: Double?
    
    // El comercio estructurado (opcional, provisto por Apple Pay Wallet)
    @Parameter(title: "Merchant", default: nil)
    var merchant: String?
    
    static var parameterSummary: some ParameterSummary {
        Summary("Log Expense: \(\.$amount) at \(\.$merchant) (Fallback: \(\.$notificationText))")
    }
    
    // Queremos que se ejecute en segundo plano sin abrir la app
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        var finalAmount: Double = 0
        var finalMerchant: String = "Desconocido"
        
        // 1. Prioridad 1: Si Shortcuts entrega variables estructuradas (Ej: Automatización nativa de Wallet)
        if let amt = amount, let merch = merchant {
            finalAmount = amt
            finalMerchant = merch
        }
        // 2. Prioridad 2: Si Shortcuts solo entrega texto crudo (Ej: SMS o Push del banco)
        else if let text = notificationText, let parsedData = parseNotification(text) {
            finalAmount = parsedData.amount
            finalMerchant = parsedData.merchant
        } else {
            print("No se pudo extraer el monto o comercio de los datos recibidos.")
            return .result() // Retornamos igual para no romper el atajo
        }
        
        do {
            // El contenedor de la app, no uno propio: ver `AppModelContainer`.
            let context = AppModelContainer.shared.mainContext
            
            // Auto-categorización básica (Prueba de concepto)
            var autoCategory = "Sin Clasificar"
            let lowerMerchant = finalMerchant.lowercased()
            if lowerMerchant.contains("starbucks") || lowerMerchant.contains("eats") || lowerMerchant.contains("tambo") {
                autoCategory = "Comida"
            } else if lowerMerchant.contains("uber") || lowerMerchant.contains("lyft") || lowerMerchant.contains("didi") {
                autoCategory = "Transporte"
            } else if lowerMerchant.contains("netflix") || lowerMerchant.contains("spotify") || lowerMerchant.contains("apple") {
                autoCategory = "Suscripciones"
            }

            let isSub = autoCategory == "Suscripciones"
            autoCategory = CategoryCatalog.shared.builtIns.resolve(autoCategory) ?? Accounting.unclassified
            
            let newExpense = Expense(amount: finalAmount, merchant: finalMerchant, category: autoCategory, isSubscription: isSub)
            context.insert(newExpense)
            
            try context.save()
            if autoCategory != Accounting.unclassified {
                ClassificationLedger.record(newExpense.id, engine: .keyword)
            }
            Analytics.track(.movementCreated, ["source": "siri", "kind": "expense",
                                               "category_source": autoCategory == Accounting.unclassified ? "none" : "keyword",
                                               "category": Analytics.categoryLabel(autoCategory)])
            Analytics.featureUsed(.siri)
            Analytics.milestone(.firstMovement)
            Analytics.shared.flush()
            WidgetSnapshotWriter.shared.refreshNow()

            print("Expense saved successfully: $\(finalAmount) at \(finalMerchant) (\(autoCategory))")
            return .result()
        } catch {
            print("Failed to save expense: \(error)")
            throw error
        }
    }
    
    // MARK: - Parseo de Texto (Regex)
    private func parseNotification(_ text: String) -> (amount: Double, merchant: String)? {
        // 1. Buscar el monto. Ejemplo: S/ 15.50, S/15.50, $15.50, 15.50 USD
        // Regex simple: busca secuencias de dígitos que tengan un punto o coma seguido de 2 dígitos.
        let amountPattern = "[0-9]+[.,][0-9]{2}"
        guard let amountRange = text.range(of: amountPattern, options: .regularExpression) else {
            return nil
        }
        
        let amountString = String(text[amountRange]).replacingOccurrences(of: ",", with: ".")
        guard let amount = Double(amountString) else { return nil }
        
        // 2. Buscar el comercio. Generalmente está después de "en " o "a ".
        let lowerText = text.lowercased()
        var merchant = "Desconocido"
        
        if let enRange = lowerText.range(of: " en ") {
            let afterEn = text[enRange.upperBound...]
            merchant = String(afterEn).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let aRange = lowerText.range(of: " a ") {
            let afterA = text[aRange.upperBound...]
            merchant = String(afterA).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // Limpieza extra: Si el mensaje incluye fechas al final "en TAMBO el 28/08"
        if let elRange = merchant.lowercased().range(of: " el ") {
            merchant = String(merchant[..<elRange.lowerBound])
        }
        
        // Quitar puntos finales si los hay
        if merchant.hasSuffix(".") {
            merchant.removeLast()
        }
        
        return (amount, merchant.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
