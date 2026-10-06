import AppKit
import Foundation
import SwiftUI
import SynchroCore

/// Une tâche de synchronisation enregistrée.
struct Preset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var source: String
    var destination: String
    var excludes: [String] = []
    var ignoreHidden = true

    // État de la dernière synchronisation réussie : il ne fait pas partie des réglages modifiables.
    var lastSync: Date?
    /// Destination et volume de la dernière synchronisation, pour remarquer qu'un autre disque a pris sa place.
    var syncedDestination: String?
    var syncedVolume: String?
    /// Début de l'analyse qui a précédé la dernière synchronisation réussie : tout fichier de la source
    /// touché depuis verra son contenu comparé, même si sa taille et sa date n'ont pas bougé.
    var verifiedSince: Date?
    /// Dossiers où une différence de contenu a été trouvée sans que la recopie aboutisse : à recomparer.
    var pendingFolders: [String] = []
    /// Dernière tentative qui ne s'est pas bien terminée, pour l'afficher dans la liste des tâches.
    var lastIssue: String?

    static let example = Preset(
        name: "SSD Photos → NAS",
        source: "/Volumes/Photos",
        destination: "smb://nas.local/Sauvegarde/Photos"
    )

    init(name: String, source: String, destination: String) {
        self.name = name
        self.source = source
        self.destination = destination
    }

    // Décodage tolérant : une clé absente (fichier d'une version antérieure) prend sa valeur par défaut
    // au lieu de rendre toutes les tâches illisibles.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Tâche"
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        destination = try c.decodeIfPresent(String.self, forKey: .destination) ?? ""
        excludes = try c.decodeIfPresent([String].self, forKey: .excludes) ?? []
        ignoreHidden = try c.decodeIfPresent(Bool.self, forKey: .ignoreHidden) ?? true
        lastSync = try c.decodeIfPresent(Date.self, forKey: .lastSync)
        syncedDestination = try c.decodeIfPresent(String.self, forKey: .syncedDestination)
        syncedVolume = try c.decodeIfPresent(String.self, forKey: .syncedVolume)
        verifiedSince = try c.decodeIfPresent(Date.self, forKey: .verifiedSince)
        pendingFolders = try c.decodeIfPresent([String].self, forKey: .pendingFolders) ?? []
        lastIssue = try c.decodeIfPresent(String.self, forKey: .lastIssue)
    }

    /// La même tâche, avec l'état de synchronisation d'une autre.
    func withRunState(of other: Preset?) -> Preset {
        var copy = self
        copy.lastSync = other?.lastSync
        copy.syncedDestination = other?.syncedDestination
        copy.syncedVolume = other?.syncedVolume
        copy.verifiedSince = other?.verifiedSince
        copy.pendingFolders = other?.pendingFolders ?? []
        copy.lastIssue = other?.lastIssue
        return copy
    }

    /// Vrai si les réglages modifiables sont identiques (l'état de synchronisation n'en fait pas partie).
    func sameSettings(as other: Preset) -> Bool {
        withRunState(of: nil) == other.withRunState(of: nil)
    }

    var sourcePath: String {
        (source.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
    }
}

/// Élément d'une liste décodé sans faire échouer les autres s'il est invalide.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// Ce que l'aperçu doit rappeler : de quelle tâche il s'agit et où elle écrit réellement.
struct PreviewContext {
    var taskName: String
    var source: String
    var destination: String
    var resolvedDestination: String
}

/// État affiché après une analyse ou une synchronisation terminée.
struct Outcome {
    /// `nil` quand l'analyse n'a rien trouvé à faire.
    var result: SyncResult?
    var unchanged: Int
    var finishedAt: Date
    var journal: URL?
    /// L'analyse n'a rien trouvé à faire parce que la source ne contient aucun fichier.
    var sourceEmpty = false
}

