import Foundation
import Testing
@testable import SynchroCore

/// Arborescence temporaire avec une source et une destination, effacée à la fin du test.
final class Sandbox {
    let root: URL
    var src: URL { root.appendingPathComponent("src") }
    var dst: URL { root.appendingPathComponent("dst") }
    let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("synchro-tests-" + UUID().uuidString)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: root) }

    @discardableResult
    func write(_ rel: String, in base: URL, _ content: String = "x", mtime: Date? = nil) throws -> URL {
        let url = base.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        if let mtime { try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path) }
        return url
    }

    func mkdir(_ rel: String, in base: URL) throws {
        try fm.createDirectory(at: base.appendingPathComponent(rel), withIntermediateDirectories: true)
    }

    func exists(_ rel: String, in base: URL) -> Bool { fm.fileExists(atPath: base.appendingPathComponent(rel).path) }

    func read(_ rel: String, in base: URL) -> String? {
        (try? Data(contentsOf: base.appendingPathComponent(rel))).map { String(decoding: $0, as: UTF8.self) }
    }

    func plan(excludes: [String] = [], ignoreHidden: Bool = true) throws -> SyncPlan {
        let ex = Set(excludes.map(Scanner.excludeKey))
        let s = try Scanner.scan(root: src, excludes: ex, ignoreHidden: ignoreHidden) { _ in }
        let d = try Scanner.scan(root: dst, excludes: ex, ignoreHidden: ignoreHidden, flagHides: false) { _ in }
        var plan = Scanner.plan(source: s, destination: d, caseInsensitive: RootCheck.isCaseInsensitive(at: dst))
        try Scanner.verifySuspects(&plan, src: src, dst: dst) { _, _ in }
        return plan
    }

    @discardableResult
    func sync(excludes: [String] = [], ignoreHidden: Bool = true, acknowledged: Bool = false) throws -> SyncResult {
        let plan = try plan(excludes: excludes, ignoreHidden: ignoreHidden)
        return SyncRunner.run(plan: plan, roots: Roots(src: src, dst: dst), acknowledged: acknowledged) { _ in }
    }
}

let old = Date(timeIntervalSince1970: 1_600_000_000)

// MARK: - Miroir de base

@Test func copieInitialePuisRienAFaire() throws {
    let box = try Sandbox()
    try box.write("2024/Islande/a.raf", in: box.src, "aaa", mtime: old)
    try box.write("2024/b.raf", in: box.src, "bb")
    try box.mkdir("vide", in: box.src)
    try box.write("zero.txt", in: box.src, "")

    let result = try box.sync()
    #expect(result.succeeded)
    #expect(result.progress.copied == 3)
    #expect(box.read("2024/Islande/a.raf", in: box.dst) == "aaa")
    #expect(box.exists("vide", in: box.dst))
    #expect(box.exists("zero.txt", in: box.dst))

    let copied = try box.fm.attributesOfItem(atPath: box.dst.appendingPathComponent("2024/Islande/a.raf").path)
    #expect((copied[.modificationDate] as? Date) == old)

    let again = try box.plan()
    #expect(again.isEmpty)
    #expect(again.unchanged == 3)
}

@Test func fichierModifieEstRecopie() throws {
    let box = try Sandbox()
    try box.write("a.txt", in: box.src, "v1", mtime: old)
    try box.sync()
    try box.write("a.txt", in: box.src, "version 2")
    let plan = try box.plan()
    #expect(plan.copies.map(\.rel) == ["a.txt"])
    #expect(plan.replaced == 1)
    try box.sync()
    #expect(box.read("a.txt", in: box.dst) == "version 2")
}

@Test func suppressionsEtCompteDesFichiers() throws {
    let box = try Sandbox()
    try box.write("garde.txt", in: box.src)
    try box.write("garde.txt", in: box.dst)
    try box.write("a/x.txt", in: box.dst, "12345")
    try box.write("a/sous/y.txt", in: box.dst, "123")
    try box.write("a b/z.txt", in: box.dst)
    try box.write("a-b.txt", in: box.dst)
    try box.mkdir("dossier vide", in: box.dst)
    let src = box.src.appendingPathComponent("garde.txt"), dst = box.dst.appendingPathComponent("garde.txt")
    try box.fm.setAttributes([.modificationDate: old], ofItemAtPath: src.path)
    try box.fm.setAttributes([.modificationDate: old], ofItemAtPath: dst.path)

    let plan = try box.plan()
    #expect(plan.deletes.map(\.rel) == ["a", "a b", "a-b.txt", "dossier vide"])
    #expect(plan.filesToDelete == 4)
    #expect(plan.deletes.first { $0.rel == "a" }?.files == 2)
    #expect(plan.deletes.first { $0.rel == "a" }?.bytes == 8)
    #expect(plan.risks.isEmpty)   // quelques fichiers : l'aperçu suffit

    let result = try box.sync()
    #expect(result.succeeded)
    #expect(result.progress.deleted == 4)
    #expect(!box.exists("a", in: box.dst))
    #expect(!box.exists("a b", in: box.dst))
    #expect(box.exists("garde.txt", in: box.dst))
}

@Test func changementDeType() throws {
    let box = try Sandbox()
    try box.write("stable.txt", in: box.src, mtime: old)
    try box.write("stable.txt", in: box.dst, mtime: old)
    try box.write("devient-dossier/dedans.txt", in: box.src, "neuf")
    try box.write("devient-dossier", in: box.dst, "ancien fichier")
    try box.write("devient-fichier", in: box.src, "neuf")
    try box.write("devient-fichier/vieux.txt", in: box.dst)

    let result = try box.sync(acknowledged: true)
    #expect(result.errors.isEmpty)
    #expect(box.read("devient-dossier/dedans.txt", in: box.dst) == "neuf")
    #expect(box.read("devient-fichier", in: box.dst) == "neuf")
    #expect(try box.plan().isEmpty)
}

