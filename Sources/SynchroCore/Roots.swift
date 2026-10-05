import Foundation

/// Identité du volume qui porte un dossier : sert à détecter qu'un disque a été débranché,
/// remplacé ou remonté ailleurs entre l'analyse et l'exécution.
public struct VolumeID: Equatable, Sendable {
    public let mountPoint: String
    public let identity: String
}

/// Les deux dossiers d'une synchronisation, tels qu'ils ont été analysés.
public struct Roots: Sendable {
    public let src: URL
    public let dst: URL
    public let srcVolume: VolumeID?
    public let dstVolume: VolumeID?

    public init(src: URL, dst: URL) {
        self.init(src: src, dst: dst, srcVolume: RootCheck.volumeID(of: src), dstVolume: RootCheck.volumeID(of: dst))
    }

    init(src: URL, dst: URL, srcVolume: VolumeID?, dstVolume: VolumeID?) {
        self.src = src
        self.dst = dst
        self.srcVolume = srcVolume
        self.dstVolume = dstVolume
    }
}

public enum RootCheck {
    /// Dossier existant le plus proche (le dossier lui-même, sinon un de ses parents).
    static func nearestExisting(_ url: URL) -> URL {
        var u = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: u.path), u.path != "/" {
            u = u.deletingLastPathComponent()
        }
        return u
    }

    public static func volumeID(of url: URL) -> VolumeID? {
        let u = nearestExisting(url)
        var fs = statfs()
        guard statfs(u.path, &fs) == 0 else { return nil }
        let uuid = (try? u.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        // L'UUID survit à un rebranchement ; les volumes réseau n'en ont pas, on prend alors l'adresse du partage,
        // ramenée à une forme qui ne dépend pas de la façon dont il a été monté.
        let from = cString(fs.f_mntfromname)
        let network = cString(fs.f_fstypename) == "smbfs" ? Mounter.canonicalMountSource(from) : nil
        return VolumeID(mountPoint: cString(fs.f_mntonname), identity: uuid ?? network ?? from)
    }

    /// Espace libre, en octets, sur le volume qui porte (ou portera) ce dossier.
    public static func freeSpace(at url: URL) -> Int64? {
        var fs = statfs()
        guard statfs(nearestExisting(url).path, &fs) == 0 else { return nil }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }

    /// Le même nom, majuscules et minuscules ASCII inversées. Les autres lettres ne sont pas touchées : selon les
    /// volumes, « ß », « µ » ou « ı » n'ont pas les mêmes équivalents, et l'essai ne prouverait rien.
    static func asciiCaseSwapped(_ name: String) -> String {
        String(name.map { c -> Character in
            guard c.isASCII, c.isLetter else { return c }
            return Character(c.isUppercase ? c.lowercased() : c.uppercased())
        })
    }

    /// Le volume qui porte (ou portera) ce dossier confond-il majuscules et minuscules ?
    /// On le constate sur un élément existant quand c'est possible (`samples` : chemins relatifs connus,
    /// par exemple issus de l'analyse) ; sinon on se fie à ce que le volume déclare.
    public static func isCaseInsensitive(at url: URL, samples: [String] = []) -> Bool {
        let base = nearestExisting(url)
        let fm = FileManager.default
        let roots = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).prefix(50).map { base.appendingPathComponent($0) }
        for candidate in roots + samples.prefix(50).map({ url.appendingPathComponent($0) }) {
            let name = candidate.lastPathComponent
            let swapped = asciiCaseSwapped(name)
            guard swapped != name else { continue }
            let folder = candidate.deletingLastPathComponent()
            // Si l'autre orthographe existe aussi, à part entière, l'essai ne dit rien.
            guard let siblings = try? fm.contentsOfDirectory(atPath: folder.path), !siblings.contains(swapped) else { continue }
            var a = stat(), b = stat()
            guard lstat(candidate.path, &a) == 0 else { continue }
            if lstat(folder.appendingPathComponent(swapped).path, &b) == 0 { return true }
            if errno == ENOENT { return false }
        }
        if let sensitive = (try? base.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames {
            return !sensitive
        }
        // Dans le doute, on suppose le cas le plus courant.
        return true
    }

    /// Composants du chemin, comparables sans tenir compte de la casse ni de la forme Unicode.
    /// Un dossier situé sur un partage SMB est ramené à son adresse, pour reconnaître un même partage monté deux fois.
    static func components(_ url: URL) -> [String] {
        // Les liens ne se résolvent que sur ce qui existe : on résout le parent existant, puis on rajoute la suite.
        let standardized = url.standardizedFileURL
        let existing = nearestExisting(standardized)
        let tail = standardized.pathComponents.dropFirst(existing.pathComponents.count)
        let resolved = existing.resolvingSymlinksInPath()
        var raw: [String]
        if let smb = Mounter.smbAddress(forLocal: resolved), let address = Mounter.parse(smb) {
            raw = ["smb:", Mounter.normalizedHost(address.host), address.share]
            raw += address.sub.split(separator: "/").map(String.init)
        } else {
            raw = resolved.pathComponents
        }
        return (raw + tail).map(normalize)
    }

    static func normalize(_ component: String) -> String {
        component.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func isAncestorOrSame(_ a: [String], of b: [String]) -> Bool {
        a.count <= b.count && Array(b.prefix(a.count)) == a
    }

    /// Refuse les configurations où un dossier contient l'autre (la synchronisation effacerait la source
    /// elle-même, ou recopierait la sauvegarde dans la sauvegarde), et celles qui visent un volume absent.
    public static func validate(src: URL, dst: URL) throws {
        for (url, role) in [(src, "source"), (dst, "destination")] {
            // Un dossier resté sous /Volumes après le débranchement d'un disque se trouve en réalité sur le disque de démarrage.
            let parts = url.standardizedFileURL.pathComponents
            if parts.count >= 3, parts[1] == "Volumes",
               let volume = volumeID(of: url), !volume.mountPoint.hasPrefix("/Volumes/") {
                throw SyncError("Le volume « \(parts[2]) » de la \(role) n'est pas connecté.")
            }
        }
        let a = components(src), b = components(dst)
        if a == b {
            throw SyncError("La source et la destination sont le même dossier.")
        }
        if isAncestorOrSame(b, of: a) {
            throw SyncError("La destination contient la source : la synchronisation effacerait la source elle-même. Choisissez un dossier de destination réservé à cette sauvegarde.")
        }
        if isAncestorOrSame(a, of: b) {
            throw SyncError("La destination se trouve à l'intérieur de la source. Choisissez une destination située ailleurs.")
        }
    }
}

/// Chaîne C stockée dans un tuple de taille fixe (champs de statfs).
func cString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
}
