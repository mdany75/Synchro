import AppKit
import UserNotifications

/// Son et notification quand une analyse ou une synchronisation demande l'attention.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    /// Ni son ni notification : pour les tests.
    var muted = false

    // UNUserNotificationCenter exige un vrai bundle d'app (absent en mode ligne de commande).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func prepare() {
        guard !muted else { return }
        center?.delegate = self
        center?.requestAuthorization(options: [.alert]) { _, _ in }
    }

    func post(title: String, body: String, sound: String) {
        guard !muted else { return }
        NSSound(named: sound)?.play()
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
    /// `--snapshot <fichier.png>` : enregistre l'image de la fenêtre (et de la feuille d'aperçu, le cas échéant)
    /// puis quitte. Le rendu se fait hors écran, donc aussi quand la session est verrouillée.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), args.count > i + 1 else { return }
        let target = URL(fileURLWithPath: args[i + 1])
        if ProcessInfo.processInfo.environment["SYNCHRO_DEMO"] == "apropos" { About.show() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for (n, window) in NSApp.windows.filter({ $0.contentView != nil && $0.frame.width > 200 }).enumerated() {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = n == 0 ? target : target.deletingPathExtension().appendingPathExtension("\(n + 1).png")
                // En sRGB : sans cela l'image embarque le profil de couleur de l'écran de la machine.
                let image = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
                try? image.representation(using: .png, properties: [:])?.write(to: url)
            }
            exit(0)
        }
    }

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
            if alert.runModal() == .alertFirstButtonReturn { return stay(model) }
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
            case .alertSecondButtonReturn: return stay(model)
            default: break
            }
        }

        guard model.isRunning else { return .terminateNow }
        // On laisse le moteur s'arrêter proprement (fichier temporaire retiré) avant de quitter, sans attendre indéfiniment.
        model.stop()
        let deadline = Date().addingTimeInterval(5)
        // Modes « communs » : après .terminateLater, AppKit fait tourner la boucle dans un mode modal
        // où un minuteur ordinaire ne se déclencherait jamais, et l'app resterait bloquée.
        let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard !AppModel.shared.isRunning || Date() > deadline else { return }
                timer.invalidate()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return .terminateLater
    }

    /// Annule la fermeture. Si elle venait de la fermeture de la fenêtre, celle-ci est rouverte :
    /// une synchronisation ne doit jamais continuer sans rien d'affiché.
    private func stay(_ model: AppModel) -> NSApplication.TerminateReply {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                    model.reopenWindow?()
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        return .terminateCancel
    }
}