@Test func nomsAccentuesNFCetNFD() throws {
    let box = try Sandbox()
    let nfc = "\u{e9}t\u{e9} \u{e0} la for\u{ea}t.jpg"
    let nfd = nfc.decomposedStringWithCanonicalMapping
    #expect(nfc != nfd || nfc.utf8.count != nfd.utf8.count)
    try box.write(nfc, in: box.src, "photo", mtime: old)
    try box.write(nfd, in: box.dst, "photo", mtime: old)
    let plan = try box.plan()
    #expect(plan.isEmpty)
    #expect(plan.unchanged == 1)
}

// MARK: - Éléments ignorés

@Test func elementIgnoreNiCopieNiEfface() throws {
    let box = try Sandbox()
    try box.write("Cache/c.dat", in: box.src)
    try box.write("Cache/ancien.dat", in: box.dst)
    try box.write("Cachette/ok.txt", in: box.src)
    try box.write("photo.raf", in: box.src)

    let result = try box.sync(excludes: ["Cache"])
    #expect(result.succeeded)
    #expect(!box.exists("Cache/c.dat", in: box.dst))
    #expect(box.exists("Cache/ancien.dat", in: box.dst))
    #expect(box.exists("Cachette/ok.txt", in: box.dst))   // un nom qui commence pareil n'est pas ignoré
}

@Test func exclusionInsensibleALaCasse() throws {
    let box = try Sandbox()
    try box.write("archives/a.raf", in: box.src)
    try box.write("photo.raf", in: box.src)
    let plan = try box.plan(excludes: ["Archives"])
    #expect(plan.copies.map(\.rel) == ["photo.raf"])
}

/// Régression : un dossier ignoré, présent seulement sur la destination, était effacé avec son parent.
@Test func dossierIgnoreSurvitALaDisparitionDeSonParent() throws {
    let box = try Sandbox()
    try box.write("garde.raf", in: box.src, mtime: old)
    try box.write("garde.raf", in: box.dst, mtime: old)
    try box.write("Archives/2019/mariage.raf", in: box.dst, "seule copie")
    try box.write("Archives/2020/autre.raf", in: box.dst, "à effacer")

    let plan = try box.plan(excludes: ["Archives/2019"])
    #expect(plan.keptDirs == ["Archives"])
    #expect(plan.deletes.map(\.rel) == ["Archives/2020"])

    let result = try box.sync(excludes: ["Archives/2019"], acknowledged: true)
    #expect(result.errors.isEmpty)
    #expect(box.read("Archives/2019/mariage.raf", in: box.dst) == "seule copie")
    #expect(!box.exists("Archives/2020", in: box.dst))
}

@Test func fichierContreDossierConserve() throws {
    let box = try Sandbox()
    try box.write("Archives", in: box.src, "un fichier nommé comme le dossier")
    try box.write("Archives/2019/mariage.raf", in: box.dst, "seule copie")

    let plan = try box.plan(excludes: ["Archives/2019"])
    #expect(plan.conflicts.map(\.rel) == ["Archives"])
    #expect(plan.copies.isEmpty)
    #expect(plan.deletes.isEmpty)
    let result = try box.sync(excludes: ["Archives/2019"], acknowledged: true)
    #expect(!result.succeeded)   // un fichier de la source n'a pas pu être sauvegardé : ce n'est pas une réussite
    #expect(result.errors.count == 1)
    #expect(box.read("Archives/2019/mariage.raf", in: box.dst) == "seule copie")
}

@Test func fichiersCachesEtSysteme() throws {
    let box = try Sandbox()
    try box.write("visible.txt", in: box.src)
    try box.write(".cache", in: box.src)
    try box.write(".DS_Store", in: box.src)
    try box.write("._visible.txt", in: box.src)
    try box.write(".sur-le-nas", in: box.dst)

    try box.sync()
    #expect(box.exists("visible.txt", in: box.dst))
    #expect(!box.exists(".cache", in: box.dst))
    #expect(!box.exists(".DS_Store", in: box.dst))
    #expect(!box.exists("._visible.txt", in: box.dst))
    #expect(box.exists(".sur-le-nas", in: box.dst))

    try box.sync(ignoreHidden: false)
    #expect(box.exists(".cache", in: box.dst))
    #expect(!box.exists(".DS_Store", in: box.dst))   // les fichiers système ne sont jamais copiés
}

/// Régression : masquer un dossier sur la source après l'avoir synchronisé faisait effacer sa sauvegarde.
@Test func elementMasqueApresCoupNEstPasEfface() throws {
    let box = try Sandbox()
    try box.write("Projet/a.raf", in: box.src)
    try box.write("b.raf", in: box.src)
    try box.write("c.raf", in: box.src)
    try box.sync()

    for rel in ["Projet", "b.raf"] {
        var url = box.src.appendingPathComponent(rel)
        var values = URLResourceValues()
        values.isHidden = true
        try url.setResourceValues(values)
    }
    let plan = try box.plan()
    #expect(plan.deletes.isEmpty)
    #expect(plan.copies.isEmpty)
}

@Test func liensSymboliquesIgnores() throws {
    let box = try Sandbox()
    try box.write("vrai.txt", in: box.src)
    try box.fm.createSymbolicLink(at: box.src.appendingPathComponent("lien"), withDestinationURL: box.src.appendingPathComponent("vrai.txt"))
    try box.write("lien", in: box.dst, "copie d'avant")

    let plan = try box.plan()
    #expect(plan.skippedLinks == 1)
    #expect(plan.copies.map(\.rel) == ["vrai.txt"])
    #expect(plan.deletes.isEmpty)
}

