import Foundation

public struct Entry: Sendable, Equatable {
    public let rel: String
    public let isDir: Bool
    public let size: Int64
    public let mtime: Date

    public init(rel: String, isDir: Bool, size: Int64, mtime: Date) {
        self.rel = rel
        self.isDir = isDir
        self.size = size
        self.mtime = mtime
    }
}

/// Élément à effacer de la destination. Un dossier emporte tout son contenu : `files` et `bytes` le totalisent.
public struct DeleteItem: Sendable, Identifiable, Equatable {
    public let rel: String
    public let isDir: Bool
    public let files: Int
    public let bytes: Int64
    public var id: String { rel }

    public init(rel: String, isDir: Bool, files: Int, bytes: Int64) {
        self.rel = rel
        self.isDir = isDir
        self.files = files
        self.bytes = bytes
    }
}

/// Élément de la source qui ne peut pas être copié sans écraser autre chose.
public struct Conflict: Sendable, Identifiable, Equatable {
    public let rel: String
    public let reason: String
    public var id: String { rel }

    public init(rel: String, reason: String) {
        self.rel = rel
        self.reason = reason
    }
}

/// Élément dont seules les majuscules ont changé : renommé sur la destination, sans recopie.
public struct Rename: Sendable, Identifiable, Equatable {
    public let from: String
    public let to: String
    public var id: String { from }
}

public struct SyncPlan: Sendable {
    public var copies: [Entry] = []
    public var dirs: [String] = []
    public var deletes: [DeleteItem] = []
    public var renames: [Rename] = []
    /// Restes de copies interrompues, à retirer.
    public var temps: [URL] = []
    public var bytesToCopy: Int64 = 0
    public var bytesToDelete: Int64 = 0
    /// Taille actuelle, sur la destination, des fichiers qui vont être remplacés.
    public var bytesReplaced: Int64 = 0
    public var largestReplaced: Int64 = 0
    public var filesToDelete = 0
    public var replaced = 0
    public var unchanged = 0
    public var sourceFiles = 0
    /// Liens symboliques et fichiers spéciaux de la source, jamais copiés.
    public var skippedLinks = 0
    /// Dossiers absents de la source mais conservés, car ils contiennent un élément ignoré.
    public var keptDirs: [String] = []
    public var conflicts: [Conflict] = []
    /// Catalogues Lightroom ouverts (présence d'un fichier .lrcat.lock).
    public var openCatalogs: [String] = []
    /// Fichiers « inchangés » en apparence dont le contenu a été comparé, et nombre de ceux qui différaient.
    public var verified = 0
    public var contentMismatches = 0
    public var destinationExists = true
    public var freeSpace: Int64?
    /// Renseigné par l'appelant quand la destination n'est plus sur le volume de la dernière synchronisation.
    public var volumeWarning: String?
    var suspects: [Suspect] = []
    var unchangedByFolder: [String: [Entry]] = [:]

    struct Suspect: Sendable {
        let entry: Entry
        let folder: String
    }

    public init() {}

    /// Vrai s'il n'y a rien à faire sur la destination.
    public var isEmpty: Bool {
        copies.isEmpty && dirs.isEmpty && deletes.isEmpty && renames.isEmpty && temps.isEmpty
    }

    /// Raison pour laquelle ce plan ne doit jamais être exécuté.
    public var blockedReason: String? {
        if sourceFiles == 0 && !deletes.isEmpty {
            return "La source ne contient aucun fichier : la suppression est bloquée par sécurité. Vérifiez que le bon disque est branché."
        }
        return nil
    }

    /// Situations inhabituelles, qui exigent une confirmation explicite en plus de l'aperçu.
    public var risks: [String] {
        var out: [String] = []
        if let volumeWarning { out.append(volumeWarning) }
        guard filesToDelete > 0 else { return out }
        let matching = unchanged + replaced
        let files = plural(filesToDelete, "fichier", "fichiers")
        if matching == 0 {
            out.append("Aucun fichier de la destination ne correspond à la source : tout son contenu actuel (\(files)) serait effacé. Vérifiez que c'est le bon dossier.")
        } else if filesToDelete >= 10 && filesToDelete * 4 > matching + filesToDelete {
            let percent = Int((Double(filesToDelete) / Double(matching + filesToDelete) * 100).rounded())
            out.append("\(files), soit \(percent) % de la destination, seraient effacés.")
        }
        return out
    }

    /// Octets manquants sur la destination pour mener la copie à bien, s'il en manque.
    public var spaceShortfall: Int64? {
        guard let freeSpace, bytesToCopy > 0 else { return nil }
        // Les suppressions passent avant la copie ; pendant un remplacement, l'ancienne et la nouvelle version coexistent un instant.
        let needed = bytesToCopy - bytesToDelete - bytesReplaced + largestReplaced
        return needed > freeSpace ? needed - freeSpace : nil
    }
}

