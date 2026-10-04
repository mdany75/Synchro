import Foundation
import NetFS

/// Traduit une destination (chemin local ou smb://hôte/partage/sous-dossier) en dossier local,
/// en montant le partage au besoin. Le mot de passe vient du Trousseau macOS, jamais de l'app.
enum Mounter {
    static func isSMB(_ dest: String) -> Bool {
        dest.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("smb://")
    }

    static func resolve(_ dest: String) throws -> URL {
        let trimmed = dest.trimmingCharacters(in: .whitespaces)
        guard isSMB(trimmed) else {
            guard !trimmed.isEmpty else { throw SyncError("Aucune destination définie.") }
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        var parts = trimmed.dropFirst(6).split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.count >= 2 else {
            throw SyncError("Destination invalide. Format attendu : smb://serveur/partage/dossier")
        }
        let host = stripUser(parts.removeFirst())
        let share = parts.removeFirst()
        let sub = parts.joined(separator: "/")

        func located(_ mount: URL) -> URL { sub.isEmpty ? mount : mount.appendingPathComponent(sub) }

        if let mount = existingMount(host: host, share: share) { return located(mount) }

        var comps = URLComponents()
        comps.scheme = "smb"
        comps.host = host
        comps.path = "/" + share
        guard let url = comps.url else { throw SyncError("Adresse du serveur invalide : \(host)") }

        var mountpoints: Unmanaged<CFArray>?
        let rc = NetFSMountURLSync(url as CFURL, nil, nil, nil, nil, nil, &mountpoints)
        if rc == 0, let first = (mountpoints?.takeRetainedValue() as? [String])?.first {
            return located(URL(fileURLWithPath: first))
        }
        if let mount = existingMount(host: host, share: share) { return located(mount) }
        throw SyncError("Connexion à smb://\(host)/\(share) impossible (code \(rc)). Vérifiez que le NAS est allumé, ou connectez le partage une fois dans le Finder (⌘K) en enregistrant le mot de passe dans le Trousseau.")
    }

    /// Dossier déposé ou choisi : suit les alias Finder et les liens symboliques jusqu'au vrai dossier.
    static func resolveDropped(_ url: URL) -> URL {
        var u = url
        if (try? u.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true,
           let target = try? URL(resolvingAliasFileAt: u) {
            u = target
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue {
            u = u.deletingLastPathComponent()
        }
        return u
    }

    /// Si le dossier est sur un partage SMB monté, renvoie son adresse smb:// (remontable automatiquement).
    static func smbAddress(forLocal url: URL) -> String? {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return nil }
        let type = withUnsafePointer(to: &fs.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
        guard type == "smbfs" else { return nil }
        let from = withUnsafePointer(to: &fs.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
        let on = withUnsafePointer(to: &fs.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
        let comps = from.drop(while: { $0 == "/" }).split(separator: "/", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        guard comps.count == 2, url.path.hasPrefix(on) else { return nil }
        let sub = String(url.path.dropFirst(on.count))
        return "smb://\(stripUser(comps[0]))/\(comps[1])\(sub)"
    }

    private static func stripUser(_ s: String) -> String {
        guard let at = s.lastIndex(of: "@") else { return s }
        return String(s[s.index(after: at)...])
    }

    private static func existingMount(host: String, share: String) -> URL? {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let buf else { return nil }
        let wantedHost = host.lowercased()
        for i in 0..<Int(n) {
            var fs = buf[i]
            guard fs.f_flags & UInt32(MNT_DONTBROWSE) == 0 else { continue }
            let type = withUnsafePointer(to: &fs.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
            guard type == "smbfs" else { continue }
            let from = withUnsafePointer(to: &fs.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
            let on = withUnsafePointer(to: &fs.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
            let comps = from.drop(while: { $0 == "/" }).split(separator: "/", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            guard comps.count == 2 else { continue }
            let mountedHost = stripUser(comps[0]).lowercased()
            let hostMatches = mountedHost == wantedHost || mountedHost.hasPrefix(wantedHost + ".")
            if hostMatches, comps[1].caseInsensitiveCompare(share) == .orderedSame {
                return URL(fileURLWithPath: on)
            }
        }
        return nil
    }
}
