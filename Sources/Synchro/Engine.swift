import Foundation

struct Entry: Sendable {
    let rel: String
    let isDir: Bool
    let size: Int64
    let mtime: Date
}

struct SyncPlan: Sendable {
    var copies: [Entry] = []
    var dirs: [String] = []
    var deletes: [Entry] = []
    var temps: [URL] = []
    var bytesToCopy: Int64 = 0
    var bytesToDelete: Int64 = 0
    var filesToDelete = 0
    var unchanged = 0
    var sourceFiles = 0
    var skippedLinks = 0

    var isEmpty: Bool { copies.isEmpty && dirs.isEmpty && deletes.isEmpty }
}

struct SyncProgress: Sendable {
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var copied = 0
    var deleted = 0
    var current = ""
    var speed: Double = 0
    var elapsed: TimeInterval = 0

    var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }
    var remaining: TimeInterval? { speed > 0 ? Double(bytesTotal - bytesDone) / speed : nil }
}

struct SyncResult: Sendable {
    var progress: SyncProgress
    var unchanged: Int
    var errors: [String]
    var cancelled: Bool

    var averageSpeed: Double { progress.elapsed > 0 ? Double(progress.bytesDone) / progress.elapsed : 0 }
}

struct SyncError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Scanner {
    static let tempPrefix = ".synchro-tmp-"

    /// Fichiers système jamais synchronisés, même si les fichiers cachés sont inclus.
    static let systemNames: Set<String> = [
        ".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd", ".DocumentRevisions-V100",
        ".TemporaryItems", ".VolumeIcon.icns", ".apdisk", ".com.apple.timemachine.donotpresent",
        "@Recycle", ".@__thumb", ".streams",
    ]

    static func isIgnoredName(_ name: String, hidden: Bool, ignoreHidden: Bool) -> Bool {
        if systemNames.contains(name) || name.hasPrefix("._") { return true }
        return ignoreHidden && (hidden || name.hasPrefix("."))
    }

    static func key(_ rel: String) -> String { rel.precomposedStringWithCanonicalMapping }

    struct Result {
        var entries: [String: Entry] = [:]
        var links = 0
        var temps: [URL] = []
    }

    static func scan(root: URL, excludes: Set<String>, ignoreHidden: Bool, tick: (Int) -> Void) throws -> Result {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        let keySet = Set(keys)
        var out = Result()
        var stack: [(url: URL, rel: String)] = [(root, "")]
        while let top = stack.popLast() {
            try Task.checkCancellation()
            let items = try fm.contentsOfDirectory(at: top.url, includingPropertiesForKeys: keys, options: [])
            for item in items {
                let name = item.lastPathComponent
                if name.hasPrefix(tempPrefix) { out.temps.append(item); continue }
                let v = try item.resourceValues(forKeys: keySet)
                if isIgnoredName(name, hidden: v.isHidden == true, ignoreHidden: ignoreHidden) { continue }
                let rel = top.rel.isEmpty ? name : top.rel + "/" + name
                let k = key(rel)
                if excludes.contains(k) { continue }
                if v.isSymbolicLink == true { out.links += 1; continue }
                let isDir = v.isDirectory == true
                out.entries[k] = Entry(rel: rel, isDir: isDir, size: Int64(v.fileSize ?? 0),
                                       mtime: v.contentModificationDate ?? .distantPast)
                if isDir { stack.append((item, rel)) }
            }
            tick(out.entries.count)
        }
        return out
    }

    static func plan(source: Result, destination: Result) -> SyncPlan {
        var p = SyncPlan()
        p.temps = destination.temps
        p.skippedLinks = source.links
        let src = source.entries, dst = destination.entries

        for (k, s) in src {
            let d = dst[k]
            if s.isDir {
                if d?.isDir != true { p.dirs.append(s.rel) }
                continue
            }
            p.sourceFiles += 1
            // Tolérance de 2 s : les horodatages SMB sont moins précis que ceux d'APFS.
            if let d, !d.isDir, d.size == s.size, abs(d.mtime.timeIntervalSince(s.mtime)) <= 2 {
                p.unchanged += 1
            } else {
                p.copies.append(s)
                p.bytesToCopy += s.size
            }
        }

        var gone: [String: Entry] = [:]
        for (k, d) in dst {
            if let s = src[k], s.isDir == d.isDir { continue }
            gone[k] = d
            if !d.isDir { p.bytesToDelete += d.size; p.filesToDelete += 1 }
        }
        // Un dossier effacé emporte son contenu : on ne garde que le plus haut niveau.
        p.deletes = gone.filter { k, _ in
            guard let slash = k.lastIndex(of: "/") else { return true }
            return gone[String(k[..<slash])] == nil
        }.map(\.value)

        p.copies.sort { $0.rel.localizedStandardCompare($1.rel) == .orderedAscending }
        p.deletes.sort { $0.rel.localizedStandardCompare($1.rel) == .orderedAscending }
        p.dirs.sort()
        return p
    }
}