public enum SyncPhase: Sendable, Equatable {
    case preparing, deleting, folders, copying, finished
}

public struct SyncProgress: Sendable {
    public var phase = SyncPhase.preparing
    public var bytesDone: Int64 = 0
    /// Octets des fichiers en échec : ils font avancer la barre, pas la vitesse ni le volume transféré.
    public var bytesSkipped: Int64 = 0
    public var bytesTotal: Int64 = 0
    public var copied = 0
    public var failed = 0
    /// Nombre de fichiers effacés (contenu des dossiers compris).
    public var deleted = 0
    public var deleteItemsDone = 0
    public var deleteItemsTotal = 0
    public var current = ""
    public var speed: Double = 0
    public var elapsed: TimeInterval = 0
    public var startedAt = Date()

    public init(bytesTotal: Int64 = 0, deleteItemsTotal: Int = 0, startedAt: Date = Date()) {
        self.bytesTotal = bytesTotal
        self.deleteItemsTotal = deleteItemsTotal
        self.startedAt = startedAt
    }

    public var fraction: Double {
        if phase == .deleting || bytesTotal == 0 {
            return deleteItemsTotal > 0 ? min(1, Double(deleteItemsDone) / Double(deleteItemsTotal)) : 0
        }
        return min(1, Double(bytesDone + bytesSkipped) / Double(bytesTotal))
    }

    public var remaining: TimeInterval? {
        speed > 0 ? Double(max(0, bytesTotal - bytesDone - bytesSkipped)) / speed : nil
    }
}

public struct SyncResult: Sendable {
    public var progress: SyncProgress
    public var unchanged: Int
    public var errors: [String]
    public var cancelled: Bool
    /// Renseigné quand la synchronisation s'est interrompue d'elle-même (disque débranché, destination pleine…).
    public var abortReason: String?
    public var finishedAt: Date
    /// Ce qui a réellement été fait, pour le journal d'une synchronisation interrompue.
    public var deletedItems: [String] = []
    public var copiedFiles: [String] = []

    public init(progress: SyncProgress, unchanged: Int, errors: [String] = [], cancelled: Bool = false,
                abortReason: String? = nil, finishedAt: Date = Date()) {
        self.progress = progress
        self.unchanged = unchanged
        self.errors = errors
        self.cancelled = cancelled
        self.abortReason = abortReason
        self.finishedAt = finishedAt
    }

    public var averageSpeed: Double { progress.elapsed > 0 ? Double(progress.bytesDone) / progress.elapsed : 0 }
    public var succeeded: Bool { !cancelled && abortReason == nil && errors.isEmpty }

    /// Résultat d'une synchronisation refusée avant d'avoir commencé.
    public static func refused(_ reason: String, plan: SyncPlan) -> SyncResult {
        var progress = SyncProgress(bytesTotal: plan.bytesToCopy, deleteItemsTotal: plan.deletes.count)
        progress.phase = .finished
        return SyncResult(progress: progress, unchanged: plan.unchanged, errors: [reason], abortReason: reason)
    }
}

public struct SyncError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// « 1 fichier », « 3 fichiers ».
func plural(_ n: Int, _ one: String, _ many: String) -> String {
    "\(n.formatted()) \(n < 2 ? one : many)"
}

public struct ScanResult: Sendable {
    public var entries: [String: Entry] = [:]
    /// Liens symboliques et fichiers spéciaux rencontrés.
    public var links = 0
    public var temps: [URL] = []
    /// Éléments ignorés par l'utilisateur et réellement rencontrés.
    public var excludedSeen: Set<String> = []
    /// Éléments écartés sans être des fichiers système (masqués par un attribut, liens, fichiers spéciaux) :
    /// ce qui porte le même nom de l'autre côté ne doit être ni effacé, ni écrasé.
    public var shielded: Set<String> = []
    public var openCatalogs: [String] = []

    public init() {}
}

public enum Scanner {
    static let tempPrefix = ".synchro-tmp-"

    /// Fichiers système jamais synchronisés, même si les fichiers cachés sont inclus.
    static let systemNames: Set<String> = [
        ".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd", ".DocumentRevisions-V100",
        ".TemporaryItems", ".VolumeIcon.icns", ".apdisk", ".com.apple.timemachine.donotpresent",
        "@Recycle", ".@__thumb", ".streams",
    ]

    /// Fichiers système et verrous temporaires : jamais copiés, et effacés avec leur dossier.
    static func isSystemName(_ name: String) -> Bool {
        systemNames.contains(name) || name.hasPrefix("._") || name.hasSuffix(".lrcat.lock")
    }

