import AppKit
import Security
import SynchroCore

/// Mise à jour depuis la dernière Release GitHub du projet.
///
/// Au lancement, au plus une fois par jour (ou à la demande, menu Synchro → Rechercher une mise à jour…),
/// l'app demande à GitHub quelle est la dernière version publiée : une seule requête, sans rien sur
/// l'utilisateur ni ses fichiers. Si elle est plus récente, l'app propose de l'installer : l'image disque
/// est téléchargée, la signature Developer ID de la nouvelle app contrôlée (même équipe, même identifiant),
/// l'app remplacée en place dans son dossier, puis relancée. Rien n'est jamais installé sans un clic.
@MainActor
final class Updater {
    static let shared = Updater()
    nonisolated static let api = URL(string: "https://api.github.com/repos/mdany75/Synchro/releases/latest")!
    /// Intervalle minimal entre deux vérifications automatiques.
    static let interval: TimeInterval = 24 * 3600
    static let lastCheckKey = "derniereVerificationMAJ"
    nonisolated static let bundleID = "com.mdany75.synchro"

    /// Numéro de version « X.Y » ou « X.Y.Z » ; « 1.4 » et « 1.4.0 » sont la même version.
    struct Version: Comparable, CustomStringConvertible, Sendable {
        let parts: [Int]

        init?(_ text: String) {
            var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
            let numbers = t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
            parts = numbers.map { $0! }
        }

        private func part(_ i: Int) -> Int { i < parts.count ? parts[i] : 0 }

        static func < (a: Version, b: Version) -> Bool {
            for i in 0..<max(a.parts.count, b.parts.count) where a.part(i) != b.part(i) {
                return a.part(i) < b.part(i)
            }
            return false
        }

        static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }

        var description: String { parts.map(String.init).joined(separator: ".") }
    }

    struct Release: Equatable, Sendable {
        var version: Version
        /// L'image disque publiée avec la version.
        var download: URL
        /// La page de la version sur GitHub.
        var page: URL
        var notes: String
    }

    /// Version de l'app en cours ; absente pour un binaire sans Info.plist (développement).
    static var current: Version? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(Version.init)
    }

    /// Lit la réponse de l'API GitHub (« releases/latest »).
    nonisolated static func parse(_ data: Data) throws -> Release {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Payload: Decodable { let tag_name: String; let html_url: URL; let body: String?; let assets: [Asset] }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw SyncError("réponse de GitHub illisible") }
        guard let version = Version(payload.tag_name) else {
            throw SyncError("numéro de version illisible : \(payload.tag_name)")
        }
        guard let dmg = payload.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            throw SyncError("la version \(version) n'a pas d'image disque")
        }
        return Release(version: version, download: dmg.browser_download_url, page: payload.html_url, notes: payload.body ?? "")
    }

    /// Les notes de version, sans la mise en forme Markdown, raccourcies pour une boîte de dialogue.
    nonisolated static func summary(of notes: String, limit: Int = 600) -> String {
        var lines: [String] = []
        for raw in notes.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                line = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = "• " + line.dropFirst(2)
            }
            lines.append(line.replacingOccurrences(of: "`", with: ""))
        }
        let text = lines.joined(separator: "\n")
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    // MARK: - Vérification

    private var busy = false

    /// Au lancement : silencieux, et au plus une fois par jour.
    func checkAtLaunch() {
        guard Self.current != nil else { return }
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date, Date().timeIntervalSince(last) < Self.interval {
            return
        }
        check(manual: false)
    }

    /// `manual` : demandé par l'utilisateur, qui attend une réponse même s'il n'y a rien de neuf.
    func check(manual: Bool) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let release = try await Self.fetchLatest()
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                guard let current = Self.current else {
                    if manual { Self.alert("Version de développement", "Cette copie de Synchro n'a pas de numéro de version ; la dernière publiée est la \(release.version).") }
                    return
                }
                if current < release.version {
                    offer(release, current: current)
                } else if manual {
                    Self.alert("Synchro est à jour", "La version \(current) est la plus récente.")
                }
            } catch {
                if manual { Self.alert("Vérification impossible", "GitHub n'a pas pu être consulté : \(error.localizedDescription)") }
            }
        }
    }

    /// Adresse interrogée : celle de GitHub, ou pour un essai, `SYNCHRO_MAJ_URL` (un fichier JSON de même forme).
    nonisolated static var source: URL {
        ProcessInfo.processInfo.environment["SYNCHRO_MAJ_URL"].flatMap(URL.init(string:)) ?? api
    }

    nonisolated static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: source)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SyncError("réponse \(http.statusCode)")
        }
        return try parse(data)
    }

    private func offer(_ release: Release, current: Version) {
        let running = AppModel.shared.isBusy
        let alert = NSAlert()
        alert.messageText = "Synchro \(release.version) est disponible"
        var text = "Vous utilisez la version \(current)."
        let notes = Self.summary(of: release.notes)
        if !notes.isEmpty { text += "\n\n" + notes }
        if running { text += "\n\nUne synchronisation est en cours : l'installation attendra qu'elle soit terminée." }
        alert.informativeText = text
        alert.addButton(withTitle: "Installer et relancer").isEnabled = !running
        alert.addButton(withTitle: "Plus tard")
        alert.addButton(withTitle: "Voir sur GitHub")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(release.page)
        default: break
        }
    }

    // MARK: - Installation

    private func install(_ release: Release) {
        let app = Bundle.main.bundleURL
        guard Self.canReplace(app) else {
            Self.alert("Installation automatique impossible",
                       "Synchro ne peut pas se remplacer elle-même à cet emplacement :\n\(app.path)\n\nTéléchargez l'image disque, puis glissez Synchro dans le dossier Applications.",
                       action: ("Télécharger", release.download))
            return
        }
        guard !AppModel.shared.isBusy else { return }
        let panel = ProgressPanel("Téléchargement de Synchro \(release.version)…")
        busy = true
        Task {
            defer { busy = false; panel.close() }
            do {
                let dmg = try await Self.download(release.download)
                panel.text = "Installation de Synchro \(release.version)…"
                let team = Self.ownTeamID()
                try await Task.detached { try Self.replace(app: app, with: dmg, team: team) }.value
                relaunch(app)
            } catch {
                Self.alert("La mise à jour n'a pas pu être installée",
                           "\(error.localizedDescription)\n\nSynchro n'a pas été modifiée. Vous pouvez télécharger l'image disque et l'installer vous-même.",
                           action: ("Télécharger", release.download))
            }
        }
    }

    /// L'app peut-elle se remplacer elle-même ? Pas depuis une image disque, ni depuis une copie que macOS a
    /// déplacée dans un dossier à usage unique, ni sans droit d'écriture sur son dossier.
    nonisolated static func canReplace(_ app: URL) -> Bool {
        guard app.pathExtension == "app", !app.path.contains("/AppTranslocation/") else { return false }
        if (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return false }
        return FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    nonisolated static func download(_ url: URL) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SyncError("téléchargement refusé (réponse \(http.statusCode))")
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("synchro-maj-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dmg = dir.appendingPathComponent("Synchro.dmg")
        try fm.moveItem(at: temp, to: dmg)
        return dmg
    }

    /// Identifiant de l'équipe Apple qui a signé l'app en cours ; absent pour une signature ad hoc.
    nonisolated static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// La nouvelle app doit être signée par Apple Developer ID, sous l'identifiant de Synchro et, si l'app en
    /// cours l'est aussi, par la même équipe : rien d'autre ne sera installé à sa place.
    nonisolated static func verify(app: URL, team: String?) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw SyncError("la nouvelle version n'est pas signée")
        }
        var text = "anchor apple generic and identifier \"\(bundleID)\""
        if let team { text += " and certificate leaf[subject.OU] = \"\(team)\"" }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw SyncError("exigence de signature invalide")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidityWithErrors(staticCode, flags, requirement, nil)
        guard status == errSecSuccess else {
            throw SyncError("la signature de la nouvelle version n'est pas celle de Synchro (code \(status)) : rien n'a été installé")
        }
    }

    /// Monte l'image disque, contrôle l'app qu'elle contient, la copie à côté de l'ancienne puis l'échange avec
    /// elle en deux renommages : à tout moment, une version complète est en place.
    nonisolated static func replace(app: URL, with dmg: URL, team: String?) throws {
        let fm = FileManager.default
        let dir = dmg.deletingLastPathComponent()
        let mount = dir.appendingPathComponent("image")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer {
            try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? fm.removeItem(at: dir)
        }
        guard let fresh = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw SyncError("l'image disque ne contient pas d'application")
        }
        try verify(app: fresh, team: team)

        let parent = app.deletingLastPathComponent()
        let stamp = String(UUID().uuidString.prefix(8))
        let staged = parent.appendingPathComponent(".\(app.lastPathComponent).\(stamp)-nouveau")
        let old = parent.appendingPathComponent(".\(app.lastPathComponent).\(stamp)-ancien")
        try fm.copyItem(at: fresh, to: staged)
        do {
            try verify(app: staged, team: team)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        // L'app vérifiée n'a plus à passer par l'avertissement « téléchargée depuis Internet ».
        removexattr(staged.path, "com.apple.quarantine", XATTR_NOFOLLOW)

        guard rename(app.path, old.path) == 0 else {
            let error = posixError()
            try? fm.removeItem(at: staged)
            throw error
        }
        guard rename(staged.path, app.path) == 0 else {
            let error = posixError()
            _ = rename(old.path, app.path)
            try? fm.removeItem(at: staged)
            throw error
        }
        try? fm.removeItem(at: old)
    }

    nonisolated static func posixError() -> SyncError {
        SyncError(String(cString: strerror(errno)))
    }

    nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        let output = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SyncError("\(URL(fileURLWithPath: tool).lastPathComponent) : \(message.isEmpty ? "code \(process.terminationStatus)" : message)")
        }
    }

    /// Quitte (avec les questions habituelles, modifications non enregistrées comprises) et rouvre l'app
    /// une fois le processus terminé. Si l'utilisateur renonce à quitter, rien ne se passe : la nouvelle
    /// version est déjà en place et servira au prochain lancement.
    private func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
            n=0
            while kill -0 \(pid) 2>/dev/null; do
                sleep 0.2
                n=$((n + 1))
                [ "$n" -gt 600 ] && exit 0
            done
            open "$0"
            """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, app.path]
        try? helper.run()
        NSApp.terminate(nil)
    }

    private static func alert(_ title: String, _ text: String, action: (title: String, url: URL)? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        if let action { alert.addButton(withTitle: action.title) }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn, let action { NSWorkspace.shared.open(action.url) }
    }
}

/// Petite fenêtre flottante « en cours… » pendant le téléchargement et l'installation.
@MainActor
final class ProgressPanel {
    private let window: NSWindow
    private let label = NSTextField(labelWithString: "")

    init(_ text: String) {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        label.stringValue = text
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 60), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.title = "Mise à jour"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    func close() { window.close() }
}