// MARK: - Garde-fous

@Test func dossiersImbriquesRefuses() throws {
    let box = try Sandbox()
    try box.mkdir("Photos/2026", in: box.root)
    let photos = box.root.appendingPathComponent("Photos")

    #expect(throws: SyncError.self) { try RootCheck.validate(src: photos, dst: box.root) }
    #expect(throws: SyncError.self) { try RootCheck.validate(src: photos, dst: photos.appendingPathComponent("2026")) }
    #expect(throws: SyncError.self) { try RootCheck.validate(src: photos, dst: photos) }
    #expect(throws: SyncError.self) {
        try RootCheck.validate(src: photos, dst: box.root.appendingPathComponent("PHOTOS/2026"))
    }
    #expect(throws: Never.self) { try RootCheck.validate(src: box.src, dst: box.dst) }
    #expect(throws: Never.self) { try RootCheck.validate(src: photos, dst: box.root.appendingPathComponent("Photos 2")) }
}

/// Régression : avec la destination pour parent, la source figurait elle-même parmi les éléments à effacer.
@Test func lExecutionRefuseUneDestinationQuiContientLaSource() throws {
    let box = try Sandbox()
    try box.write("x.raf", in: box.src, "original")
    let s = try Scanner.scan(root: box.src, excludes: [], ignoreHidden: true) { _ in }
    let d = try Scanner.scan(root: box.root, excludes: [], ignoreHidden: true) { _ in }
    let plan = Scanner.plan(source: s, destination: d)
    let result = SyncRunner.run(plan: plan, roots: Roots(src: box.src, dst: box.root), acknowledged: true) { _ in }
    #expect(result.abortReason != nil)
    #expect(result.progress.deleted == 0)
    #expect(box.read("x.raf", in: box.src) == "original")
}

@Test func sourceVideBloqueLaSuppression() throws {
    let box = try Sandbox()
    try box.write("2025/p.raf", in: box.dst, "sauvegarde")
    let plan = try box.plan()
    #expect(plan.blockedReason != nil)
    let result = try box.sync(acknowledged: true)
    #expect(result.abortReason != nil)
    #expect(box.read("2025/p.raf", in: box.dst) == "sauvegarde")
}

@Test func destinationSansRapportDemandeConfirmation() throws {
    let box = try Sandbox()
    try box.write("nouveau.raf", in: box.src)
    try box.write("autre-sauvegarde/important.doc", in: box.dst, "sans rapport")
    let plan = try box.plan()
    #expect(plan.blockedReason == nil)
    #expect(!plan.risks.isEmpty)
    try box.sync()
    #expect(box.exists("autre-sauvegarde/important.doc", in: box.dst))
    #expect(!box.exists("nouveau.raf", in: box.dst))   // rien n'est fait tant que le risque n'est pas confirmé
}

@Test func suppressionMassiveDemandeConfirmation() throws {
    let box = try Sandbox()
    for i in 0..<100 {
        try box.write("garde/p\(i).raf", in: box.src, "photo \(i)", mtime: old)
        try box.write("garde/p\(i).raf", in: box.dst, "photo \(i)", mtime: old)
    }
    for i in 0..<60 { try box.write("2023/q\(i).raf", in: box.dst, "ancienne \(i)") }

    let plan = try box.plan()
    #expect(plan.filesToDelete == 60)
    #expect(!plan.risks.isEmpty)   // 60 fichiers sur 160 : plus du quart de la destination

    let refused = try box.sync()
    #expect(refused.abortReason != nil)
    #expect(refused.progress.deleted == 0)
    #expect(box.exists("2023/q0.raf", in: box.dst))

    let result = try box.sync(acknowledged: true)
    #expect(result.succeeded)
    #expect(result.progress.deleted == 60)
    #expect(!box.exists("2023", in: box.dst))
}

@Test func petiteSuppressionSansAlerte() throws {
    let box = try Sandbox()
    for i in 0..<10 {
        try box.write("p\(i).raf", in: box.src, "photo \(i)", mtime: old)
        try box.write("p\(i).raf", in: box.dst, "photo \(i)", mtime: old)
    }
    try box.write("rejet.raf", in: box.dst)
    let plan = try box.plan()
    #expect(plan.risks.isEmpty)
    #expect(plan.filesToDelete == 1)
    #expect(try box.sync().succeeded)
}

@Test func volumeChangeDepuisLAnalyse() throws {
    let box = try Sandbox()
    try box.write("a.raf", in: box.src)
    try box.write("vieux.raf", in: box.dst)
    try box.write("a.raf", in: box.dst)
    let plan = try box.plan()
    let autre = VolumeID(mountPoint: "/Volumes/Photos", identity: "un-autre-disque")
    let roots = Roots(src: box.src, dst: box.dst, srcVolume: autre, dstVolume: RootCheck.volumeID(of: box.dst))
    let result = SyncRunner.run(plan: plan, roots: roots, acknowledged: true) { _ in }
    #expect(result.abortReason != nil)
    #expect(box.exists("vieux.raf", in: box.dst))
}

