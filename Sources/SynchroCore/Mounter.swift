import Foundation
import NetFS

/// Traduit une destination (chemin local ou smb://hôte/partage/sous-dossier) en dossier local,
/// en montant le partage au besoin. Le mot de passe vient du Trousseau macOS, jamais de l'app.
public enum Mounter {
    public static func isSMB(_ dest: String) -> Bool {
        dest.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("smb://")
    }

    struct Address: Equatable {
        var host: String
        var share: String
        var sub: String
    }

    static func parse(_ address: String) -> Address? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard isSMB(trimmed) else { return nil }
        var parts = trimmed.dropFirst(6).split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.count >= 2 else { return nil }
        let host = stripUser(parts.removeFirst())
        let share = parts.removeFirst()
        return Address(host: host, share: share, sub: parts.joined(separator: "/"))
    }

    public static func resolve(_ dest: String) throws -> URL {
        let trimmed = dest.trimmingCharacters(in: .whitespaces)
        guard isSMB(trimmed) else {
            let path = (trimmed as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else {
                throw SyncError(trimmed.isEmpty ? "Aucune destination définie." : "Le chemin de la destination est incomplet : \(trimmed)")
            }
            return URL(fileURLWithPath: path)
        }
        guard let address = parse(trimmed) else {
            throw SyncError("Destination invalide. Format attendu : smb://serveur/partage/dossier")
        }
        func located(_ mount: URL) -> URL { address.sub.isEmpty ? mount : mount.appendingPathComponent(address.sub) }

        if let mount = existingMount(host: address.host, share: address.share) { return located(mount) }

        guard let host = address.host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
              let share = address.share.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))),
              let url = URL(string: "smb://\(host)/\(share)") else {
            throw SyncError("Adresse du serveur invalide : \(address.host)")
        }

        var mountpoints: Unmanaged<CFArray>?
        let rc = NetFSMountURLSync(url as CFURL, nil, nil, nil, nil, nil, &mountpoints)
        let mounted = (mountpoints?.takeRetainedValue() as? [String])?.first
        // EEXIST : le partage était déjà monté, le système renvoie son point de montage.
        if rc == 0 || rc == EEXIST, let mounted {
            return located(URL(fileURLWithPath: mounted))
        }
        if let mount = existingMount(host: address.host, share: address.share) { return located(mount) }
        throw SyncError("Connexion à smb://\(address.host)/\(address.share) impossible (code \(rc)). Vérifiez que le NAS est allumé, ou connectez le partage une fois dans le Finder (⌘K) en enregistrant le mot de passe dans le Trousseau.")
    }

    /// Dossier déposé ou choisi : suit les alias Finder et les liens symboliques jusqu'au vrai dossier.
    public static func resolveDropped(_ url: URL) -> URL {
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
    public static func smbAddress(forLocal url: URL) -> String? {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0, cString(fs.f_fstypename) == "smbfs" else { return nil }
        let on = cString(fs.f_mntonname)
        guard let from = mountSource(cString(fs.f_mntfromname)),
              url.path == on || url.path.hasPrefix(on + "/") else { return nil }
        return "smb://\(stripUser(from.host))/\(from.share)\(url.path.dropFirst(on.count))"
    }

    /// Nom d'hôte comparable : sans utilisateur, port, casse ni suffixe Bonjour.
    static func normalizedHost(_ host: String) -> String {
        var h = stripUser(host).lowercased()
        if let colon = h.lastIndex(of: ":"), h[h.index(after: colon)...].allSatisfy(\.isNumber) { h = String(h[..<colon]) }
        while h.hasSuffix(".") { h.removeLast() }
        for suffix in ["._smb._tcp.local", ".local"] where h.hasSuffix(suffix) {
            h.removeLast(suffix.count)
        }
        return h
    }

    private static func stripUser(_ s: String) -> String {
        guard let at = s.lastIndex(of: "@") else { return s }
        return String(s[s.index(after: at)...])
    }

    /// Décompose « //utilisateur@hôte/partage » tel que renvoyé par statfs.
    private static func mountSource(_ from: String) -> (host: String, share: String)? {
        let comps = from.drop(while: { $0 == "/" }).split(separator: "/", maxSplits: 1)
            .map { String($0).removingPercentEncoding ?? String($0) }
        return comps.count == 2 ? (comps[0], comps[1]) : nil
    }

    private static func existingMount(host: String, share: String) -> URL? {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let buf else { return nil }
        let wanted = normalizedHost(host)
        for i in 0..<Int(n) {
            let fs = buf[i]
            // Les montages masqués (Time Machine, par exemple) ne sont pas ceux de l'utilisateur.
            guard fs.f_flags & UInt32(MNT_DONTBROWSE) == 0, cString(fs.f_fstypename) == "smbfs",
                  let from = mountSource(cString(fs.f_mntfromname)) else { continue }
            if normalizedHost(from.host) == wanted, from.share.caseInsensitiveCompare(share) == .orderedSame {
                return URL(fileURLWithPath: cString(fs.f_mntonname))
            }
        }
        return nil
    }
}