    public static func isIgnoredName(_ name: String, hidden: Bool, ignoreHidden: Bool) -> Bool {
        isSystemName(name) || (ignoreHidden && (hidden || name.hasPrefix(".")))
    }

    /// Clé de comparaison d'un chemin relatif : forme Unicode composée, pour qu'un « é » du Mac et un « é » du NAS coïncident.
    public static func key(_ rel: String) -> String { rel.precomposedStringWithCanonicalMapping }

    /// Clé d'un élément ignoré : insensible à la casse, pour qu'un simple changement de majuscules n'annule pas
    /// l'exclusion, et débarrassée des « ./ » et « / » superflus d'un chemin saisi à la main.
    public static func excludeKey(_ rel: String) -> String {
        var r = Substring(rel.trimmingCharacters(in: .whitespaces))
        while r.hasPrefix("./") { r = r.dropFirst(2) }
        while r.hasPrefix("/") { r = r.dropFirst() }
        while r.hasSuffix("/") { r = r.dropLast() }
        return key(String(r)).lowercased()
    }

    static func parentKey(_ k: String) -> String? {
        k.lastIndex(of: "/").map { String(k[..<$0]) }
    }

    static func lastComponent(_ k: String) -> Substring {
        k.lastIndex(of: "/").map { k[k.index(after: $0)...] } ?? Substring(k)
    }

    /// - Parameters:
    ///   - excludes: chemins relatifs passés par `excludeKey`.
    ///   - flagHides: écarter aussi ce qui porte l'attribut « masqué ». À réserver à la source : sur la destination,
    ///     cet attribut a pu être posé par le NAS ou un autre ordinateur, et ne doit pas rendre la sauvegarde invisible.
    public static func scan(root: URL, excludes: Set<String>, ignoreHidden: Bool, flagHides: Bool = true,
                            tick: (Int) -> Void) throws -> ScanResult {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        let keySet = Set(keys)
        var out = ScanResult()
        var stack: [(url: URL, rel: String)] = [(root, "")]
        while let top = stack.popLast() {
            try Task.checkCancellation()
            let items: [URL]
            do {
                items = try fm.contentsOfDirectory(at: top.url, includingPropertiesForKeys: keys, options: [])
            } catch {
                // Un dossier illisible n'est jamais traité comme vide : cela ferait effacer sa sauvegarde.
                let shown = top.rel.isEmpty ? top.url.path : top.rel
                throw SyncError("Impossible de lire le dossier « \(shown) » : \(error.localizedDescription)")
            }
            for item in items {
                let name = item.lastPathComponent
                if name.hasPrefix(tempPrefix) { out.temps.append(item); continue }
                let rel = top.rel.isEmpty ? name : top.rel + "/" + name
                if name.hasSuffix(".lrcat.lock") { out.openCatalogs.append(String(rel.dropLast(5))) }
                if isSystemName(name) { continue }
                let k = key(rel)
                let lowered = k.lowercased()
                if excludes.contains(lowered) { out.excludedSeen.insert(k); continue }
                let v = try item.resourceValues(forKeys: keySet)
                let dotted = name.hasPrefix(".")
                if ignoreHidden && (dotted || (flagHides && v.isHidden == true)) {
                    // Un nom à point est écarté des deux côtés ; un attribut « masqué » n'existe que d'un côté.
                    if !dotted { out.shielded.insert(k) }
                    // On n'y descend pas : s'il abrite un élément ignoré par l'utilisateur, il doit être protégé comme lui.
                    let below = lowered + "/"
                    if excludes.contains(where: { $0.hasPrefix(below) }) { out.excludedSeen.insert(k) }
                    continue
                }
                let isDir = v.isDirectory == true
                guard isDir || v.isRegularFile == true else {
                    // Lien symbolique, tube nommé, périphérique… : rien de cela ne se copie comme un fichier.
                    out.links += 1
                    out.shielded.insert(k)
                    continue
                }
                out.entries[k] = Entry(rel: rel, isDir: isDir, size: Int64(v.fileSize ?? 0),
                                       mtime: v.contentModificationDate ?? .distantPast)
                if isDir { stack.append((item, rel)) }
            }
            tick(out.entries.count)
        }
        return out
    }