@Test func destinationCreeeSeulementSiSonParentExiste() throws {
    let box = try Sandbox()
    try box.write("a.raf", in: box.src)
    let s = try Scanner.scan(root: box.src, excludes: [], ignoreHidden: true) { _ in }
    var plan = Scanner.plan(source: s, destination: ScanResult())
    plan.destinationExists = false

    let nouveau = box.root.appendingPathComponent("nouveau")
    #expect(SyncRunner.run(plan: plan, roots: Roots(src: box.src, dst: nouveau), acknowledged: false) { _ in }.succeeded)
    #expect(box.fm.fileExists(atPath: nouveau.appendingPathComponent("a.raf").path))

    let orphelin = box.root.appendingPathComponent("absent/sous-dossier")
    let result = SyncRunner.run(plan: plan, roots: Roots(src: box.src, dst: orphelin), acknowledged: false) { _ in }
    #expect(result.abortReason != nil)
    #expect(!box.fm.fileExists(atPath: orphelin.path))
}

// MARK: - Contenu et métadonnées

/// Régression : des rafales de même taille renumérotées après un tri passaient pour « inchangées ».
@Test func rafaleRenumeroteeDetecteeParLeContenu() throws {
    let box = try Sandbox()
    let t = old
    for (i, offset) in [0.0, 0.0, 1.0, 1.0, 2.0].enumerated() {
        try box.write("Islande-000\(i + 1).ARW", in: box.src, "IMAGE-NUMERO-\(i + 1)", mtime: t.addingTimeInterval(offset))
    }
    try box.sync()

    // Tri : l'image 2 est jetée, les suivantes sont renumérotées (un renommage conserve la date).
    try box.fm.removeItem(at: box.src.appendingPathComponent("Islande-0002.ARW"))
    for i in 3...5 {
        try box.fm.moveItem(at: box.src.appendingPathComponent("Islande-000\(i).ARW"),
                            to: box.src.appendingPathComponent("Islande-000\(i - 1).ARW"))
    }

    let plan = try box.plan()
    #expect(plan.contentMismatches == 3)
    #expect(plan.deletes.map(\.rel) == ["Islande-0005.ARW"])
    try box.sync()
    #expect(box.read("Islande-0002.ARW", in: box.dst) == "IMAGE-NUMERO-3")
    #expect(box.read("Islande-0003.ARW", in: box.dst) == "IMAGE-NUMERO-4")
    #expect(box.read("Islande-0004.ARW", in: box.dst) == "IMAGE-NUMERO-5")
    #expect(!box.exists("Islande-0005.ARW", in: box.dst))
    #expect(try box.plan().isEmpty)
}

@Test func echantillonsDeGrosFichiers() throws {
    let box = try Sandbox()
    var data = Data(count: 1 << 20)
    let a = box.root.appendingPathComponent("a.bin"), b = box.root.appendingPathComponent("b.bin")
    try data.write(to: a)
    try data.write(to: b)
    #expect(Scanner.sameSamples(a, b, size: Int64(data.count)))
    data[data.count / 2] = 7
    try data.write(to: b)
    #expect(!Scanner.sameSamples(a, b, size: Int64(data.count)))
}

@Test func datesDeCreationEtEtiquettesConservees() throws {
    let box = try Sandbox()
    let url = try box.write("photo.raf", in: box.src, "raw")
    let created = Date(timeIntervalSince1970: 1_500_000_000)
    try box.fm.setAttributes([.creationDate: created, .modificationDate: old], ofItemAtPath: url.path)
    let tag = Array("bplist-simule".utf8)
    #expect(setxattr(url.path, "com.apple.metadata:_kMDItemUserTags", tag, tag.count, 0, 0) == 0)

    try box.sync()
    let copy = box.dst.appendingPathComponent("photo.raf")
    let attrs = try box.fm.attributesOfItem(atPath: copy.path)
    #expect((attrs[.creationDate] as? Date) == created)
    #expect((attrs[.modificationDate] as? Date) == old)
    #expect(getxattr(copy.path, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, 0) == tag.count)
}

/// Un fichier modifié pendant sa copie est refusé ; l'ancienne version reste, aucun fichier temporaire ne traîne.
@Test func fichierModifiePendantLaCopie() throws {
    let box = try Sandbox()
    let source = box.src.appendingPathComponent("gros.bin")
    try Data(repeating: 7, count: 9 << 20).write(to: source)
    try box.write("gros.bin", in: box.dst, "ancienne version")
    var touched = false
    var message = ""
    do {
        try SyncRunner.copyFile(from: source, to: box.dst.appendingPathComponent("gros.bin")) { _ in
            guard !touched else { return }
            touched = true
            let handle = try! FileHandle(forWritingTo: source)
            _ = try! handle.seekToEnd()
            try! handle.write(contentsOf: Data("ajout".utf8))
            try! handle.close()
        }
    } catch { message = error.localizedDescription }
    #expect(message.contains("modifié pendant la copie"))
    #expect(box.read("gros.bin", in: box.dst) == "ancienne version")
    #expect(try box.fm.contentsOfDirectory(atPath: box.dst.path) == ["gros.bin"])
}

@Test func sourceAbsenteLaisseLAncienneVersion() throws {
    let box = try Sandbox()
    try box.write("a.txt", in: box.dst, "ancienne version")
    #expect(throws: (any Error).self) {
        try SyncRunner.copyFile(from: box.src.appendingPathComponent("a.txt"), to: box.dst.appendingPathComponent("a.txt")) { _ in }
    }
    #expect(box.read("a.txt", in: box.dst) == "ancienne version")
    #expect(try box.fm.contentsOfDirectory(atPath: box.dst.path) == ["a.txt"])
}

/// Si le serveur refuse le remplacement et que le plan B échoue aussi, l'ancienne version doit être remise en place.
@Test func remplacementReversible() throws {
    let box = try Sandbox()
    let target = try box.write("a.jpg", in: box.dst, "ancienne version")
    let tmp = try box.write(".synchro-tmp-zz", in: box.dst, "nouvelle version")
    #expect(chflags(tmp.path, UInt32(UF_IMMUTABLE)) == 0)   // le fichier temporaire ne peut plus être renommé
    defer { chflags(tmp.path, 0) }
    #expect(throws: (any Error).self) { try SyncRunner.replace(tmp: tmp, target: target) }
    #expect(box.read("a.jpg", in: box.dst) == "ancienne version")
}

