import Foundation
import SwiftUI

struct Preset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var source: String
    var destination: String
    var excludes: [String] = []
    var ignoreHidden = true
    var lastSync: Date?

    static let example = Preset(
        name: "SSD Photos → NAS",
        source: "/Volumes/Photos",
        destination: "smb://nas.local/Sauvegarde/Photos"
    )
}

enum Phase {
    case idle
    case scanning
    case preview
    case running
    case done(SyncResult)
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var presets: [Preset] { didSet { save() } }
    /// Modifications en attente : un préréglage n'est réécrit qu'après « Enregistrer ».
    @Published var drafts: [UUID: Preset] = [:]
    @Published var selection: UUID?
    @Published var phase: Phase = .idle
    @Published var activePreset: UUID?
    @Published var scanStatus = ""
    @Published var progress = SyncProgress()
    @Published var plan: SyncPlan?
    @Published var treeCollapsed = UserDefaults.standard.bool(forKey: "treeCollapsed") {
        didSet { UserDefaults.standard.set(treeCollapsed, forKey: "treeCollapsed") }
    }

    private var roots: (src: URL, dst: URL)?
    private var task: Task<Void, Never>?

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Synchro")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("presets.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.storeURL),
           let saved = try? JSONDecoder().decode([Preset].self, from: data) {
            presets = saved
        } else {
            presets = [.example]
        }
        selection = presets.first?.id
        // Fige un état « en cours » fictif, uniquement pour les captures d'écran du README.
        if ProcessInfo.processInfo.environment["SYNCHRO_DEMO"] != nil {
            activePreset = selection
            phase = .running
            plan = SyncPlan(unchanged: 48_912)
            progress = SyncProgress(bytesDone: 83_200_000_000, bytesTotal: 134_000_000_000, copied: 1_204, deleted: 37,
                                    current: "2026/Islande/DSCF4821.RAF", speed: 108_000_000, elapsed: 767)
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(presets).write(to: Self.storeURL, options: .atomic)
    }

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

    func isDirty(_ id: UUID) -> Bool { drafts[id] != nil }

    func edit(_ new: Preset) {
        guard let saved = presets.first(where: { $0.id == new.id }) else { return }
        drafts[new.id] = new == saved ? nil : new
    }

    func saveDraft(_ id: UUID) {
        guard let draft = drafts[id], let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i] = draft
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
        guard var p = drafts[id] ?? presets.first(where: { $0.id == id }) else { return }
        p.id = UUID()
        p.name += " (copie)"
        presets.append(p)
        selection = p.id
    }

    func remove(_ id: UUID) {
        guard !(isBusy && activePreset == id) else { return }
        presets.removeAll { $0.id == id }
        drafts[id] = nil
        if selection == id { selection = presets.first?.id }
    }

    nonisolated private func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }

    /// Étape 1 : analyse la source et la destination, puis présente l'aperçu. Rien n'est modifié.
    func analyze(_ preset: Preset) {
        guard !isBusy else { return }
        activePreset = preset.id
        phase = .scanning
        scanStatus = "Connexion à la destination…"
        plan = nil

        task = Task.detached { [weak self] in
            do {
                let srcPath = (preset.source.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                guard !srcPath.isEmpty, FileManager.default.fileExists(atPath: srcPath, isDirectory: &isDir), isDir.boolValue else {
                    throw SyncError("Source introuvable : \(preset.source). Le disque est-il branché ?")
                }
                let src = URL(fileURLWithPath: srcPath)
                let dst = try Mounter.resolve(preset.destination)
                if dst.standardizedFileURL.path == src.standardizedFileURL.path {
                    throw SyncError("La source et la destination sont identiques.")
                }
                let excludes = Set(preset.excludes.map(Scanner.key))

                var last = Date.distantPast
                func ticker(_ label: String) -> (Int) -> Void {
                    { count in
                        guard Date().timeIntervalSince(last) > 0.2 else { return }
                        last = Date()
                        self?.onMain { self?.scanStatus = "\(label) — \(count.formatted()) éléments" }
                    }
                }

                let srcScan = try Scanner.scan(root: src, excludes: excludes, ignoreHidden: preset.ignoreHidden, tick: ticker("Analyse de la source"))
                var dstScan = Scanner.Result()
                if FileManager.default.fileExists(atPath: dst.path) {
                    dstScan = try Scanner.scan(root: dst, excludes: excludes, ignoreHidden: preset.ignoreHidden, tick: ticker("Analyse de la destination"))
                }
                let plan = Scanner.plan(source: srcScan, destination: dstScan)
                self?.onMain {
                    self?.roots = (src, dst)
                    self?.plan = plan
                    self?.phase = .preview
                }
            } catch is CancellationError {
                self?.onMain { self?.phase = .idle }
            } catch {
                let message = error.localizedDescription
                self?.onMain { self?.phase = .failed(message) }
            }
        }
    }

    /// Étape 2 : exécute le plan approuvé dans l'aperçu.
    func confirm() {
        guard isPreview, let plan, let roots else { return }
        phase = .running
        progress = SyncProgress(bytesTotal: plan.bytesToCopy)
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Synchronisation en cours")

        let id = activePreset
        let name = presets.first(where: { $0.id == id })?.name ?? "Synchro"
        Notifier.shared.prepare()
        task = Task.detached { [weak self] in
            let result = SyncRunner.run(plan: plan, src: roots.src, dst: roots.dst) { p in
                self?.onMain { self?.progress = p }
            }
            self?.onMain {
                ProcessInfo.processInfo.endActivity(activity)
                self?.progress = result.progress
                self?.plan = nil
                self?.phase = .done(result)
                if !result.cancelled {
                    let p = result.progress
                    Notifier.shared.finished(
                        title: result.errors.isEmpty ? "Synchronisation terminée" : "Terminée avec \(result.errors.count) erreur(s)",
                        body: "\(name) — \(p.copied.formatted()) copiés, \(p.deleted.formatted()) effacés · \(Fmt.duration(p.elapsed)) · \(Fmt.speed(result.averageSpeed))",
                        success: result.errors.isEmpty)
                }
                if !result.cancelled, result.errors.isEmpty, let i = self?.presets.firstIndex(where: { $0.id == id }) {
                    self?.presets[i].lastSync = Date()
                }
            }
        }
    }

    func cancelPreview() {
        guard isPreview else { return }
        plan = nil
        phase = .idle
    }

    func stop() {
        task?.cancel()
    }
}

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
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
}