    /// - Parameter caseInsensitive: la destination ne distingue pas majuscules et minuscules (cas d'APFS par défaut,
    ///   d'exFAT et des partages SMB) : « Photos » et « photos » y désignent le même élément.
    public static func plan(source: ScanResult, destination: ScanResult, caseInsensitive: Bool = false) -> SyncPlan {
        var p = SyncPlan()
        p.temps = destination.temps
        p.skippedLinks = source.links
        p.openCatalogs = source.openCatalogs.sorted()
        let canon: (String) -> String = caseInsensitive ? { $0.lowercased() } : { $0 }

        func hit(_ k: String, in set: Set<String>) -> String? {
            guard !set.isEmpty else { return nil }
            var cur: String? = k
            while let c = cur {
                if set.contains(c) { return c }
                cur = parentKey(c)
            }
            return nil
        }

        // Source. Sur une destination insensible à la casse, deux fichiers de la source dont les noms ne diffèrent
        // que par les majuscules s'écraseraient l'un l'autre : aucun des deux n'est copié, et c'est signalé.
        var src: [String: Entry] = [:]
        var clashes = Set<String>()
        if caseInsensitive {
            src.reserveCapacity(source.entries.count)
            var clashing = Set<String>()
            for (k, e) in source.entries {
                let c = canon(k)
                guard let other = src[c] else { src[c] = e; continue }
                if other.isDir && e.isDir { continue }   // deux dossiers se fondent en un seul, sans perte
                clashes.insert(c)
                clashing.insert(other.rel)
                clashing.insert(e.rel)
            }
            for c in clashes { src[c] = nil }
            // Ces fichiers existent bel et bien : la source n'est pas « vide » pour autant.
            p.sourceFiles += clashing.count
            p.conflicts += clashing.map {
                Conflict(rel: $0, reason: "un autre élément de la source porte le même nom, aux majuscules près")
            }
        } else {
            src = source.entries
        }
        var dst: [String: Entry] = [:]
        if caseInsensitive {
            dst.reserveCapacity(destination.entries.count)
            for (k, e) in destination.entries { dst[canon(k)] = e }
        } else {
            dst = destination.entries
        }

        // Un dossier de la destination qui contient un élément ignoré ne doit jamais être effacé en bloc.
        var keep = Set<String>()
        for k in destination.excludedSeen {
            var cur = canon(k)
            while let parent = parentKey(cur), keep.insert(parent).inserted { cur = parent }
        }
        // Ce que la source écarte (masqué, lien) ou ne peut pas copier (conflit de casse) garde sa sauvegarde.
        let shield = Set(source.shielded.map(canon)).union(clashes)
        // Un lien ou un fichier spécial sur la destination : y écrire sortirait du dossier de sauvegarde.
        let barrier = Set(destination.shielded.map(canon))

        var active = Set<String>()   // dossiers où un fichier est copié, remplacé ou effacé
        var unchanged: [(key: String, src: Entry, dst: Entry)] = []

        for (k, s) in src {
            if !s.isDir { p.sourceFiles += 1 }
            if hit(k, in: clashes) != nil { continue }
            if let blocker = hit(k, in: barrier) {
                if blocker == k {
                    p.conflicts.append(Conflict(rel: s.rel, reason: "un lien ou un fichier spécial porte ce nom sur la destination"))
                }
                continue
            }
            let d = dst[k]
            // Seules les majuscules du nom ont changé : on renomme sur place au lieu d'effacer puis de recopier.
            if let d, d.isDir == s.isDir, lastComponent(key(d.rel)) != lastComponent(key(s.rel)) {
                p.renames.append(Rename(from: d.rel, to: s.rel))
            }
            if s.isDir {
                if d?.isDir != true { p.dirs.append(s.rel) }
                continue
            }
            if let d, d.isDir, keep.contains(k) {
                p.conflicts.append(Conflict(rel: s.rel, reason: "un dossier à conserver porte le même nom sur la destination"))
                continue
            }
            // Tolérance de 2 s : les horodatages SMB et exFAT sont moins précis que ceux d'APFS.
            if let d, !d.isDir, d.size == s.size, abs(d.mtime.timeIntervalSince(s.mtime)) <= 2 {
                p.unchanged += 1
                unchanged.append((k, s, d))
            } else {
                p.copies.append(s)
                p.bytesToCopy += s.size
                if let d, !d.isDir {
                    p.replaced += 1
                    p.bytesReplaced += d.size
                    p.largestReplaced = max(p.largestReplaced, d.size)
                }
                active.insert(parentKey(k) ?? "")
            }
        }
        var gone: [String: Entry] = [:]
        var keptMissing = Set<String>()
        for (k, d) in dst {
            if let s = src[k], s.isDir == d.isDir { continue }
            if d.isDir && keep.contains(k) {
                if src[k] == nil { keptMissing.insert(k) }
                continue
            }
            if hit(k, in: shield) != nil { continue }
            gone[k] = d
            if !d.isDir {
                p.bytesToDelete += d.size
                p.filesToDelete += 1
                active.insert(parentKey(k) ?? "")
            }
        }
        p.keptDirs = keptMissing.filter { k in parentKey(k).map { !keptMissing.contains($0) } ?? true }
            .compactMap { dst[$0]?.rel }.sorted()

        // Un dossier effacé emporte son contenu : on ne garde que le plus haut niveau, avec ses totaux.
        var totals: [String: (files: Int, bytes: Int64)] = [:]
        for (k, d) in gone where !d.isDir {
            var top = k
            while let parent = parentKey(top), gone[parent] != nil { top = parent }
            totals[top, default: (0, 0)].files += 1
            totals[top]!.bytes += d.size
        }
        p.deletes = gone.compactMap { k, d in
            if let parent = parentKey(k), gone[parent] != nil { return nil }
            return DeleteItem(rel: d.rel, isDir: d.isDir, files: totals[k]?.files ?? 0, bytes: totals[k]?.bytes ?? 0)
        }

        // Même nom, même taille, même date à 2 s près ne prouve pas le même contenu : des rafales renumérotées
        // après un tri donnent exactement cela. Dans tout dossier où un fichier vient d'être ajouté, remplacé ou
        // retiré, on comparera donc le contenu des « inchangés » ambigus : ceux dont la date n'est pas rigoureusement
        // identique, et ceux qui ont, d'un côté ou de l'autre, un voisin de même taille à moins de 2 s.
        if !active.isEmpty {
            var srcTimes: [String: [Int64: [Date]]] = [:], dstTimes: [String: [Int64: [Date]]] = [:]
            for (k, s) in src where !s.isDir {
                let folder = parentKey(k) ?? ""
                if active.contains(folder) { srcTimes[folder, default: [:]][s.size, default: []].append(s.mtime) }
            }
            for (k, d) in dst where !d.isDir {
                let folder = parentKey(k) ?? ""
                if active.contains(folder) { dstTimes[folder, default: [:]][d.size, default: []].append(d.mtime) }
            }
            func hasTwin(_ dates: [Date]?, _ t: Date) -> Bool {
                var near = 0
                for date in dates ?? [] where abs(date.timeIntervalSince(t)) <= 2 {
                    near += 1
                    if near > 1 { return true }   // le fichier lui-même compte pour un
                }
                return false
            }
            for (k, s, d) in unchanged where s.size > 0 {
                let folder = parentKey(k) ?? ""
                guard active.contains(folder) else { continue }
                p.unchangedByFolder[folder, default: []].append(s)
                let exact = abs(d.mtime.timeIntervalSince(s.mtime)) < 0.001
                if !exact || hasTwin(srcTimes[folder]?[s.size], s.mtime) || hasTwin(dstTimes[folder]?[d.size], d.mtime) {
                    p.suspects.append(SyncPlan.Suspect(entry: s, folder: folder))
                }
            }
        }

        p.copies.sort { $0.rel.localizedStandardCompare($1.rel) == .orderedAscending }
        p.deletes.sort { $0.rel.localizedStandardCompare($1.rel) == .orderedAscending }
        p.conflicts.sort { $0.rel < $1.rel }
        // Les dossiers avant leur contenu : le chemin d'un enfant reste valable quelle que soit la casse de son parent.
        p.renames.sort { ($0.from.count, $0.from) < ($1.from.count, $1.from) }
        p.dirs.sort()
        return p
    }