@Test func annulationEnPleineCopie() async throws {
    let box = try Sandbox()
    let source = box.src.appendingPathComponent("gros.bin")
    try Data(repeating: 1, count: 12 << 20).write(to: source)
    try box.write("gros.bin", in: box.dst, "ancienne version")
    let target = box.dst.appendingPathComponent("gros.bin")
    var chunks = 0
    let outcome = await Task.detached {
        // L'arrêt est demandé après le premier bloc de 4 Mo : la copie doit s'interrompre avant la fin.
        try SyncRunner.copyFile(from: source, to: target) { _ in
            chunks += 1
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }.result
    #expect(throws: CancellationError.self) { try outcome.get() }
    #expect(chunks == 1)
    #expect(box.read("gros.bin", in: box.dst) == "ancienne version")
    #expect(try box.fm.contentsOfDirectory(atPath: box.dst.path) == ["gros.bin"])
}

@Test func synchronisationAnnuleeNeFaitRien() async throws {
    let box = try Sandbox()
    try box.write("garde.txt", in: box.src, mtime: old)
    try box.write("garde.txt", in: box.dst, mtime: old)
    try box.write("nouveau.txt", in: box.src)
    try box.write("vieux.txt", in: box.dst)
    let plan = try box.plan()
    let roots = Roots(src: box.src, dst: box.dst)
    let result = await Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return SyncRunner.run(plan: plan, roots: roots, acknowledged: false) { _ in }
    }.value
    #expect(result.cancelled)
    #expect(!result.succeeded)
    #expect(result.progress.copied == 0 && result.progress.deleted == 0)
    #expect(box.exists("vieux.txt", in: box.dst))
    #expect(!box.exists("nouveau.txt", in: box.dst))
}

@Test func fichiersTemporairesNettoyes() throws {
    let box = try Sandbox()
    try box.write("a.txt", in: box.src)
    try box.write("sous/.synchro-tmp-abc12345", in: box.dst, "reste d'une copie interrompue")
    try box.mkdir("sous", in: box.src)
    try box.sync()
    #expect(!box.exists("sous/.synchro-tmp-abc12345", in: box.dst))
}

@Test func fichierIllisibleSignaleSansBloquerLeReste() throws {
    let box = try Sandbox()
    let locked = try box.write("verrouille.raf", in: box.src, "secret")
    try box.write("ok.raf", in: box.src)
    try box.fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    defer { try? box.fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

    let result = try box.sync()
    #expect(result.errors.count == 1)
    #expect(result.progress.copied == 1)
    #expect(result.progress.failed == 1)
    #expect(box.exists("ok.raf", in: box.dst))
    #expect(result.progress.bytesDone == 1)   // seul le fichier réellement copié compte dans le volume transféré
}

@Test func dossierIllisibleInterromptLAnalyse() throws {
    let box = try Sandbox()
    try box.write("prive/a.raf", in: box.src)
    try box.write("prive/a.raf", in: box.dst)
    let dir = box.src.appendingPathComponent("prive")
    try box.fm.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)
    defer { try? box.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
    // Un dossier illisible ne doit jamais être pris pour un dossier vide : sa sauvegarde serait effacée.
    #expect(throws: SyncError.self) { try box.plan() }
}

@Test func catalogueLightroomOuvertSignale() throws {
    let box = try Sandbox()
    try box.write("Catalogue/Photos.lrcat", in: box.src, "base")
    try box.write("Catalogue/Photos.lrcat.lock", in: box.src, "verrou")
    let plan = try box.plan()
    #expect(plan.openCatalogs == ["Catalogue/Photos.lrcat"])
    #expect(plan.copies.map(\.rel) == ["Catalogue/Photos.lrcat"])   // le verrou lui-même n'est pas copié
}

@Test func espaceLibreInsuffisantSignale() throws {
    var plan = SyncPlan()
    plan.bytesToCopy = 1_000
    plan.freeSpace = 1_000
    #expect(plan.spaceShortfall == nil)   // un nouveau fichier qui tient tout juste ne déclenche pas de fausse alerte
    plan.freeSpace = 900
    #expect(plan.spaceShortfall == 100)
    plan.bytesToDelete = 200
    #expect(plan.spaceShortfall == nil)
    // Remplacement : l'ancienne version libère sa place, mais coexiste un instant avec la nouvelle.
    plan.bytesToDelete = 0
    plan.bytesReplaced = 600
    plan.largestReplaced = 600
    plan.freeSpace = 900
    #expect(plan.spaceShortfall == 100)
}

@Test func detectionDisquePlein() {
    #expect(SyncRunner.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
    #expect(SyncRunner.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
    let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT))])
    #expect(SyncRunner.isOutOfSpace(wrapped))
    #expect(!SyncRunner.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
}

@Test func seuilsDeSuppressionInhabituelle() {
    func risky(delete: Int, matching: Int) -> Bool {
        var plan = SyncPlan()
        plan.filesToDelete = delete
        plan.unchanged = matching
        return !plan.risks.isEmpty
    }
    #expect(!risky(delete: 9, matching: 1))     // sous dix fichiers, l'aperçu se lit d'un coup d'œil
    #expect(risky(delete: 10, matching: 1))
    #expect(!risky(delete: 50, matching: 150))  // exactement le quart : pas encore inhabituel
    #expect(risky(delete: 50, matching: 149))
    #expect(risky(delete: 1, matching: 0))      // rien en commun avec la source
    #expect(!risky(delete: 0, matching: 0))

    var plan = SyncPlan()
    plan.volumeWarning = "autre volume"
    #expect(plan.risks == ["autre volume"])
}

