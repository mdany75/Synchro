import AppKit
import UserNotifications

/// Son et notification de fin de synchronisation.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    // UNUserNotificationCenter exige un vrai bundle d'app (absent en mode ligne de commande).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func prepare() {
        center?.delegate = self
        center?.requestAuthorization(options: [.alert]) { _, _ in }
    }

    func finished(title: String, body: String, success: Bool) {
        NSSound(named: success ? "Glass" : "Basso")?.play()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center?.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Affiche la bannière même si Synchro est au premier plan.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared

        if model.isRunning {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Une synchronisation est en cours"
            alert.informativeText = "Quitter maintenant l'arrête. Les fichiers déjà copiés sont conservés ; relancer la tâche reprendra le reste."
            alert.addButton(withTitle: "Continuer la synchronisation")
            alert.addButton(withTitle: "Quitter quand même")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }

        if !model.drafts.isEmpty {
            let names = model.drafts.values.map { "« \($0.name) »" }.sorted().joined(separator: ", ")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Enregistrer les modifications avant de quitter ?"
            alert.informativeText = "Modifications non enregistrées : \(names)."
            alert.addButton(withTitle: "Enregistrer")
            alert.addButton(withTitle: "Annuler")
            alert.addButton(withTitle: "Ne pas enregistrer")
            switch alert.runModal() {
            case .alertFirstButtonReturn: model.saveAllDrafts()
            case .alertSecondButtonReturn: return .terminateCancel
            default: break
            }
        }
        return .terminateNow
    }
}