    /// Compare le contenu des fichiers ambigus repérés par `plan` et replace dans les copies ceux qui diffèrent.
    /// Dès qu'une différence est prouvée dans un dossier, tous ses fichiers « inchangés » sont comparés à leur tour.
    public static func verifySuspects(_ plan: inout SyncPlan, src: URL, dst: URL, tick: (Int, Int) -> Void) throws {
        var queue = plan.suspects
        let byFolder = plan.unchangedByFolder
        plan.suspects = []
        plan.unchangedByFolder = [:]
        guard !queue.isEmpty else { return }
        var seen = Set(queue.map(\.entry.rel))
        var widened = Set<String>()
        var index = 0
        while index < queue.count {
            try Task.checkCancellation()
            let suspect = queue[index]
            let s = suspect.entry
            index += 1
            tick(index, queue.count)
            if sameSamples(src.appendingPathComponent(s.rel), dst.appendingPathComponent(s.rel), size: s.size) { continue }
            plan.contentMismatches += 1
            plan.unchanged -= 1
            plan.replaced += 1
            plan.bytesReplaced += s.size
            plan.largestReplaced = max(plan.largestReplaced, s.size)
            plan.copies.append(s)
            plan.bytesToCopy += s.size
            if widened.insert(suspect.folder).inserted {
                for other in byFolder[suspect.folder] ?? [] where seen.insert(other.rel).inserted {
                    queue.append(SyncPlan.Suspect(entry: other, folder: suspect.folder))
                }
            }
        }
        plan.verified = queue.count
        plan.copies.sort { $0.rel.localizedStandardCompare($1.rel) == .orderedAscending }
    }

