import BackgroundTasks
import Foundation
import UIKit

/// Lectura del correo con la app cerrada (`BGAppRefreshTask`).
///
/// **Por qué así y no de otra forma.** iOS no deja a una app mirar el correo
/// cuando quiera: no hay hilos corriendo en segundo plano ni temporizadores que
/// sobrevivan al cierre. Lo que sí hay es esta tarea, que el sistema despierta
/// cuando le parece —según la batería, la red y cuánto uses la app—, con unos
/// segundos para trabajar. Por eso el aviso de un gasto puede llegar unos
/// minutos después del correo, y por eso al abrir la app siempre se vuelve a
/// mirar: lo que el sistema no despertó, lo recoge la apertura.
///
/// **Cuesta casi nada.** Cada despertar es *una* petición `messages.list` a
/// Gmail (unos pocos KB) y sólo si aparece un correo sin procesar se descarga
/// ese mensaje. Si Gmail no está vinculado, ni siquiera se programa.
enum BackgroundSync {

    /// Debe coincidir con `BGTaskSchedulerPermittedIdentifiers` del Info.plist.
    static let taskIdentifier = "clmilo.Notifable.gmailRefresh"

    /// Lo antes que se le pide al sistema volver. Es un mínimo, no una
    /// promesa: iOS decide cuándo despierta de verdad.
    static let minimumInterval: TimeInterval = 15 * 60

    /// Margen propio: la tarea se da por terminada antes de que el sistema
    /// corte, para poder guardar y reprogramar la siguiente.
    private static let budget: Duration = .seconds(25)

    /// En `NotifableApp.init`: registrar después de que la app termine de
    /// lanzarse es un error fatal en iOS.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            handle(task)
        }
    }

    /// Se pide al pasar a segundo plano y después de cada vuelta: una tarea
    /// pendiente a la vez, y sin nada pendiente el sistema no vuelve nunca.
    static func schedule() {
        guard MailProviders.anyStoredSession else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minimumInterval)
        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // En el simulador siempre falla («unavailable»): no es un problema
            // de la app, pero conviene verlo en Diagnóstico.
            Diagnostics.shared.log("Lectura en segundo plano: no se pudo programar (\(error.localizedDescription))")
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        // Lo primero: pedir la siguiente. Si la app se cierra a mitad, la
        // cadena no se rompe.
        schedule()

        let work = Task { @MainActor in
            await run()
        }
        task.expirationHandler = { work.cancel() }

        Task { @MainActor in
            _ = await work.value
            task.setTaskCompleted(success: true)
        }
    }

    /// Una vuelta: mirar el correo y dejar que el resto de la app haga lo suyo
    /// —los gastos nuevos avisan desde `GmailSyncService`—.
    @MainActor
    static func run() async {
        guard MailProviders.anyConnected else {
            Diagnostics.shared.log("Lectura en segundo plano: sin correo vinculado")
            return
        }
        Diagnostics.shared.log("Lectura en segundo plano: inicio")
        GmailSyncService.shared.modelContext = AppModelContainer.shared.mainContext

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await GmailSyncService.shared.syncNow() }
            group.addTask { try? await Task.sleep(for: budget) }
            await group.next()
            group.cancelAll()
        }
        Diagnostics.shared.log("Lectura en segundo plano: fin")
    }
}
