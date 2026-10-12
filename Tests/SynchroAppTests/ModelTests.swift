import Foundation
import SwiftUI
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

@MainActor
    @Test func exporterPuisImporter() throws {
        let bench = try Bench()
        bench.model.presets[0].excludes = ["Rejets"]
        bench.model.presets[0].lastSync = Date()
        let file = bench.root.appendingPathComponent("taches.json")
        try bench.model.exportPresets(to: file)

        // Réimporter le même fichier n'ajoute rien ; une tâche différente est ajoutée sans son historique.
        #expect(try bench.model.importPresets(from: file) == 0)
        var other = try #require(try JSONDecoder().decode([Preset].self, from: Data(contentsOf: file)).first)
        #expect(other.lastSync == nil && other.excludes == ["Rejets"])
        other.name = "Vidéos"
        other.destination = "/ailleurs"
        try JSONEncoder().encode([other]).write(to: file)
        #expect(try bench.model.importPresets(from: file) == 1)
        #expect(bench.model.presets.map(\.name) == ["Essai", "Vidéos (importée)"])
        #expect(bench.model.presets[1].id != bench.model.presets[0].id)
        #expect(bench.model.selection == bench.model.presets[1].id)

        try Data("pas du JSON".utf8).write(to: file)
        #expect(throws: SyncError.self) { try bench.model.importPresets(from: file) }
    }

    /// Le mode Image se lit dans le fichier des tâches, et une tâche d'avant cette option est en mode Copie.
    @Test func modeImageDeLaTache() async throws {
        let bench = try Bench(presetsJSON: """
        [{"name": "Ancienne", "source": "/a", "destination": "/b"},
         {"name": "Image", "source": "/a", "destination": "/b", "mirrorIgnored": true}]
        """)
        #expect(bench.model.presets.map(\.mirrorIgnored) == [false, true])

        let bench2 = try Bench()
        try bench2.write("garde.txt", in: bench2.src, mtime: old)
        try bench2.write("garde.txt", in: bench2.dst, mtime: old)
        try bench2.write("Rejets/r.txt", in: bench2.src)
        try bench2.write("Rejets/r.txt", in: bench2.dst)
        bench2.model.presets[0].excludes = ["Rejets"]
        bench2.model.presets[0].mirrorIgnored = true
        try await bench2.analyze()
        #expect(bench2.model.context?.mirrorIgnored == true)
        #expect(bench2.model.plan?.deletes.map(\.rel) == ["Rejets"])
        try await bench2.confirm(acknowledged: true)
        #expect(bench2.outcome?.result?.succeeded == true)
        #expect(!bench2.fm.fileExists(atPath: bench2.dst.appendingPathComponent("Rejets").path))
        #expect(bench2.read("Rejets/r.txt", in: bench2.src) != nil)
    }

    /// Actions par lot sur les éléments ignorés.
    @Test func ignorerParLot() throws {
        let bench = try Bench()
        for name in ["2024", "2025", "Exports", "Rejets"] { try bench.write("\(name)/f.raf", in: bench.src) }
        try bench.write("Lisez-moi.txt", in: bench.src)
        var preset = bench.task
        let binding = Binding(get: { preset }, set: { preset = $0 })

        Batch.ignore(["2024", "Rejets", "2024"], in: binding)
        #expect(preset.excludes == ["2024", "Rejets"])
        Batch.allow(["2024"], in: binding)
        #expect(preset.excludes == ["Rejets"])

        Batch.ignoreAll(in: bench.src, rel: "", except: ["Exports", "Lisez-moi.txt"], preset: binding)
        #expect(Set(preset.excludes) == ["2024", "2025", "Rejets"])

        Batch.ignore(["Exports/f.raf"], in: binding)
        Batch.allowAll(under: "Exports", preset: binding)
        #expect(Set(preset.excludes) == ["2024", "2025", "Rejets"])
        preset.excludes = []
        Batch.ignoreAll(in: bench.src, rel: "", except: [], preset: binding)
        #expect(Set(preset.excludes) == ["2024", "2025", "Exports", "Rejets", "Lisez-moi.txt"])
    }

    /// Pastilles : identique, différent ou absent, dossier par dossier, sans rien connecter.
    @Test func etatSurLaDestination() throws {
        let bench = try Bench()
        try bench.write("2024/a.raf", in: bench.src, mtime: old)
        try bench.write("2024/a.raf", in: bench.dst, mtime: old)
        try bench.write("b.raf", in: bench.src, "nouveau contenu")
        try bench.write("b.raf", in: bench.dst, "ancien")
        try bench.write("c.raf", in: bench.src)
        try bench.write("Exports/e.jpg", in: bench.src)
        try bench.write("Memes/f.txt", in: bench.src, mtime: old)
        try bench.write("Memes/f.txt", in: bench.dst, mtime: old)
        guard case .items(let items) = TreeLoader.list(dir: bench.src, rel: "", ignoreHidden: true) else { Issue.record("liste illisible"); return }

        let statuses = try #require(StatusCheck.statuses(for: items, in: bench.dst, knownDifferences: ["2024"]))
        #expect(statuses == ["2024": .different, "Memes": .same, "b.raf": .different, "c.raf": .missing, "Exports": .missing])
        let inside = try #require(StatusCheck.statuses(for: items.filter { $0.rel == "2024" }, in: bench.dst, knownDifferences: []))
        #expect(inside == ["2024": .same])

        #expect(AppModel.destinationRoot(for: bench.task) == bench.dst)
        #expect(Mounter.locateMounted("smb://nas-inexistant.local/partage") == nil)
        #expect(Mounter.locateMounted("/dossier/inexistant") == nil)

        var plan = SyncPlan()
        plan.copies = [Entry(rel: "2026/Islande/x.raf", isDir: false, size: 1, mtime: old)]
        plan.deletes = [DeleteItem(rel: "Exports/Brouillons", isDir: true, files: 1, bytes: 1)]
        #expect(AppModel.foldersWithDifferences(in: plan) == ["2026", "2026/islande", "exports"])
    }

    /// Le filtre d'affichage suit les pastilles et les éléments ignorés, et se mémorise.
    @Test func filtreDAffichage() {
        var f = ListFilter()
        #expect(f.isDefault && f.shows(ignored: false, status: .same) && f.shows(ignored: true, status: nil))
        f.same = false
        f.ignored = false
        #expect(!f.shows(ignored: false, status: .same) && f.shows(ignored: false, status: .different))
        #expect(f.shows(ignored: false, status: .missing) && !f.shows(ignored: true, status: .same))
        #expect(f.shows(ignored: false, status: nil))   // sans pastille : toujours affiché
        f.save()
        #expect(ListFilter.load() == f)
        ListFilter().save()
        #expect(ListFilter.load().isDefault)
    }
}