    /// Compare le début, le milieu et la fin de deux fichiers de même taille (les fichiers courts en entier).
    static func sameSamples(_ a: URL, _ b: URL, size: Int64) -> Bool {
        let chunk: Int64 = 64 << 10
        guard let ha = try? FileHandle(forReadingFrom: a), let hb = try? FileHandle(forReadingFrom: b) else { return false }
        defer { try? ha.close(); try? hb.close() }
        var ranges: [(UInt64, Int)] = [(0, Int(min(size, chunk)))]
        if size <= 3 * chunk {
            ranges = [(0, Int(size))]
        } else {
            let middle = UInt64(size / 2 - chunk / 2)
            let end = UInt64(size - chunk)
            ranges.append((middle, Int(chunk)))
            ranges.append((end, Int(chunk)))
        }
        for (offset, length) in ranges {
            do {
                try ha.seek(toOffset: offset)
                try hb.seek(toOffset: offset)
                let da = try ha.read(upToCount: length) ?? Data()
                let db = try hb.read(upToCount: length) ?? Data()
                if da.count != length || da != db { return false }
            } catch {
                return false
            }
        }
        return true
    }
}

public enum SyncRunner {
    /// Nombre d'échecs d'affilée au-delà duquel on vérifie que la destination accepte encore l'écriture.
    static let maxConsecutiveFailures = 25