// MARK: - Adresses SMB

@Test func nomsDHoteComparables() {
    #expect(Mounter.normalizedHost("admin@QNAP-Maison") == "qnap-maison")
    #expect(Mounter.normalizedHost("QNAP-Maison.local") == "qnap-maison")
    #expect(Mounter.normalizedHost("QNAP-Maison._smb._tcp.local") == "qnap-maison")
    #expect(Mounter.normalizedHost("nas.local:445") == "nas")
    #expect(Mounter.normalizedHost("nas.studio.example.com") != Mounter.normalizedHost("nas"))
}

@Test func analyseDesAdressesSMB() {
    #expect(Mounter.parse("smb://QNAP-Maison/Backup/Lacie SSD") == .init(host: "QNAP-Maison", share: "Backup", sub: "Lacie SSD"))
    #expect(Mounter.parse("smb://admin@nas.local/Sauvegarde/Photos%20SSD/2026") == .init(host: "nas.local", share: "Sauvegarde", sub: "Photos SSD/2026"))
    #expect(Mounter.parse("smb://nas") == nil)
    #expect(Mounter.parse("/Volumes/Backup") == nil)
    #expect(throws: SyncError.self) { try Mounter.resolve("dossier/relatif") }
}

// MARK: - Deuxième série : cas trouvés par la revue contradictoire

/// Reproduit une rafale : `count` images, `perSecond` par seconde, horodatées à la seconde comme le fait un appareil.
private func burst(_ box: Sandbox, count: Int, perSecond: Int, size: (Int) -> Int) throws {
    for i in 1...count {
        let content = String(repeating: "x", count: size(i) - 6) + String(format: "%06d", i)
        try box.write(String(format: "DSCF%04d.RAF", i), in: box.src, content,
                      mtime: old.addingTimeInterval(Double((i - 1) / perSecond)))
    }
}

/// Jette la première image et renumérote les suivantes, comme après un tri.
private func cullFirstAndRenumber(_ box: Sandbox, count: Int) throws {
    try box.fm.removeItem(at: box.src.appendingPathComponent("DSCF0001.RAF"))
    for i in 2...count {
        try box.fm.moveItem(at: box.src.appendingPathComponent(String(format: "DSCF%04d.RAF", i)),
                            to: box.src.appendingPathComponent(String(format: "DSCF%04d.RAF", i - 1)))
    }
}

private func mirrorIsExact(_ box: Sandbox) throws -> Bool {
    let names = try box.fm.contentsOfDirectory(atPath: box.src.path).sorted()
    guard try box.fm.contentsOfDirectory(atPath: box.dst.path).sorted() == names else { return false }
    return names.allSatisfy { box.fm.contentsEqual(atPath: box.src.path + "/" + $0, andPath: box.dst.path + "/" + $0) }
}

@Test func longueRafaleRenumerotee() throws {
    let box = try Sandbox()
    try burst(box, count: 50, perSecond: 10) { _ in 4_000 }
    try box.sync()
    try cullFirstAndRenumber(box, count: 50)
    let plan = try box.plan()
    #expect(plan.contentMismatches == 49)
    #expect(try box.sync().succeeded)
    #expect(try mirrorIsExact(box))
    #expect(try box.plan().isEmpty)
}

@Test func rafaleDeTaillesMelangees() throws {
    let box = try Sandbox()
    // Trente images de taille fixe, puis vingt de tailles variées : les tailles qui bougent ne sont pas celles à vérifier.
    try burst(box, count: 50, perSecond: 10) { $0 <= 30 ? 4_000 : 4_000 + $0 }
    try box.sync()
    try cullFirstAndRenumber(box, count: 50)
    #expect(try box.sync().succeeded)
    #expect(try mirrorIsExact(box))
}

@Test func troisImagesDontDeuxDeMemeTaille() throws {
    let box = try Sandbox()
    try burst(box, count: 3, perSecond: 1) { $0 == 3 ? 4_100 : 4_000 }
    try box.sync()
    try cullFirstAndRenumber(box, count: 3)
    #expect(try box.sync().succeeded)
    #expect(try mirrorIsExact(box))
}

/// Toutes les images dans la même seconde : les dates sont rigoureusement identiques, seule la règle
/// « un voisin de même taille à moins de 2 s » peut révéler la renumérotation.
@Test func rafaleDansLaMemeSeconde() throws {
    let box = try Sandbox()
    try burst(box, count: 6, perSecond: 100) { _ in 4_000 }
    try box.sync()
    try cullFirstAndRenumber(box, count: 6)
    let plan = try box.plan()
    #expect(plan.contentMismatches == 5)
    #expect(try box.sync().succeeded)
    #expect(try mirrorIsExact(box))
}

@Test func ajoutSansRafaleNeDeclenchePasDeComparaison() throws {
    let box = try Sandbox()
    for i in 1...20 { try box.write("p\(i).jpg", in: box.src, "photo \(i)", mtime: old.addingTimeInterval(Double(i) * 60)) }
    try box.sync()
    try box.write("p21.jpg", in: box.src, "photo 21")
    let plan = try box.plan()
    #expect(plan.copies.count == 1)
    #expect(plan.verified == 0)   // des photos prises à une minute d'intervalle ne sont pas ambiguës
}

