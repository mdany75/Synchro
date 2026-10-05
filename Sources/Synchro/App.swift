import SwiftUI

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
                .frame(minWidth: 860, minHeight: 620)
        }
    }
}

/// Mode ligne de commande pour vérifier le moteur sans interface :
///   Synchro --plan <source> <destination> [--exclude <chemin>]... [--run]
enum CLI {
    static func runIfRequested() {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let i = args.firstIndex(of: "--plan"), args.count >= i + 3 else { return }
        let src = URL(fileURLWithPath: args[i + 1])
        let dstArg = args[i + 2]
        args.removeSubrange(i...i + 2)
        var excludes: Set<String> = []
        while let e = args.firstIndex(of: "--exclude"), args.count > e + 1 {
            excludes.insert(Scanner.key(args[e + 1]))
            args.removeSubrange(e...e + 1)
        }
        do {
            let dst = try Mounter.resolve(dstArg)
            let s = try Scanner.scan(root: src, excludes: excludes, ignoreHidden: true) { _ in }
            let d = FileManager.default.fileExists(atPath: dst.path)
                ? try Scanner.scan(root: dst, excludes: excludes, ignoreHidden: true) { _ in }
                : Scanner.Result()
            let plan = Scanner.plan(source: s, destination: d)
            print("destination: \(dst.path)")
            print("copier: \(plan.copies.count) (\(Fmt.bytes(plan.bytesToCopy)))  effacer: \(plan.filesToDelete) fichiers, \(plan.deletes.count) éléments (\(Fmt.bytes(plan.bytesToDelete)))  inchangés: \(plan.unchanged)  dossiers à créer: \(plan.dirs.count)")
            for e in plan.deletes.prefix(40) { print("  - \(e.rel)") }
            for e in plan.copies.prefix(40) { print("  + \(e.rel)") }
            if args.contains("--run") {
                let r = SyncRunner.run(plan: plan, src: src, dst: dst) { _ in }
                print("copiés: \(r.progress.copied)  effacés: \(r.progress.deleted)  durée: \(Fmt.duration(r.progress.elapsed))  vitesse: \(Fmt.speed(r.averageSpeed))  erreurs: \(r.errors)")
            }
            exit(0)
        } catch {
            print("erreur: \(error.localizedDescription)")
            exit(1)
        }
    }
}