    /// `acknowledged` : l'utilisateur a explicitement confirmé les situations signalées par `plan.risks`.
    public static func run(plan: SyncPlan, roots: Roots, acknowledged: Bool, onProgress: (SyncProgress) -> Void) -> SyncResult {
        let fm = FileManager.default
        let src = roots.src, dst = roots.dst
        let start = Date()
        var prog = SyncProgress(bytesTotal: plan.bytesToCopy, deleteItemsTotal: plan.deletes.count, startedAt: start)
        var errors: [String] = []
        var abortReason: String?
        var consecutive = 0
        var deletedItems: [String] = []
        var copiedFiles: [String] = []
        var samples: [(t: Date, bytes: Int64)] = [(start, 0)]
        var lastReport = Date.distantPast

        func report(force: Bool = false) {
            let now = Date()
            guard force || now.timeIntervalSince(lastReport) > 0.15 else { return }
            lastReport = now
            samples.append((now, prog.bytesDone))
            while samples.count > 2, now.timeIntervalSince(samples[0].t) > 5 { samples.removeFirst() }
            let dt = now.timeIntervalSince(samples[0].t)
            prog.speed = dt > 0.3 ? max(0, Double(prog.bytesDone - samples[0].bytes) / dt) : prog.speed
            prog.elapsed = now.timeIntervalSince(start)
            onProgress(prog)
        }

        func finish() -> SyncResult {
            prog.current = ""
            prog.phase = .finished
            report(force: true)
            var result = SyncResult(progress: prog, unchanged: plan.unchanged, errors: errors,
                                    cancelled: Task.isCancelled, abortReason: abortReason)
            result.deletedItems = deletedItems
            result.copiedFiles = copiedFiles
            return result
        }

        func abort(_ reason: String) {
            guard abortReason == nil else { return }
            abortReason = reason
            errors.append(reason)
        }

        /// Les deux dossiers sont-ils toujours sur les volumes qui ont été analysés ?
        func volumesIntact() -> Bool {
            fm.fileExists(atPath: src.path)
                && RootCheck.volumeID(of: src) == roots.srcVolume
                && RootCheck.volumeID(of: dst) == roots.dstVolume
        }

        /// La destination accepte-t-elle encore qu'on y écrive ?
        func destinationWritable() -> Bool {
            let probe = dst.appendingPathComponent(Scanner.tempPrefix + "essai-" + UUID().uuidString.prefix(8))
            guard fm.createFile(atPath: probe.path, contents: nil) else { return false }
            try? fm.removeItem(at: probe)
            return true
        }

        func fail(_ rel: String, _ error: Error) {
            errors.append("\(rel) — \(error.localizedDescription)")
            prog.failed += 1
            consecutive += 1
            if !volumesIntact() || !fm.fileExists(atPath: dst.path) {
                abort("La source ou la destination n'est plus accessible. Synchronisation interrompue.")
            } else if isOutOfSpace(error) {
                abort("La destination est pleine. Synchronisation interrompue.")
            } else if consecutive >= maxConsecutiveFailures {
                // Un seul dossier défectueux ne doit pas priver de sauvegarde tous ceux qui suivent :
                // on n'arrête que si la destination entière refuse l'écriture.
                if destinationWritable() {
                    consecutive = 0
                } else {
                    abort("La destination n'accepte plus l'écriture (lecture seule ou droits insuffisants). Synchronisation interrompue.")
                }
            }
        }

        // Garde-fous : aucun appelant ne peut exécuter un plan dangereux, quelle que soit l'interface.
        if let blocked = plan.blockedReason { abort(blocked); return finish() }
        if !plan.risks.isEmpty && !acknowledged {
            abort("Situation inhabituelle non confirmée : rien n'a été modifié. \(plan.risks.joined(separator: " "))")
            return finish()
        }
        do { try RootCheck.validate(src: src, dst: dst) } catch { abort(error.localizedDescription); return finish() }
        guard volumesIntact(), fm.fileExists(atPath: dst.path) == plan.destinationExists else {
            abort("La source ou la destination a changé depuis l'analyse : rien n'a été modifié. Relancez la synchronisation.")
            return finish()
        }
        if !plan.destinationExists {
            // Sans dossiers intermédiaires : un parent absent signifie un volume manquant, pas un dossier à créer.
            do { try fm.createDirectory(at: dst, withIntermediateDirectories: false) } catch {
                abort("Impossible de créer le dossier de destination : \(error.localizedDescription)")
                return finish()
            }
        }

        for conflict in plan.conflicts {
            errors.append("\(conflict.rel) — non copié : \(conflict.reason)")
            prog.failed += 1
        }
        for t in plan.temps { try? fm.removeItem(at: t) }

        prog.phase = .deleting
        let srcComponents = RootCheck.components(src)
        let dstComponents = RootCheck.components(dst)
        for item in plan.deletes where abortReason == nil && !Task.isCancelled {
            prog.current = item.rel
            // Forcé pour les dossiers : leur suppression peut durer, autant afficher lequel est en cours.
            report(force: item.isDir)
            let target = dstComponents + item.rel.split(separator: "/").map { RootCheck.normalize(String($0)) }
            if RootCheck.isAncestorOrSame(target, of: srcComponents) {
                fail(item.rel, SyncError("refus d'effacer un dossier qui contient la source"))
            } else {
                do {
                    try fm.removeItem(at: dst.appendingPathComponent(item.rel))
                    prog.deleted += item.files
                    deletedItems.append(item.rel)
                    consecutive = 0
                } catch { fail(item.rel, error) }
            }
            prog.deleteItemsDone += 1
        }

        prog.phase = .folders
        prog.current = ""
        report(force: true)
        for r in plan.renames where abortReason == nil && !Task.isCancelled {
            // Renommage direct, en une opération : passer par un nom intermédiaire pourrait, en cas de coupure,
            // laisser un dossier entier sous un nom que rien ne rattache plus à la source.
            if rename(dst.appendingPathComponent(r.from).path, dst.appendingPathComponent(r.to).path) != 0 {
                fail(r.from, posixError())
            }
        }
        for rel in plan.dirs where abortReason == nil && !Task.isCancelled {
            do { try fm.createDirectory(at: dst.appendingPathComponent(rel), withIntermediateDirectories: true) }
            catch { fail(rel, error) }
        }

        prog.phase = .copying
        for f in plan.copies where abortReason == nil && !Task.isCancelled {
            prog.current = f.rel
            report()
            var fileBytes: Int64 = 0
            do {
                try copyFile(from: src.appendingPathComponent(f.rel), to: dst.appendingPathComponent(f.rel)) { n in
                    fileBytes += Int64(n)
                    prog.bytesDone += Int64(n)
                    report()
                }
                prog.copied += 1
                copiedFiles.append(f.rel)
                consecutive = 0
            } catch is CancellationError {
                prog.bytesDone -= fileBytes
                break
            } catch {
                // Rien de ce fichier n'est resté sur la destination : il ne compte pas dans le volume transféré.
                prog.bytesDone -= fileBytes
                prog.bytesSkipped += f.size
                fail(f.rel, error)
            }
        }

        return finish()
    }