enum Phase {
    case idle
    case scanning
    case preview
    case running
    case done(Outcome)
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var presets: [Preset] { didSet { save() } }
    /// Modifications en attente : une tâche n'est réécrite qu'après « Enregistrer ».
    @Published var drafts: [UUID: Preset] = [:]
    @Published var selection: UUID?
    @Published var phase: Phase = .idle
    @Published var activePreset: UUID?
    @Published var scanStatus = ""
    @Published var stopping = false
    @Published var progress = SyncProgress()
    @Published var plan: SyncPlan?
    @Published var context: PreviewContext?
    /// Incrémenté quand le contenu des disques a pu changer : les listes de dossiers se rechargent.
    @Published var treeToken = 0
    /// Message à présenter une fois (tâches illisibles, enregistrement impossible).
    @Published var storeAlert: String?
    /// Simple information à montrer une fois (import, export).
    @Published var notice: String?
    @Published var treeCollapsed = UserDefaults.standard.bool(forKey: "treeCollapsed") {
        didSet { UserDefaults.standard.set(treeCollapsed, forKey: "treeCollapsed") }
    }

    /// Rouvre la fenêtre principale ; fourni par la vue, qui seule a accès à l'action SwiftUI.
    var reopenWindow: (() -> Void)?

    private var roots: Roots?
    /// Début de l'analyse qui a produit le plan affiché.
    private var analysisStart = Date()
    /// Un aperçu plus vieux que cela ne reflète plus forcément la destination : il faut refaire l'analyse.
    static let previewLifetime: TimeInterval = 30 * 60
    private var task: Task<Void, Never>?
    private var saveFailed = false
    /// Le fichier des tâches est illisible et n'a pas pu être mis de côté : on ne l'écrase pas.
    private var saveBlocked = false

    /// Dossier de rechange pour les tests, qui ne doivent jamais toucher aux tâches de l'utilisateur.
    nonisolated(unsafe) static var storeOverride: URL?