// MARK: - Mise à jour

@Test func numerosDeVersionCompares() throws {
    let v = { (s: String) in try #require(Updater.Version(s)) }
    #expect(try v("1.4") < v("1.5"))
    #expect(try v("1.9") < v("1.10"))
    #expect(try v("v1.5") == v("1.5.0"))
    #expect(try !(v("2.0") < v("1.12")))
    #expect(try v("1.4").description == "1.4")
    #expect(Updater.Version("") == nil)
    #expect(Updater.Version("1.a") == nil)
    #expect(Updater.Version("abc") == nil)
}

@Test func reponseGitHubLue() throws {
    let json = """
    {"tag_name": "v1.5", "html_url": "https://github.com/mdany75/Synchro/releases/tag/v1.5",
     "body": "### Ajouté\\n- Mise à jour proposée.\\n",
     "assets": [{"name": "notes.txt", "browser_download_url": "https://example.test/notes.txt"},
                {"name": "Synchro.dmg", "browser_download_url": "https://example.test/Synchro.dmg"}]}
    """
    let release = try Updater.parse(Data(json.utf8))
    #expect(release.version == Updater.Version("1.5"))
    #expect(release.download.lastPathComponent == "Synchro.dmg")
    #expect(release.page.path.hasSuffix("/v1.5"))
    #expect(Updater.summary(of: release.notes) == "Ajouté\n• Mise à jour proposée.")

    let sansImage = #"{"tag_name": "v1.5", "html_url": "https://example.test/", "assets": []}"#
    #expect(throws: SyncError.self) { try Updater.parse(Data(sansImage.utf8)) }
    #expect(throws: SyncError.self) { try Updater.parse(Data("pas du JSON".utf8)) }
}

@Test func notesDeVersionRaccourcies() {
    let long = String(repeating: "- ligne\n", count: 200)
    let text = Updater.summary(of: long, limit: 50)
    #expect(text.hasSuffix("…"))
    #expect(text.count <= 52)
}

@Test func appNonRemplacableDepuisUneImageOuSansDroit() throws {
    #expect(!Updater.canReplace(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/abc/d/Synchro.app")))
    #expect(!Updater.canReplace(URL(fileURLWithPath: "/usr/bin/true")))
    #expect(!Updater.canReplace(URL(fileURLWithPath: "/System/Applications/Synchro.app")))
}

/// Une image disque qui contient une app non signée ne remplace jamais l'app en place.
@Test func remplacementRefuseSansSignatureDeveloperID() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("synchro-maj-test-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let apps = root.appendingPathComponent("Applications")
    let app = apps.appendingPathComponent("Synchro.app")
    try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try Data("ancienne".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Synchro"))

    let stage = root.appendingPathComponent("stage")
    let fake = stage.appendingPathComponent("Synchro.app")
    try fm.createDirectory(at: fake.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try Data("nouvelle".utf8).write(to: fake.appendingPathComponent("Contents/MacOS/Synchro"))
    let dmgDir = root.appendingPathComponent("maj")
    try fm.createDirectory(at: dmgDir, withIntermediateDirectories: true)
    let dmg = dmgDir.appendingPathComponent("Synchro.dmg")
    try Updater.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", stage.path, "-volname", "Synchro", "-format", "UDZO", dmg.path])

    #expect(throws: SyncError.self) { try Updater.replace(app: app, with: dmg, team: nil) }
    #expect(try String(contentsOf: app.appendingPathComponent("Contents/MacOS/Synchro"), encoding: .utf8) == "ancienne")
    #expect(try fm.contentsOfDirectory(atPath: apps.path) == ["Synchro.app"])
    #expect(!fm.fileExists(atPath: dmgDir.appendingPathComponent("image").path))
}
