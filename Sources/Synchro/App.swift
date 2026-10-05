import SwiftUI
import SynchroCore

@main
struct SynchroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    init() {
        CLI.runIfRequested()
    }

    var body: some Scene {
        Window("Synchro", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 880, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("À propos de Synchro") { About.show() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Nouvelle tâche") { model.addPreset() }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("Afficher les journaux") {
                    try? FileManager.default.createDirectory(at: Journal.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Journal.folder)
                }
            }
        }
    }
}

enum About {
    /// Fenêtre « À propos » standard, avec la seule version (« Version 1.1 ») : le numéro de compilation
    /// que macOS ajoute entre parenthèses n'apprend rien à l'utilisateur.
    @MainActor static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.version: ""])
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Mode ligne de commande, pour vérifier le moteur sans interface :
///   Synchro --plan <source> <destination> [--exclude <chemin>]... [--comparer-tout] [--run [--confirmer]]
/// `--plan` seul n'écrit rien. `--run` exécute le plan aussitôt, sans aperçu à confirmer, avec les garde-fous
/// du moteur ; `--confirmer` tient lieu de la case à cocher exigée pour une situation inhabituelle.
/// `--comparer-tout` compare le contenu de tous les fichiers qui paraissent inchangés.
/// `--repere-copie` compare aussi ceux qui ont été touchés après l'écriture de leur copie de destination ;
/// à réserver aux destinations locales : un NAS ne date pas ses copies de façon comparable, et tout y passerait.
/// Les fichiers cachés sont toujours ignorés et aucun journal n'est écrit.
enum CLI {
    static func runIfRequested() {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let i = args.firstIndex(of: "--plan"), args.count >= i + 3 else { return }
        let src = URL(fileURLWithPath: args[i + 1]).resolvingSymlinksInPath()
        let dstArg = args[i + 2]
        args.removeSubrange(i...i + 2)
        var excludes: Set<String> = []
        while let e = args.firstIndex(of: "--exclude"), args.count > e + 1 {
            excludes.insert(Scanner.excludeKey(args[e + 1]))
            args.removeSubrange(e...e + 1)
        }
        do {
            var dst = try Mounter.resolve(dstArg)
            try RootCheck.validate(src: src, dst: dst)
            let dstExists = FileManager.default.fileExists(atPath: dst.path)
            if dstExists {
                dst = dst.resolvingSymlinksInPath()
            } else if !FileManager.default.fileExists(atPath: dst.deletingLastPathComponent().path) {
                throw SyncError("Destination introuvable : \(dst.path). Vérifiez l'adresse, ou créez d'abord le dossier.")
            }
            let s = try Scanner.scan(root: src, excludes: excludes, ignoreHidden: true) { _ in }
            let d = dstExists
                ? try Scanner.scan(root: dst, excludes: excludes, ignoreHidden: true, flagHides: false) { _ in }
                : ScanResult()
            var options = PlanOptions(reference: args.contains("--repere-copie") ? .destinationCopy : .none,
                                      verifyAll: args.contains("--comparer-tout"))
            options.caseInsensitive = RootCheck.isCaseInsensitive(
                at: dst, samples: d.entries.values.lazy.filter { !$0.isDir }.prefix(50).map(\.rel))
            var plan = Scanner.plan(source: s, destination: d, options: options)
            plan.destinationExists = dstExists
            try Scanner.verifySuspects(&plan, src: src, dst: dst) { _, _ in }
            plan.freeSpace = RootCheck.freeSpace(at: dst)

            print("destination: \(dst.path)\(dstExists ? "" : " (à créer)")")
            print("copier: \(plan.copies.count) (\(Fmt.bytes(plan.bytesToCopy)))  effacer: \(plan.filesToDelete) fichiers, \(plan.deletes.count) éléments (\(Fmt.bytes(plan.bytesToDelete)))  inchangés: \(plan.unchanged)  dossiers à créer: \(plan.dirs.count)")
            if plan.verified > 0 { print("contenu comparé: \(plan.verified), différents: \(plan.contentMismatches)") }
            for k in plan.keptDirs { print("  = \(k) (conservé : contient un élément ignoré)") }
            for c in plan.conflicts { print("  ! \(c.rel) (non copié : \(c.reason))") }
            for r in plan.renames { print("  ~ \(r.from) → \(r.to)") }
            if !plan.temps.isEmpty { print("  restes de copies interrompues à nettoyer : \(plan.temps.count)") }
            for c in plan.openCatalogs { print("  ! catalogue Lightroom ouvert : \(c)") }
            for e in plan.deletes.prefix(40) { print("  - \(e.rel)\(e.isDir ? "/ (\(e.files) fichiers)" : "")") }
            for e in plan.copies.prefix(40) { print("  + \(e.rel)") }
            if let blocked = plan.blockedReason { print("bloqué: \(blocked)") }
            for risk in plan.risks { print("risque: \(risk)") }
            if let missing = plan.spaceShortfall { print("espace insuffisant: il manque \(Fmt.bytes(missing))") }

            if args.contains("--run") {
                let r = SyncRunner.run(plan: plan, roots: Roots(src: src, dst: dst), acknowledged: args.contains("--confirmer")) { _ in }
                print("copiés: \(r.progress.copied)  effacés: \(r.progress.deleted)  échecs: \(r.progress.failed)  durée: \(Fmt.duration(r.progress.elapsed))  vitesse: \(Fmt.speed(r.averageSpeed))")
                for e in r.errors { print("  ! \(e)") }
                exit(r.succeeded ? 0 : 2)
            }
            exit(0)
        } catch {
            print("erreur: \(error.localizedDescription)")
            exit(1)
        }
    }
}