    nonisolated static var storeFolder: URL {
        let dir = storeOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Synchro")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var storeURL: URL { storeFolder.appendingPathComponent("presets.json") }

    init() {
        let (loaded, alert, blocked) = Self.load()
        presets = loaded
        storeAlert = alert
        saveBlocked = blocked
        selection = presets.first?.id
        // Des tâches invalides ont été écartées (une copie du fichier est gardée) : on réécrit le fichier assaini,
        // sinon la même alerte et une nouvelle copie reviendraient à chaque lancement.
        if alert != nil && !blocked { save() }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.treeToken += 1 }
            }
        }

        if let demo = ProcessInfo.processInfo.environment["SYNCHRO_DEMO"], demo != "apropos" { showDemo(demo) }
    }

    /// Relit les tâches. Un fichier présent mais illisible n'est jamais écrasé sans qu'une copie en ait été gardée.
    private static func load() -> (presets: [Preset], alert: String?, saveBlocked: Bool) {
        let fm = FileManager.default
        let url = storeURL
        guard fm.fileExists(atPath: url.path) else { return ([.example], nil, false) }

        var kept: [Preset] = []
        var problem: String?
        if let data = try? Data(contentsOf: url) {
            if let items = try? JSONDecoder().decode([Lossy<Preset>].self, from: data) {
                kept = items.compactMap(\.value)
                let skipped = items.count - kept.count
                if skipped == 0 { return (kept, nil, false) }
                problem = "\(Fmt.count(skipped, "tâche enregistrée n'a pas pu être relue et a été écartée", "tâches enregistrées n'ont pas pu être relues et ont été écartées"))."
            } else {
                problem = "Vos tâches n'ont pas pu être relues."
            }
        } else {
            problem = "Le fichier de vos tâches n'a pas pu être ouvert."
        }

        let backup = storeFolder.appendingPathComponent("presets.illisible \(Fmt.stamp(Date())).json")
        let saved = (try? fm.copyItem(at: url, to: backup)) != nil
        let where_ = "~/Library/Application Support/Synchro"
        let alert = saved
            ? "\(problem ?? "") Une copie de l'ancien fichier a été conservée sous le nom « \(backup.lastPathComponent) » dans \(where_)."
            : "\(problem ?? "") Aucune copie de sécurité n'a pu en être faite : le fichier d'origine, dans \(where_), ne sera pas modifié et vos changements ne seront pas enregistrés pendant cette session."
        return (kept.isEmpty ? [.example] : kept, alert, !saved)
    }

    private func save() {
        guard !saveBlocked else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(presets).write(to: Self.storeURL, options: .atomic)
            saveFailed = false
        } catch {
            if !saveFailed {
                storeAlert = "Les tâches n'ont pas pu être enregistrées : \(error.localizedDescription)"
            }
            saveFailed = true
        }
    }

    /// Fige un état fictif (« copie », « apercu », « fini »), uniquement pour les captures d'écran de la documentation.
    private func showDemo(_ state: String) {
        activePreset = selection
        let copied = 2_381, size: Int64 = 56_300_000
        var p = SyncProgress(bytesTotal: Int64(copied) * size, deleteItemsTotal: 3, startedAt: Date().addingTimeInterval(-767))
        p.phase = .copying
        p.copied = 1_478
        p.bytesDone = Int64(p.copied) * size
        p.deleted = 37
        p.deleteItemsDone = 3
        p.current = "2026/Islande/DSCF4821.RAF"
        p.speed = 108_000_000
        p.elapsed = 767
        var demo = SyncPlan()
        demo.unchanged = 48_912
        demo.sourceFiles = 48_912 + copied

        switch state {
        case "apercu":
            let day = Date()
            demo.copies = (0..<copied).map { Entry(rel: "2026/Islande/DSCF\(3_344 + $0).RAF", isDir: false, size: size, mtime: day) }
            demo.bytesToCopy = Int64(copied) * size
            demo.deletes = [
                DeleteItem(rel: "2025/Rejets", isDir: true, files: 31, bytes: 1_740_000_000),
                DeleteItem(rel: "2026/Islande/DSCF3302.RAF", isDir: false, files: 1, bytes: size),
                DeleteItem(rel: "Exports/Brouillons", isDir: true, files: 5, bytes: 48_000_000),
            ]
            demo.filesToDelete = 37
            demo.bytesToDelete = 1_844_300_000
            demo.openCatalogs = ["Lightroom Catalog/Lightroom Catalog.lrcat"]
            demo.keptDirs = ["Archives"]
            plan = demo
            context = PreviewContext(taskName: presets.first?.name ?? "", source: presets.first?.source ?? "",
                                     destination: "smb://nas.local/Sauvegarde/Photos", resolvedDestination: "/Volumes/Sauvegarde/Photos")
            phase = .preview
        case "fini":
            p.phase = .finished
            p.copied = copied
            p.bytesDone = p.bytesTotal
            p.elapsed = 1_262
            progress = p
            phase = .done(Outcome(result: SyncResult(progress: p, unchanged: 48_912), unchanged: 48_912, finishedAt: Date(), journal: nil))
        default:
            progress = p
            plan = demo
            phase = .running
        }
    }

    // MARK: - État

    var isBusy: Bool {
        switch phase {
        case .scanning, .preview, .running: return true
        default: return false
        }
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var isPreview: Bool {
        if case .preview = phase { return true }
        return false
    }

    func isActive(_ id: UUID) -> Bool { activePreset == id && isBusy }

    var activeName: String { presets.first { $0.id == activePreset }?.name ?? "" }

    // MARK: - Tâches

    func isDirty(_ id: UUID) -> Bool { drafts[id] != nil }

    func edit(_ new: Preset) {
        guard let saved = presets.first(where: { $0.id == new.id }) else { return }
        drafts[new.id] = new.sameSettings(as: saved) ? nil : new
    }

    func saveDraft(_ id: UUID) {
        guard let draft = drafts[id], let i = presets.firstIndex(where: { $0.id == id }) else { return }
        // Le brouillon a pu être créé avant la fin d'une synchro : l'état enregistré fait foi.
        // Si la source ou la destination change, ce n'est plus la même sauvegarde : son historique ne vaut plus.
        let sameFolders = draft.source == presets[i].source && draft.destination == presets[i].destination
        presets[i] = draft.withRunState(of: sameFolders ? presets[i] : nil)
        drafts[id] = nil
    }

    func saveAllDrafts() {
        for id in Array(drafts.keys) { saveDraft(id) }
    }

    func revertDraft(_ id: UUID) {
        drafts[id] = nil
    }

    func addPreset() {
        let p = Preset(name: "Nouvelle tâche", source: "", destination: "")
        presets.append(p)
        selection = p.id
    }

    func duplicate(_ id: UUID) {
        guard var p = (drafts[id] ?? presets.first(where: { $0.id == id }))?.withRunState(of: nil) else { return }
        p.id = UUID()
        p.name += " (copie)"
        presets.append(p)
        selection = p.id
    }

    /// Écrit les tâches dans un fichier, sans l'état des synchronisations (dates, volumes), qui ne vaut que pour ce Mac.
    func exportPresets(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let exported = presets.map { (drafts[$0.id] ?? $0).withRunState(of: nil) }
        try enc.encode(exported).write(to: url, options: .atomic)
    }

    /// Ajoute les tâches d'un fichier. Une tâche déjà présente à l'identique est passée ; une tâche qui porte
    /// l'identifiant d'une tâche existante mais diffère est ajoutée comme une copie. Renvoie le nombre de tâches ajoutées.
    func importPresets(from url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        guard let items = try? JSONDecoder().decode([Lossy<Preset>].self, from: data) else {
            throw SyncError("Ce fichier ne contient pas de tâches Synchro.")
        }
        var added = 0
        for var p in items.compactMap(\.value).map({ $0.withRunState(of: nil) }) {
            if let existing = presets.first(where: { $0.id == p.id }) {
                if existing.sameSettings(as: p) { continue }
                p.id = UUID()
                p.name += " (importée)"
            }
            presets.append(p)
            added += 1
        }
        if added > 0 { selection = presets.last?.id }
        return added
    }

    func remove(_ id: UUID) {
        guard !isActive(id) else { return }
        presets.removeAll { $0.id == id }
        drafts[id] = nil
        if selection == id { selection = presets.first?.id }
    }

    // MARK: - Synchronisation

    nonisolated private func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }

    private func keepAwake(_ reason: String) -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
    }

    /// Note qu'une synchronisation vient de réussir (ou que la sauvegarde a été trouvée à jour).
    private func markSynced(_ id: UUID?, at date: Date, roots: Roots, analysisStart: Date) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].lastSync = date
        presets[i].syncedDestination = presets[i].destination
        presets[i].syncedVolume = roots.dstVolume?.identity
        presets[i].verifiedSince = analysisStart
        presets[i].pendingFolders = []
        presets[i].lastIssue = nil
    }

    private func update(_ id: UUID?, _ change: (inout Preset) -> Void) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        change(&presets[i])
    }

    /// Étape 1 : analyse la source et la destination, puis présente l'aperçu. Rien n'est modifié.
    /// `verifyAll` : comparer aussi le contenu de tous les fichiers qui paraissent inchangés (lent).
    func analyze(_ preset: Preset, verifyAll: Bool = false) {
        guard !isBusy, !isDirty(preset.id) else { return }
        activePreset = preset.id
        phase = .scanning
        stopping = false
        scanStatus = "Connexion à la destination…"
        plan = nil
        Notifier.shared.prepare()
        let started = Date()
        let activity = keepAwake("Analyse en cours")

        task = Task.detached { [weak self] in
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                let fm = FileManager.default
                let srcPath = preset.sourcePath
                guard srcPath.hasPrefix("/") else {
                    throw SyncError(srcPath.isEmpty ? "Aucune source définie." : "Le chemin de la source est incomplet : \(preset.source)")
                }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: srcPath, isDirectory: &isDir), isDir.boolValue else {
                    throw SyncError("Source introuvable : \(preset.source). Le disque est-il branché ?")
                }
                // Un dossier désigné par un lien symbolique est analysé à son emplacement réel.
                let src = URL(fileURLWithPath: srcPath).resolvingSymlinksInPath()
                var dst = try Mounter.resolve(preset.destination)
                try Task.checkCancellation()
                try RootCheck.validate(src: src, dst: dst)

                var dstIsDir: ObjCBool = false
                let dstExists = fm.fileExists(atPath: dst.path, isDirectory: &dstIsDir)
                if dstExists {
                    guard dstIsDir.boolValue else { throw SyncError("La destination n'est pas un dossier : \(dst.path)") }
                    dst = dst.resolvingSymlinksInPath()
                } else if !fm.fileExists(atPath: dst.deletingLastPathComponent().path) {
                    // Un parent absent signale une faute de frappe ou un volume manquant, pas un dossier à créer.
                    throw SyncError("Destination introuvable : \(dst.path). Vérifiez l'adresse, ou créez d'abord le dossier.")
                }

                var last = Date.distantPast
                func status(_ text: @autoclosure () -> String) {
                    guard Date().timeIntervalSince(last) > 0.2 else { return }
                    last = Date()
                    let text = text()
                    self?.onMain { self?.scanStatus = text }
                }

                let excludes = Set(preset.excludes.map(Scanner.excludeKey))
                let srcScan = try Scanner.scan(root: src, excludes: excludes, ignoreHidden: preset.ignoreHidden) {
                    status("Analyse de la source — \($0.formatted()) éléments")
                }
                var dstScan = ScanResult()
                if dstExists {
                    dstScan = try Scanner.scan(root: dst, excludes: excludes, ignoreHidden: preset.ignoreHidden, flagHides: false) {
                        status("Analyse de la destination — \($0.formatted()) éléments")
                    }
                }
                try Task.checkCancellation()

                var options = PlanOptions(verifyFolders: Set(preset.pendingFolders), verifyAll: verifyAll)
                options.caseInsensitive = RootCheck.isCaseInsensitive(
                    at: dst, samples: dstScan.entries.values.lazy.filter { !$0.isDir }.prefix(50).map(\.rel))
                // Sans historique pour cette destination, on n'a pas de repère fiable : la règle ne s'applique pas encore.
                if let since = preset.verifiedSince, preset.syncedDestination == preset.destination {
                    options.reference = .date(since)
                }
                var plan = Scanner.plan(source: srcScan, destination: dstScan, options: options)
                plan.destinationExists = dstExists
                try Scanner.verifySuspects(&plan, src: src, dst: dst) { done, total in
                    status("Comparaison du contenu — \(done.formatted()) / \(total.formatted())")
                }
                plan.freeSpace = RootCheck.freeSpace(at: dst)
                let roots = Roots(src: src, dst: dst)
                if let volume = preset.syncedVolume, preset.syncedDestination == preset.destination,
                   let now = roots.dstVolume?.identity, now != volume {
                    plan.volumeWarning = "La destination ne se trouve plus sur le même volume qu'à la dernière synchronisation. Vérifiez que le bon disque ou le bon partage est connecté."
                }
                let context = PreviewContext(taskName: preset.name, source: src.path,
                                             destination: preset.destination, resolvedDestination: dst.path)
                try Task.checkCancellation()
                let ready = plan

                self?.onMain {
                    guard let self else { return }
                    self.stopping = false
                    let nothingToDo = ready.isEmpty && ready.conflicts.isEmpty
                    self.analysisStart = started
                    if nothingToDo {
                        // Rien à confirmer : on l'affiche dans la fenêtre au lieu d'ouvrir un aperçu vide.
                        let now = Date()
                        if ready.sourceFiles > 0 { self.markSynced(preset.id, at: now, roots: roots, analysisStart: started) }
                        self.plan = nil
                        self.phase = .done(Outcome(result: nil, unchanged: ready.unchanged, finishedAt: now, journal: nil,
                                                   sourceEmpty: ready.sourceFiles == 0))
                    } else {
                        self.roots = roots
                        self.plan = ready
                        self.context = context
                        self.phase = .preview
                    }
                    // L'analyse d'un NAS peut durer : on prévient si l'utilisateur est passé à autre chose.
                    if !NSApplication.shared.isActive || Date().timeIntervalSince(started) > 20 {
                        NSApplication.shared.requestUserAttention(.informationalRequest)
                        let title: String
                        if nothingToDo {
                            title = ready.sourceFiles > 0 ? "Tout est déjà à jour" : "Rien à synchroniser"
                        } else if ready.blockedReason != nil {
                            title = "Analyse terminée — suppression bloquée"
                        } else {
                            title = "Analyse terminée — à vous de confirmer"
                        }
                        Notifier.shared.post(
                            title: title,
                            body: nothingToDo || (ready.copies.isEmpty && ready.deletes.isEmpty)
                                ? preset.name
                                : "\(preset.name) — \(Fmt.count(ready.copies.count, "fichier à copier", "fichiers à copier")), \(ready.filesToDelete.formatted()) à effacer",
                            sound: "Glass")
                    }
                }
            } catch is CancellationError {
                self?.onMain {
                    self?.stopping = false
                    self?.phase = .idle
                }
            } catch {
                let message = error.localizedDescription
                self?.onMain {
                    self?.stopping = false
                    self?.phase = .failed(message)
                    if !NSApplication.shared.isActive {
                        Notifier.shared.post(title: "Analyse impossible", body: "\(preset.name) — \(message)", sound: "Basso")
                    }
                }
            }
        }
    }

    /// Étape 2 : exécute le plan approuvé dans l'aperçu.
    /// `acknowledged` : la case de confirmation d'une situation inhabituelle a été cochée.
    func confirm(acknowledged: Bool) {
        guard isPreview, let plan, let roots, let preset = presets.first(where: { $0.id == activePreset }),
              !plan.isEmpty, plan.blockedReason == nil, plan.risks.isEmpty || acknowledged else { return }
        let analysisStart = analysisStart
        guard Date().timeIntervalSince(analysisStart) < Self.previewLifetime else {
            // La destination a pu changer entre-temps : exécuter un vieux plan donnerait une sauvegarde incomplète.
            self.plan = nil
            phase = .failed("Cet aperçu date de plus de 30 minutes : rien n'a été modifié. Relancez la synchronisation pour repartir d'une analyse à jour.")
            return
        }
        // Noté avant de commencer : si la synchronisation est coupée net, ces dossiers seront recomparés.
        update(preset.id) { $0.pendingFolders = Array(Set($0.pendingFolders).union(plan.mismatchFolders)).sorted() }
        phase = .running
        stopping = false
        progress = SyncProgress(bytesTotal: plan.bytesToCopy, deleteItemsTotal: plan.deletes.count)
        let activity = keepAwake("Synchronisation en cours")
        let journal = Journal.begin(task: preset.name, source: roots.src.path, destination: preset.destination,
                                    resolved: roots.dst.path, plan: plan, acknowledged: acknowledged)

        task = Task.detached { [weak self] in
            let result: SyncResult
            // Le partage a pu être démonté pendant que l'aperçu attendait : on s'assure qu'il est toujours au même endroit.
            if let now = try? Mounter.resolve(preset.destination),
               now.resolvingSymlinksInPath().standardizedFileURL.path == roots.dst.standardizedFileURL.path
                || now.standardizedFileURL.path == roots.dst.standardizedFileURL.path {
                result = SyncRunner.run(plan: plan, roots: roots, acknowledged: acknowledged) { p in
                    self?.onMain { self?.progress = p }
                }
            } else {
                result = .refused("La destination n'est plus accessible au même emplacement : rien n'a été modifié. Relancez la synchronisation.", plan: plan)
            }
            Journal.finish(journal, result: result)

            self?.onMain {
                guard let self else { return }
                ProcessInfo.processInfo.endActivity(activity)
                self.progress = result.progress
                self.plan = nil
                self.stopping = false
                self.phase = .done(Outcome(result: result, unchanged: result.unchanged, finishedAt: result.finishedAt, journal: journal))
                self.treeToken += 1
                if result.succeeded {
                    self.markSynced(preset.id, at: result.finishedAt, roots: roots, analysisStart: analysisStart)
                } else {
                    // Les dossiers où une différence de contenu reste à réparer seront recomparés la prochaine fois.
                    let missing = Set(plan.copies.map(\.rel)).subtracting(result.copiedFiles)
                    let unfinished = Set(missing.map { ($0 as NSString).deletingLastPathComponent })
                    let when = Fmt.dateTime(result.finishedAt)
                    self.update(preset.id) {
                        $0.pendingFolders = $0.pendingFolders.filter { unfinished.contains($0) }
                        $0.lastIssue = result.cancelled ? "Arrêtée le \(when)"
                            : result.abortReason != nil ? "Interrompue le \(when)"
                            : "\(Fmt.count(result.errors.count, "erreur", "erreurs")) le \(when)"
                    }
                }
                guard !result.cancelled else { return }
                let p = result.progress
                let title: String
                if result.abortReason != nil {
                    title = "Synchronisation interrompue"
                } else if result.errors.isEmpty {
                    title = "Synchronisation terminée"
                } else {
                    title = "Terminée avec " + Fmt.count(result.errors.count, "erreur", "erreurs")
                }
                Notifier.shared.post(
                    title: title,
                    body: result.abortReason
                        ?? "\(preset.name) — \(Fmt.count(p.copied, "copié", "copiés")), \(Fmt.count(p.deleted, "effacé", "effacés")) · \(Fmt.duration(p.elapsed)) · \(Fmt.speed(result.averageSpeed))",
                    sound: result.succeeded ? "Glass" : "Basso")
            }
        }
    }

    /// Pour les tests : fait comme si l'aperçu affiché datait de `interval` secondes de plus.
    func agePreviewForTesting(by interval: TimeInterval) {
        analysisStart = analysisStart.addingTimeInterval(-interval)
    }

    /// Ferme l'aperçu sans rien exécuter.
    func cancelPreview() {
        guard isPreview else { return }
        plan = nil
        phase = .idle
    }

    func dismissResult() {
        switch phase {
        case .done, .failed: phase = .idle
        default: break
        }
    }

    func stop() {
        guard !stopping else { return }
        stopping = true
        task?.cancel()
    }
}

enum Fmt {
    /// L'interface est en français : les tailles le sont aussi (« 83,2 Go »), quels que soient les réglages
    /// régionaux, plutôt qu'un mélange d'unités françaises et de point décimal.
    private static let french = Locale(identifier: "fr")

    static func bytes(_ n: Int64) -> String {
        n.formatted(.byteCount(style: .file, allowedUnits: .all, spellsOutZero: false).locale(french))
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytesPerSecond > 0 ? bytes(Int64(bytesPerSecond)) + "/s" : "—"
    }

    static func duration(_ t: TimeInterval?) -> String {
        guard let t, t.isFinite, t >= 0 else { return "—" }
        let s = Int(t.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// « 1 erreur », « 3 erreurs ».
    static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n.formatted()) \(n < 2 ? one : many)"
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().day().month(.abbreviated).hour().minute())
    }

    /// Horodatage utilisable dans un nom de fichier.
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: date)
    }
}
