import Foundation

/// Sugerencia de categoría para un comercio sin clasificar.
struct CategorySuggestion: Equatable {
    let category: String
    /// 0…1. Por debajo de 0.45 no se muestra el botón "Aplicar".
    let confidence: Double
    /// Texto corto que explica por qué. La sugerencia sin motivo no se aplica sola.
    let reason: String
}

/// Motor de sugerencias de la Bandeja.
///
/// El flujo anterior costaba: por cada comercio, abrir un sheet, buscar en una
/// lista, elegir, cerrar. Con 12 comercios son 48 toques. Aquí la app propone y
/// el usuario confirma con uno.
///
/// Orden de resolución: regla exacta → regla por raíz del nombre (no para
/// Yape/Plin/transferencias) → catálogo de comercios conocidos
/// (`MerchantCatalog`, descargado de Supabase y guardado en el teléfono).
///
/// Yape, Plin y las transferencias bancarias ("YAPE - ", "PLIN - ", "BBVA - ", "BCP - ",
/// "INTERBANK - ")
/// llevan el nombre de la **persona** destinataria como comercio, no el de un
/// negocio: no se repite de forma predecible ni dice nada de la categoría del
/// gasto. Por eso sólo cuentan para la regla 1 (ya clasificaste exactamente a
/// esa persona antes) — ni la raíz del nombre ni "la mayoría de tus Yapes son
/// Comida" son señales confiables ahí, así que esta última se quitó del todo.
enum SuggestionEngine {

    /// - Parameters:
    ///   - merchant: nombre crudo, tal como llega del parser (puede traer "YAPE - ").
    ///   - rules: `merchantCategories` de UserDefaults, [comercio: categoría].
    ///   - catalog: el de comercios conocidos; en pruebas, uno con archivo propio.
    static func suggest(for merchant: String,
                        rules: [String: String],
                        catalog: MerchantCatalog = .shared) -> CategorySuggestion? {

        // 1. Regla exacta ya guardada.
        if let exact = rules[merchant], exact != Accounting.unclassified {
            return CategorySuggestion(category: exact, confidence: 1.0, reason: "Ya tienes una regla para este comercio")
        }

        // Configuración › Asistente › Sugerencias de categoría. Apagadas, sólo
        // queda la regla exacta, que no es una propuesta sino lo ya decidido.
        guard AssistantSettings.suggestions else { return nil }

        let clean = normalize(Accounting.displayName(merchant))

        // 2. Misma raíz de nombre: "METRO 0231" contra la regla "Metro". No
        //    aplica a Yape/Plin/transferencias: ahí lo que se repite es un
        //    nombre de persona, no de negocio, y dos personas con nombres
        //    parecidos no son el mismo tipo de gasto.
        if !isPersonToPerson(merchant) {
            for (ruleMerchant, category) in rules where category != Accounting.unclassified {
                guard !isPersonToPerson(ruleMerchant) else { continue }
                let ruleClean = normalize(Accounting.displayName(ruleMerchant))
                guard ruleClean.count >= 4 else { continue }
                if clean.hasPrefix(ruleClean) || ruleClean.hasPrefix(clean) {
                    return CategorySuggestion(
                        category: category,
                        confidence: 0.9,
                        reason: "Se parece a " + Accounting.displayName(ruleMerchant)
                    )
                }
            }
        }

        // 3. Catálogo de comercios conocidos. Sólo como último recurso, y
        //    siempre pidiendo confirmación.
        //    Habla en nombres de fábrica: si el usuario quitó esa básica, no
        //    se sugiere nada; si la renombró o fusionó, va a la de ahora.
        if let raw = catalog.category(for: clean),
           let category = CategoryCatalog.shared.builtIns.resolve(raw) {
            return CategorySuggestion(
                category: category,
                confidence: 0.7,
                reason: "Suele ser " + category
            )
        }

        return nil
    }

    /// Categorías más usadas por el usuario, para los chips de la tarjeta.
    /// Se excluye la sugerencia para no repetir la misma opción dos veces.
    static func frequentCategories(history: [Expense],
                                   excluding: String?,
                                   limit: Int = 3) -> [String] {
        let classified = history.filter { $0.category != Accounting.unclassified }
        let counts = Dictionary(grouping: classified, by: { $0.category }).mapValues { $0.count }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { $0.key }
            .filter { $0 != excluding }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Helpers

    /// Yape, Plin y transferencias bancarias: el comercio es el nombre de la
    /// persona destinataria, puesto ahí por el parser correspondiente (ver
    /// `YapeParser`, `BBVAParser.parseBBVATransfer`). Si algún banco más suma
    /// su propio parser de transferencias con otro prefijo, hay que sumarlo
    /// aquí también.
    private static func isPersonToPerson(_ merchant: String) -> Bool {
        merchant.hasPrefix("YAPE - ") || merchant.hasPrefix("PLIN - ") || merchant.hasPrefix("BBVA - ")
            || merchant.hasPrefix("BCP - ") || merchant.hasPrefix("INTERBANK - ")
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_PE"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