@Test func elementIgnoreSousUnDossierCache() throws {
    let box = try Sandbox()
    try box.write("garde.jpg", in: box.src, mtime: old)
    try box.write("garde.jpg", in: box.dst, mtime: old)
    try box.write("Lot/.prive/Garde/s.jpg", in: box.dst, "précieux")
    try box.write("Lot/z.jpg", in: box.dst)
    let plan = try box.plan(excludes: ["Lot/.prive/Garde"])
    #expect(plan.deletes.map(\.rel) == ["Lot/z.jpg"])
    try box.sync(excludes: ["Lot/.prive/Garde"], acknowledged: true)
    #expect(box.read("Lot/.prive/Garde/s.jpg", in: box.dst) == "précieux")
}

@Test func exclusionSaisieAvecBarres() {
    #expect(Scanner.excludeKey("./Archives/2019/") == "archives/2019")
    #expect(Scanner.excludeKey("/Archives") == "archives")
    #expect(Scanner.excludeKey(" Archives ") == "archives")
}

@Test func renommageDeCasseSansRecopie() throws {
    let box = try Sandbox()
    try #require(RootCheck.isCaseInsensitive(at: box.dst))
    try box.write("Islande/IMG_1.RAF", in: box.src, "un")
    try box.write("Islande/IMG_2.RAF", in: box.src, "deux")
    try box.write("Readme.TXT", in: box.src, "lisez")
    try box.sync()

    // Sur un volume insensible à la casse, changer la casse demande un détour par un autre nom.
    for (from, to) in [("Islande", "islande"), ("Readme.TXT", "readme.txt")] {
        let tmp = box.src.appendingPathComponent("tmp-" + to)
        try box.fm.moveItem(at: box.src.appendingPathComponent(from), to: tmp)
        try box.fm.moveItem(at: tmp, to: box.src.appendingPathComponent(to))
    }
    let plan = try box.plan()
    #expect(plan.renames.map(\.to).sorted() == ["islande", "readme.txt"])
    #expect(plan.copies.isEmpty)
    #expect(plan.deletes.isEmpty)
    #expect(try box.sync().succeeded)
    #expect(try box.fm.contentsOfDirectory(atPath: box.dst.path).sorted() == ["islande", "readme.txt"])
    #expect(box.read("islande/IMG_2.RAF", in: box.dst) == "deux")
    #expect(try box.plan().isEmpty)
}

/// Régression : ce cas effaçait puis recopiait le dossier à chaque synchronisation, sans jamais converger.
@Test func renommageDeCasseDUnDossierQuiAbriteUnElementIgnore() throws {
    let box = try Sandbox()
    try #require(RootCheck.isCaseInsensitive(at: box.dst))
    try box.write("Photos/p1.raw", in: box.src, "un")
    try box.write("Photos/Rejets/r.txt", in: box.src)
    try box.write("Photos/Rejets/ancien.txt", in: box.dst, "seulement sur le NAS")
    try box.sync(excludes: ["Photos/Rejets"])
    try box.fm.moveItem(at: box.src.appendingPathComponent("Photos"), to: box.src.appendingPathComponent("ptmp"))
    try box.fm.moveItem(at: box.src.appendingPathComponent("ptmp"), to: box.src.appendingPathComponent("photos"))

    let plan = try box.plan(excludes: ["Photos/Rejets"])
    #expect(plan.deletes.isEmpty)
    #expect(plan.copies.isEmpty)
    #expect(try box.sync(excludes: ["Photos/Rejets"]).succeeded)
    #expect(box.read("photos/Rejets/ancien.txt", in: box.dst) == "seulement sur le NAS")
    #expect(try box.plan(excludes: ["Photos/Rejets"]).isEmpty)
}

@Test func nomsDeLaSourceQuiNeDifferentQueParLaCasse() {
    var source = ScanResult(), destination = ScanResult()
    for rel in ["a.txt", "A.txt", "normal.txt", "Dir", "dir", "Dir/x.txt", "dir/y.txt"] {
        source.entries[rel] = Entry(rel: rel, isDir: !rel.contains("."), size: 3, mtime: old)
    }
    destination.entries["a.txt"] = Entry(rel: "a.txt", isDir: false, size: 9, mtime: old)

    let plan = Scanner.plan(source: source, destination: destination, caseInsensitive: true)
    #expect(plan.conflicts.map(\.rel) == ["A.txt", "a.txt"])
    #expect(plan.copies.map(\.rel) == ["Dir/x.txt", "dir/y.txt", "normal.txt"])
    #expect(plan.deletes.isEmpty)   // la copie existante n'est ni écrasée ni effacée

    // Sur une destination sensible à la casse, ce sont simplement des fichiers différents.
    let strict = Scanner.plan(source: source, destination: destination, caseInsensitive: false)
    #expect(strict.conflicts.isEmpty)
    #expect(strict.copies.count == 5)
}

@Test func lienVersUnDossierSurLaDestination() throws {
    let box = try Sandbox()
    try box.write("album/x.jpg", in: box.src, "nouveau")
    let ailleurs = box.root.appendingPathComponent("ailleurs")
    try box.fm.createDirectory(at: ailleurs, withIntermediateDirectories: true)
    try Data("précieux".utf8).write(to: ailleurs.appendingPathComponent("x.jpg"))
    try box.fm.createSymbolicLink(at: box.dst.appendingPathComponent("album"), withDestinationURL: ailleurs)

    let plan = try box.plan()
    #expect(plan.conflicts.map(\.rel) == ["album"])
    #expect(plan.copies.isEmpty)
    let result = try box.sync()
    #expect(!result.succeeded)
    #expect(String(decoding: try Data(contentsOf: ailleurs.appendingPathComponent("x.jpg")), as: UTF8.self) == "précieux")
}

