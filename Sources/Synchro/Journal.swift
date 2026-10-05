import Foundation
import SynchroCore

/// Trace écrite de chaque synchronisation : ce qui devait être fait, puis ce qui l'a été.
/// Les suppressions étant définitives, c'est la seule mémoire de ce qui a disparu de la destination.
enum Journal {
    static let keep = 50

    static var folder: URL {
        AppModel.storeFolder.appendingPathComponent("Journal")
    }

    /// Écrit le plan complet avant de commencer, pour qu'une exécution interrompue laisse quand même une trace.
    /// Une erreur d'écriture du journal ne doit jamais empêcher la synchronisation : elle renvoie simplement `nil`.
    static func begin(task: String, source: String, destination: String, resolved: String, plan: SyncPlan) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = task.map { "/:\\".contains($0) ? "-" : $0 }.prefix(60)
        let url = folder.appendingPathComponent("\(Fmt.stamp(Date())) \(String(safeName)).txt")

        var lines = [
            "Synchro — journal de synchronisation",
            "Tâche : \(task)",
            "Source : \(source)",
            "Destination : \(destination)" + (destination == resolved ? "" : " (\(resolved))"),
            "Début : \(Date().formatted(date: .long, time: .standard))",
            "",
            "PLAN",
            "À copier : \(Fmt.count(plan.copies.count, "fichier", "fichiers")) (\(Fmt.bytes(plan.bytesToCopy)))",
            "À effacer : \(Fmt.count(plan.filesToDelete, "fichier", "fichiers")) (\(Fmt.bytes(plan.bytesToDelete)))",
            "Inchangés : \(plan.unchanged.formatted())",
        ]
        if plan.contentMismatches > 0 {
            lines.append("Contenu différent malgré une taille et une date identiques : \(plan.contentMismatches.formatted())")
        }
        if !plan.keptDirs.isEmpty {
            lines.append("")
            lines.append("DOSSIERS CONSERVÉS (ils contiennent un élément ignoré)")
            lines += plan.keptDirs.map { "  = \($0)" }
        }
        if !plan.conflicts.isEmpty {
            lines.append("")
            lines.append("CONFLITS (non copiés)")
            lines += plan.conflicts.map { "  ! \($0.rel) — \($0.reason)" }
        }
        if !plan.renames.isEmpty {
            lines.append("")
            lines.append("À RENOMMER (seules les majuscules changent)")
            lines += plan.renames.map { "  ~ \($0.from) → \($0.to)" }
        }
        lines.append("")
        lines.append("À EFFACER DE LA DESTINATION")
        lines += plan.deletes.map {
            $0.isDir ? "  - \($0.rel)/  (\(Fmt.count($0.files, "fichier", "fichiers")), \(Fmt.bytes($0.bytes)))" : "  - \($0.rel)  (\(Fmt.bytes($0.bytes)))"
        }
        lines.append("")
        lines.append("À COPIER")
        lines += plan.copies.map { "  + \($0.rel)  (\(Fmt.bytes($0.size)))" }
        lines.append("")

        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        prune()
        return url
    }

    static func finish(_ url: URL?, result: SyncResult) {
        guard let url, let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        let p = result.progress
        let status: String
        if result.cancelled {
            status = "arrêtée par l'utilisateur"
        } else if let reason = result.abortReason {
            status = "interrompue — \(reason)"
        } else if result.errors.isEmpty {
            status = "terminée"
        } else {
            status = "terminée avec " + Fmt.count(result.errors.count, "erreur", "erreurs")
        }
        var lines = [
            "",
            "RÉSULTAT",
            "État : \(status)",
            "Fin : \(result.finishedAt.formatted(date: .long, time: .standard))",
            "Durée : \(Fmt.duration(p.elapsed))",
            "Vitesse moyenne : \(Fmt.speed(result.averageSpeed))",
            "Copiés : \(p.copied.formatted()) (\(Fmt.bytes(p.bytesDone)))",
            "Effacés : \(p.deleted.formatted())",
            "En échec : \(p.failed.formatted())",
        ]
        if !result.errors.isEmpty {
            lines.append("")
            lines.append("ERREURS")
            lines += result.errors.map { "  ! \($0)" }
        }
        // Quand tout s'est bien passé, le plan ci-dessus dit déjà ce qui a été fait. Sinon, on précise jusqu'où on est allé.
        if !result.succeeded {
            lines.append("")
            lines.append("RÉELLEMENT EFFACÉ (\(result.deletedItems.count.formatted()))")
            lines += result.deletedItems.map { "  - \($0)" }
            lines.append("")
            lines.append("RÉELLEMENT COPIÉ (\(result.copiedFiles.count.formatted()))")
            lines += result.copiedFiles.map { "  + \($0)" }
        }
        lines.append("")
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(lines.joined(separator: "\n").utf8))
    }

    private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "txt" })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) else { return }
        for old in files.dropFirst(keep) { try? fm.removeItem(at: old) }
    }
}
