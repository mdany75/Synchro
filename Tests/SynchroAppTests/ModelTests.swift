import Foundation
import Testing
@testable import Synchro
@testable import SynchroCore

/// Une app sans fenêtre : ses tâches sont rangées dans un dossier temporaire, et elle reste muette.
@MainActor
final class Bench {
    let root: URL
    let model: AppModel
    let fm = FileManager.default
    var src: URL { root.appendingPathComponent("src") }
    var dst: URL { root.appendingPathComponent("dst") }

    init(presetsJSON: String? = nil) throws {
        root = fm.temporaryDirectory.appendingPathComponent("synchro-app-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("dst"), withIntermediateDirectories: true)
        let store = root.appendingPathComponent("store")
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        if let presetsJSON {
            try Data(presetsJSON.utf8).write(to: store.appendingPathComponent("presets.json"))
        }
        AppModel.storeOverride = store
        Notifier.shared.muted = true
        model = AppModel()
        if presetsJSON == nil {
            model.presets = [Preset(name: "Essai", source: src.path, destination: dst.path)]
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var task: Preset { model.presets[0] }

    @discardableResult
    func write(_ rel: String, in base: URL, _ content: String = "x", mtime: Date? = nil) throws -> URL {
        let url = base.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        if let mtime { try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path) }
        return url
    }

    func read(_ rel: String, in base: URL) -> String? {
        (try? Data(contentsOf: base.appendingPathComponent(rel))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Attend que l'analyse ou la synchronisation en cours rende la main.
    func settle() async throws {
        for _ in 0..<1_000 {
            switch model.phase {
            case .scanning, .running: try await Task.sleep(nanoseconds: 10_000_000)
            default: return
            }
        }
        Issue.record("l'app n'a pas fini à temps")
    }

    func analyze(verifyAll: Bool = false) async throws {
        model.analyze(task, verifyAll: verifyAll)
        try await settle()
    }

    func confirm(acknowledged: Bool = false) async throws {
        model.confirm(acknowledged: acknowledged)
        try await settle()
    }

    var outcome: Outcome? {
        if case .done(let outcome) = model.phase { return outcome }
        return nil
    }

    var failure: String? {
        if case .failed(let message) = model.phase { return message }
        return nil
    }
}

private let old = Date(timeIntervalSince1970: 1_600_000_000)

// Les tests partagent un dossier de rangement global : ils s'exécutent l'un après l'autre.
@MainActor
@Suite(.serialized)
struct ModelTests {
    @Test func deroulementNormal() async throws {
        let bench = try Bench()
        try bench.write("2026/a.raf", in: bench.src, "nouveau")
        try bench.write("garde.txt", in: bench.src, mtime: old)
        try bench.write("garde.txt", in: bench.dst, mtime: old)
        try bench.write("vieux.txt", in: bench.dst)

        let before = Date()
        try await bench.analyze()
        #expect(bench.model.isPreview)
        #expect(bench.model.plan?.copies.count == 1)
        #expect(bench.read("2026/a.raf", in: bench.dst) == nil)   // l'analyse n'écrit rien

        try await bench.confirm()
        let outcome = try #require(bench.outcome)
        #expect(outcome.result?.succeeded == true)
        #expect(bench.read("2026/a.raf", in: bench.dst) == "nouveau")
        #expect(bench.read("vieux.txt", in: bench.dst) == nil)

        let task = bench.task
        #expect(task.lastSync != nil && task.lastIssue == nil && task.pendingFolders.isEmpty)
        #expect(task.syncedDestination == task.destination && task.syncedVolume != nil)
        #expect(try #require(task.verifiedSince) >= before.addingTimeInterval(-1))

        let journal = try String(contentsOf: try #require(outcome.journal), encoding: .utf8)
        #expect(journal.contains("+ 2026/a.raf") && journal.contains("- vieux.txt") && journal.contains("État : terminée"))

        // L'état est bien enregistré : une app relancée le retrouve.
        #expect(AppModel().presets.first?.lastSync == task.lastSync)
    }

    @Test func rienAFaireSansAperçu() async throws {
        let bench = try Bench()
        try bench.write("a.txt", in: bench.src, mtime: old)
        try bench.write("a.txt", in: bench.dst, mtime: old)
        try await bench.analyze()
        let outcome = try #require(bench.outcome)
        #expect(outcome.result == nil && !outcome.sourceEmpty && outcome.unchanged == 1)
        #expect(bench.model.plan == nil && !bench.model.isPreview)
        #expect(bench.task.lastSync != nil)
    }

    @Test func sourceVideNEstPasUneSauvegardeAJour() async throws {
        let bench = try Bench()
        try await bench.analyze()
        #expect(bench.outcome?.sourceEmpty == true)
        #expect(bench.task.lastSync == nil)
    }

    @Test func suppressionInhabituelleExigeLaCase() async throws {
        let bench = try Bench()
        try bench.write("nouveau.raf", in: bench.src)
        try bench.write("autre-sauvegarde/important.doc", in: bench.dst, "sans rapport")
        try await bench.analyze()
        #expect(bench.model.plan?.risks.isEmpty == false)

        try await bench.confirm(acknowledged: false)
        #expect(bench.model.isPreview)   // rien ne s'est passé
        #expect(bench.read("autre-sauvegarde/important.doc", in: bench.dst) == "sans rapport")

        try await bench.confirm(acknowledged: true)
        #expect(bench.outcome?.result?.succeeded == true)
        #expect(bench.read("nouveau.raf", in: bench.dst) != nil)
    }

    @Test func sourceVideBloquee() async throws {
        let bench = try Bench()
        try bench.write("2025/p.raf", in: bench.dst, "sauvegarde")
        try await bench.analyze()
        #expect(bench.model.plan?.blockedReason != nil)
        try await bench.confirm(acknowledged: true)
        #expect(bench.model.isPreview)
        #expect(bench.read("2025/p.raf", in: bench.dst) == "sauvegarde")
    }

    @Test func dossiersImbriquesRefusesALAnalyse() async throws {
        let bench = try Bench()
        bench.model.presets[0].destination = bench.root.path   // la destination contient la source
        try await bench.analyze()
        #expect(bench.failure?.contains("contient la source") == true)
    }

    /// Une recopie échoue après une renumérotation : la tâche retient le dossier, et l'analyse suivante répare.
    @Test func reparationInacheveeRetenueParLaTache() async throws {
        let bench = try Bench()
        for i in 1...6 {
            try bench.write("Rafale/IMG_000\(i).RAF", in: bench.src, String(repeating: "x", count: 3_000) + "\(i)", mtime: old)
        }
        try await bench.analyze()
        try await bench.confirm()
        #expect(bench.outcome?.result?.succeeded == true)

        try bench.fm.removeItem(at: bench.src.appendingPathComponent("Rafale/IMG_0001.RAF"))
        for i in 2...6 {
            try bench.fm.moveItem(at: bench.src.appendingPathComponent("Rafale/IMG_000\(i).RAF"),
                                  to: bench.src.appendingPathComponent("Rafale/IMG_000\(i - 1).RAF"))
        }
        let blocked = bench.src.appendingPathComponent("Rafale/IMG_0003.RAF")
        try bench.fm.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        try await bench.analyze()
        #expect(bench.model.plan?.mismatchFolders == ["Rafale"])
        try await bench.confirm()
        try bench.fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: blocked.path)

        #expect(bench.outcome?.result?.succeeded == false)
        #expect(bench.task.pendingFolders == ["Rafale"])
        #expect(bench.task.lastIssue != nil)
        #expect(AppModel().presets.first?.pendingFolders == ["Rafale"])   // retenu même si l'app est relancée

        try await bench.analyze()
        #expect(bench.model.plan?.copies.map(\.rel) == ["Rafale/IMG_0003.RAF"])
        try await bench.confirm()
        #expect(bench.outcome?.result?.succeeded == true)
        #expect(bench.read("Rafale/IMG_0003.RAF", in: bench.dst)?.hasSuffix("4") == true)
        #expect(bench.task.pendingFolders.isEmpty && bench.task.lastIssue == nil)
    }

    @Test func fichierReecritSurPlaceDetecteApresUneSynchro() async throws {
        let bench = try Bench()
        let photo = try bench.write("photo.dng", in: bench.src, String(repeating: "a", count: 5_000), mtime: old)
        try bench.write("autre.jpg", in: bench.src, "autre", mtime: old)
        try await bench.analyze()
        try await bench.confirm()

        try await Task.sleep(nanoseconds: 50_000_000)
        try Data(String(repeating: "b", count: 5_000).utf8).write(to: photo)
        try bench.fm.setAttributes([.modificationDate: old], ofItemAtPath: photo.path)
        try await bench.analyze()
        #expect(bench.model.plan?.copies.map(\.rel) == ["photo.dng"])
    }

    @Test func aperçuPerime() async throws {
        let bench = try Bench()
        try bench.write("a.txt", in: bench.src)
        try await bench.analyze()
        #expect(bench.model.isPreview)
        bench.model.agePreviewForTesting(by: AppModel.previewLifetime + 1)
        try await bench.confirm()
        #expect(bench.failure?.contains("30 minutes") == true)
        #expect(bench.read("a.txt", in: bench.dst) == nil)
    }

    @Test func changerDeDestinationEffaceLHistorique() async throws {
        let bench = try Bench()
        try bench.write("a.txt", in: bench.src)
        try await bench.analyze()
        try await bench.confirm()
        #expect(bench.task.lastSync != nil)

        var renamed = bench.task
        renamed.name = "Autre nom"
        bench.model.edit(renamed)
        bench.model.saveDraft(renamed.id)
        #expect(bench.task.name == "Autre nom" && bench.task.lastSync != nil)   // un simple renommage garde l'historique

        var moved = bench.task
        moved.destination = bench.root.appendingPathComponent("ailleurs").path
        bench.model.edit(moved)
        #expect(bench.model.isDirty(moved.id))
        bench.model.saveDraft(moved.id)
        #expect(bench.task.lastSync == nil && bench.task.verifiedSince == nil && bench.task.syncedVolume == nil)
    }

    @Test func autreVolumeDemandeConfirmation() async throws {
        let bench = try Bench()
        try bench.write("a.txt", in: bench.src)
        try await bench.analyze()
        try await bench.confirm()
        bench.model.presets[0].syncedVolume = "un-autre-disque"
        try bench.write("b.txt", in: bench.src)
        try await bench.analyze()
        #expect(bench.model.plan?.volumeWarning != nil)
        try await bench.confirm(acknowledged: false)
        #expect(bench.model.isPreview && bench.read("b.txt", in: bench.dst) == nil)
        try await bench.confirm(acknowledged: true)
        #expect(bench.read("b.txt", in: bench.dst) != nil)
        #expect(bench.task.syncedVolume != "un-autre-disque")
    }

    @Test func tachesPartiellementIllisibles() throws {
        let id = UUID().uuidString
        let json = """
        [{"id":"\(id)","name":"Bonne","source":"/a","destination":"/b","excludes":["x"]},
         {"id":"pas-un-identifiant","name":"Cassée","source":"/c","destination":"/d"},
         {"name":"Ancienne version, sans identifiant","source":"/e","destination":"/f"}]
        """
        let bench = try Bench(presetsJSON: json)
        #expect(bench.model.presets.map(\.name) == ["Bonne", "Ancienne version, sans identifiant"])
        #expect(bench.model.presets[0].excludes == ["x"])
        #expect(bench.model.storeAlert != nil)
        let store = try #require(AppModel.storeOverride)
        let backups = try bench.fm.contentsOfDirectory(atPath: store.path).filter { $0.hasPrefix("presets.illisible") }
        #expect(backups.count == 1)
        #expect(try String(contentsOf: store.appendingPathComponent(backups[0]), encoding: .utf8) == json)
        // Le fichier assaini est réécrit : pas de nouvelle alerte ni de nouvelle copie au lancement suivant.
        #expect(AppModel().storeAlert == nil)
    }

    @Test func fichierDeTachesIllisible() throws {
        let bench = try Bench(presetsJSON: "{ ceci n'est pas une liste de tâches")
        #expect(bench.model.presets.map(\.name) == [Preset.example.name])
        #expect(bench.model.storeAlert != nil)
        let store = try #require(AppModel.storeOverride)
        #expect(try bench.fm.contentsOfDirectory(atPath: store.path).contains { $0.hasPrefix("presets.illisible") })
    }
}