@Test func tubeNommeDansLaSource() throws {
    let box = try Sandbox()
    try box.write("a.txt", in: box.src)
    try box.write("z.txt", in: box.src)
    #expect(mkfifo(box.src.appendingPathComponent("tube").path, 0o644) == 0)
    let plan = try box.plan()
    #expect(plan.skippedLinks == 1)
    #expect(try box.sync().succeeded)
    #expect(box.exists("z.txt", in: box.dst))
    #expect(!box.exists("tube", in: box.dst))
}

@Test func dossierMasqueSeulementSurLaDestination() throws {
    let box = try Sandbox()
    try box.write("Projet/a.raf", in: box.src, "un")
    try box.write("Projet/b.raf", in: box.src, "deux")
    try box.sync()
    var folder = box.dst.appendingPathComponent("Projet")
    var values = URLResourceValues()
    values.isHidden = true
    try folder.setResourceValues(values)
    #expect(try box.plan().isEmpty)   // sinon le dossier serait recopié en entier à chaque synchronisation

    try box.fm.removeItem(at: box.src.appendingPathComponent("Projet/b.raf"))
    #expect(try box.plan().deletes.map(\.rel) == ["Projet/b.raf"])
}

@Test func destinationFutureDansLaSourceParUnLien() throws {
    let box = try Sandbox()
    try box.mkdir("vrai/Photos", in: box.root)
    let link = box.root.appendingPathComponent("raccourci")
    try box.fm.createSymbolicLink(at: link, withDestinationURL: box.root.appendingPathComponent("vrai"))
    let photos = box.root.appendingPathComponent("vrai/Photos")
    // La destination n'existe pas encore et son chemin passe par un lien.
    #expect(throws: SyncError.self) {
        try RootCheck.validate(src: photos, dst: link.appendingPathComponent("Photos/sauvegarde"))
    }
    #expect(throws: SyncError.self) {
        try RootCheck.validate(src: link.appendingPathComponent("Photos"), dst: photos.appendingPathComponent("nouveau/sous-dossier"))
    }
}

@Test func volumeNonConnecteRefuse() throws {
    let box = try Sandbox()
    #expect(throws: SyncError.self) {
        try RootCheck.validate(src: URL(fileURLWithPath: "/Volumes/Synchro-volume-absent-\(UUID().uuidString)/Photos"), dst: box.dst)
    }
}

@Test func destinationDisparueDepuisLAnalyse() throws {
    let box = try Sandbox()
    try box.write("a.raf", in: box.src, "nouveau contenu")
    try box.write("2026/nouveau.raf", in: box.src)   // un dossier à créer : il ne doit pas faire renaître la destination
    try box.write("a.raf", in: box.dst, "v1")
    let plan = try box.plan()
    #expect(plan.deletes.isEmpty && plan.dirs == ["2026"])
    let roots = Roots(src: box.src, dst: box.dst)
    try box.fm.moveItem(at: box.dst, to: box.root.appendingPathComponent("deplacee"))
    let result = SyncRunner.run(plan: plan, roots: roots, acknowledged: false) { _ in }
    #expect(result.abortReason != nil)
    #expect(!box.fm.fileExists(atPath: box.dst.path))   // surtout ne pas recréer un dossier neuf à moitié rempli
}

/// Régression : un seul dossier refusant l'écriture arrêtait toute la synchronisation au bout de 25 erreurs.
@Test func unDossierDefectueuxNeBloquePasLesSuivants() throws {
    let box = try Sandbox()
    try box.mkdir("2023", in: box.dst)
    for i in 0..<30 { try box.write(String(format: "2023/n%02d.jpg", i), in: box.src) }
    try box.write("2024/ok.jpg", in: box.src, "bon")
    let locked = box.dst.appendingPathComponent("2023")
    try box.fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    defer { try? box.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

    let result = try box.sync()
    #expect(result.abortReason == nil)
    #expect(result.progress.failed == 30)
    #expect(box.read("2024/ok.jpg", in: box.dst) == "bon")
}

@Test func destinationEnLectureSeuleInterrompt() throws {
    let box = try Sandbox()
    for i in 0..<40 { try box.write(String(format: "n%02d.jpg", i), in: box.src) }
    let plan = try box.plan()
    try box.fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: box.dst.path)
    defer { try? box.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.dst.path) }
    let result = SyncRunner.run(plan: plan, roots: Roots(src: box.src, dst: box.dst), acknowledged: false) { _ in }
    #expect(result.abortReason != nil)
    #expect(result.progress.failed == SyncRunner.maxConsecutiveFailures)
}

@Test func restesTemporairesSeulsFormentUnPlan() throws {
    let box = try Sandbox()
    try box.write("a.txt", in: box.src, mtime: old)
    try box.write("a.txt", in: box.dst, mtime: old)
    try box.write(".synchro-tmp-abc12345", in: box.dst, "reste")
    let plan = try box.plan()
    #expect(!plan.isEmpty)
    #expect(plan.copies.isEmpty && plan.deletes.isEmpty)
    #expect(try box.sync().succeeded)
    #expect(try box.fm.contentsOfDirectory(atPath: box.dst.path) == ["a.txt"])
}

@Test func journalDeCeQuiAEteFait() throws {
    let box = try Sandbox()
    try box.write("garde.txt", in: box.src, mtime: old)
    try box.write("garde.txt", in: box.dst, mtime: old)
    try box.write("nouveau.txt", in: box.src)
    try box.write("vieux/x.txt", in: box.dst)
    let result = try box.sync()
    #expect(result.copiedFiles == ["nouveau.txt"])
    #expect(result.deletedItems == ["vieux"])
}