enum SyncRunner {
    static func run(plan: SyncPlan, src: URL, dst: URL, onProgress: (SyncProgress) -> Void) -> SyncResult {
        let fm = FileManager.default
        let start = Date()
        var prog = SyncProgress(bytesTotal: plan.bytesToCopy)
        var errors: [String] = []
        var samples: [(t: Date, bytes: Int64)] = [(start, 0)]
        var lastReport = Date.distantPast
        var aborted = false

        func report(force: Bool = false) {
            let now = Date()
            guard force || now.timeIntervalSince(lastReport) > 0.15 else { return }
            lastReport = now
            samples.append((now, prog.bytesDone))
            while samples.count > 2, now.timeIntervalSince(samples[0].t) > 5 { samples.removeFirst() }
            let dt = now.timeIntervalSince(samples[0].t)
            prog.speed = dt > 0.3 ? Double(prog.bytesDone - samples[0].bytes) / dt : prog.speed
            prog.elapsed = now.timeIntervalSince(start)
            onProgress(prog)
        }

        func fail(_ rel: String, _ error: Error) {
            errors.append("\(rel) — \(error.localizedDescription)")
            // Disque débranché ou NAS déconnecté : inutile d'accumuler des milliers d'erreurs.
            if !fm.fileExists(atPath: src.path) || !fm.fileExists(atPath: dst.path) {
                errors.append("La source ou la destination n'est plus accessible. Synchronisation interrompue.")
                aborted = true
            }
        }

        for t in plan.temps { try? fm.removeItem(at: t) }
        do { try fm.createDirectory(at: dst, withIntermediateDirectories: true) } catch { fail(dst.path, error) }

        for d in plan.deletes where !aborted && !Task.isCancelled {
            prog.current = d.rel
            do {
                try fm.removeItem(at: dst.appendingPathComponent(d.rel))
                prog.deleted += 1
            } catch { fail(d.rel, error) }
            report()
        }

        for rel in plan.dirs where !aborted && !Task.isCancelled {
            do { try fm.createDirectory(at: dst.appendingPathComponent(rel), withIntermediateDirectories: true) }
            catch { fail(rel, error) }
        }

        for f in plan.copies where !aborted && !Task.isCancelled {
            prog.current = f.rel
            var fileBytes: Int64 = 0
            do {
                try copyFile(from: src.appendingPathComponent(f.rel), to: dst.appendingPathComponent(f.rel), mtime: f.mtime) { n in
                    fileBytes += Int64(n)
                    prog.bytesDone += Int64(n)
                    report()
                }
                prog.copied += 1
            } catch is CancellationError {
                break
            } catch {
                prog.bytesDone += max(0, f.size - fileBytes)
                fail(f.rel, error)
            }
            report()
        }

        prog.current = ""
        report(force: true)
        return SyncResult(progress: prog, unchanged: plan.unchanged, errors: errors, cancelled: Task.isCancelled)
    }

    /// Copie vers un fichier temporaire caché puis renomme, pour ne jamais laisser un fichier tronqué sous son vrai nom.
    static func copyFile(from: URL, to: URL, mtime: Date, onBytes: (Int) -> Void) throws {
        let fm = FileManager.default
        let tmp = to.deletingLastPathComponent()
            .appendingPathComponent(Scanner.tempPrefix + UUID().uuidString.prefix(8))
        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            throw SyncError("Impossible de créer le fichier sur la destination")
        }
        do {
            let input = try FileHandle(forReadingFrom: from)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: tmp)
            do {
                while true {
                    try Task.checkCancellation()
                    let n: Int = try autoreleasepool {
                        guard let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty else { return 0 }
                        try output.write(contentsOf: chunk)
                        return chunk.count
                    }
                    if n == 0 { break }
                    onBytes(n)
                }
                try output.close()
            } catch {
                try? output.close()
                throw error
            }
            try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: tmp.path)
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            try fm.moveItem(at: tmp, to: to)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }
}