    static func isOutOfSpace(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let e = current {
            if e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError { return true }
            if e.domain == NSPOSIXErrorDomain && (e.code == Int(ENOSPC) || e.code == Int(EDQUOT)) { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Copie vers un fichier temporaire caché puis le met à la place de la cible, pour ne jamais laisser un fichier
    /// tronqué sous son vrai nom. La version précédente reste en place jusqu'à ce que la nouvelle soit complète.
    static func copyFile(from: URL, to: URL, onBytes: (Int) -> Void) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: to.path, isDirectory: &isDir), isDir.boolValue {
            throw SyncError("un dossier du même nom existe sur la destination")
        }
        // O_NONBLOCK : ouvrir un tube nommé sans cela attendrait indéfiniment un écrivain.
        let inFD = open(from.path, O_RDONLY | O_NONBLOCK)
        guard inFD >= 0 else { throw SyncError("lecture impossible sur la source (\(reason(errno)))") }
        let input = FileHandle(fileDescriptor: inFD, closeOnDealloc: true)
        var before = stat()
        guard fstat(inFD, &before) == 0 else { throw posixError() }
        guard (before.st_mode & S_IFMT) == S_IFREG else { throw SyncError("ce n'est pas un fichier ordinaire") }

        let tmp = to.deletingLastPathComponent()
            .appendingPathComponent(Scanner.tempPrefix + UUID().uuidString.prefix(8))
        let outFD = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard outFD >= 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: "écriture impossible sur la destination (\(reason(code)))"])
        }
        let output = FileHandle(fileDescriptor: outFD, closeOnDealloc: true)
        do {
            var written: Int64 = 0
            do {
                while true {
                    try Task.checkCancellation()
                    let n: Int = try autoreleasepool {
                        guard let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty else { return 0 }
                        try output.write(contentsOf: chunk)
                        return chunk.count
                    }
                    if n == 0 { break }
                    written += Int64(n)
                    onBytes(n)
                }
                // Une erreur d'écriture différée (disque plein, réseau) doit apparaître avant de toucher à l'ancienne version.
                try output.synchronize()
                try output.close()
            } catch {
                try? output.close()
                throw error
            }

            var after = stat()
            guard fstat(inFD, &after) == 0,
                  after.st_size == before.st_size, written == Int64(before.st_size),
                  after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
                throw SyncError("le fichier a été modifié pendant la copie ; il sera recopié à la prochaine synchronisation")
            }

            let created = date(before.st_birthtimespec), modified = date(before.st_mtimespec)
            copyFinderMetadata(from: from.path, to: tmp.path)
            // Les dates en dernier : écrire d'autres attributs peut modifier la date côté serveur.
            try? fm.setAttributes([.creationDate: created], ofItemAtPath: tmp.path)
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: tmp.path)

            let landed = (try fm.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value
            guard landed == written else {
                throw SyncError("la copie sur la destination est incomplète")
            }
            try replace(tmp: tmp, target: to)

            // Certains volumes (exFAT avec étiquettes) perdent la date de création au renommage : on la repose au besoin.
            if let now = (try? fm.attributesOfItem(atPath: to.path))?[.creationDate] as? Date,
               abs(now.timeIntervalSince(created)) > 2 {
                try? fm.setAttributes([.creationDate: created], ofItemAtPath: to.path)
                try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: to.path)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Met le fichier temporaire à la place de la cible. En cas d'échec, l'ancienne version est toujours là.
    static func replace(tmp: URL, target: URL) throws {
        if rename(tmp.path, target.path) == 0 { return }
        let code = errno
        var st = stat()
        guard [EEXIST, EPERM, EACCES, ENOTSUP].contains(code), lstat(target.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG else { throw posixError(code) }
        // Certains serveurs refusent d'écraser un fichier lors d'un renommage. On écarte alors l'ancienne version
        // sous un nom temporaire (retiré à la prochaine synchronisation s'il devait rester) et on la remet en cas d'échec.
        let aside = target.deletingLastPathComponent()
            .appendingPathComponent(Scanner.tempPrefix + "avant-" + UUID().uuidString.prefix(8))
        guard rename(target.path, aside.path) == 0 else { throw posixError(code) }
        if rename(tmp.path, target.path) == 0 {
            try? FileManager.default.removeItem(at: aside)
            return
        }
        let second = errno
        _ = rename(aside.path, target.path)
        throw posixError(second)
    }

    /// Étiquettes, couleur et commentaire du Finder. Au mieux : un serveur qui les refuse ne fait pas échouer la copie.
    static func copyFinderMetadata(from: String, to: String) {
        for name in ["com.apple.metadata:_kMDItemUserTags", "com.apple.FinderInfo", "com.apple.metadata:kMDItemFinderComment"] {
            let size = getxattr(from, name, nil, 0, 0, 0)
            guard size > 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: size)
            let read = getxattr(from, name, &buffer, size, 0, 0)
            if read > 0 { _ = setxattr(to, name, buffer, read, 0, 0) }
        }
    }

    static func date(_ t: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1_000_000_000)
    }

    /// Cause d'une erreur système, en français pour les plus courantes.
    static func reason(_ code: Int32) -> String {
        switch code {
        case EACCES, EPERM: return "accès refusé"
        case ENOENT: return "élément introuvable"
        case ENOSPC, EDQUOT: return "espace insuffisant"
        case EROFS: return "volume en lecture seule"
        case EIO: return "erreur de lecture ou d'écriture du disque"
        case ENAMETOOLONG: return "nom trop long"
        case EISDIR: return "un dossier porte ce nom"
        default: return String(cString: strerror(code))
        }
    }

    static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: reason(code)])
    }
}
