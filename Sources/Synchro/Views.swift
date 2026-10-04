import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    private var pendingDeleteStorage = State<UUID?>(initialValue: nil)
    private var pendingDelete: UUID? {
        get { pendingDeleteStorage.wrappedValue }
        nonmutating set { pendingDeleteStorage.wrappedValue = newValue }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Tâches") {
                    ForEach(model.presets) { preset in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.name + (model.isDirty(preset.id) ? " •" : ""))
                                Text(preset.lastSync.map { "Synchro : " + $0.formatted(.relative(presentation: .named)) } ?? "Jamais synchronisée")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .padding(.vertical, 2)
                        .tag(preset.id)
                            .contextMenu {
                                Button("Dupliquer") { model.duplicate(preset.id) }
                                Button("Supprimer…", role: .destructive) { pendingDelete = preset.id }
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { model.addPreset() } label: { Label("Ajouter", systemImage: "plus") }
                    Spacer()
                    Button { pendingDelete = model.selection } label: { Image(systemName: "minus") }
                        .disabled(model.selection == nil)
                        .help("Supprimer la tâche")
                }
                .buttonStyle(.borderless)
                .padding(10)
            }
        } detail: {
            if let id = model.selection, let preset = binding(for: id) {
                PresetDetail(preset: preset)
            } else {
                ContentUnavailableView("Aucune tâche", systemImage: "arrow.triangle.2.circlepath",
                                       description: Text("Ajoutez une tâche pour commencer."))
            }
        }
        .alert("Supprimer la tâche « \(model.presets.first(where: { $0.id == pendingDelete })?.name ?? "") » ?",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Supprimer", role: .destructive) { if let id = pendingDelete { model.remove(id) } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("La tâche sera retirée de l'app. Aucun fichier n'est touché, ni sur la source ni sur la destination.")
        }
        .sheet(isPresented: Binding(get: { model.isPreview }, set: { if !$0 { model.cancelPreview() } })) {
            if let plan = model.plan { PreviewSheet(plan: plan) }
        }
    }

    private func binding(for id: UUID) -> Binding<Preset>? {
        guard let current = model.presets.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { model.drafts[id] ?? model.presets.first(where: { $0.id == id }) ?? current },
            set: { model.edit($0) })
    }
}

struct PresetDetail: View {
    @EnvironmentObject var model: AppModel
    @Binding var preset: Preset

    private var isActive: Bool { model.activePreset == preset.id }
    private var locked: Bool { model.isBusy && isActive }
    private var dirty: Bool { model.isDirty(preset.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Nom", text: $preset.name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                Spacer()
                if locked {
                    Button("Arrêter", role: .cancel) { model.stop() }
                } else {
                    Button { model.analyze(preset) } label: {
                        Label("Synchroniser", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || dirty || preset.source.isEmpty || preset.destination.isEmpty)
                    .help(dirty ? "Enregistrez ou annulez les modifications avant de synchroniser" : "")
                }
            }

            if dirty {
                HStack {
                    Label("Modifications non enregistrées", systemImage: "pencil.circle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Annuler les modifications") { model.revertDraft(preset.id) }
                    Button("Enregistrer") { model.saveDraft(preset.id) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s")
                }
                .padding(10)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Source").foregroundStyle(.secondary)
                    TextField("/Volumes/MonDisque — ou glissez un dossier ici", text: $preset.source)
                        .dropDestination(for: URL.self) { urls, _ in drop(urls, setSource) }
                    Button("Choisir…") { pick(setSource) }
                }
                GridRow {
                    Text("Destination").foregroundStyle(.secondary)
                    TextField("smb://serveur/partage/dossier — ou glissez un dossier ici", text: $preset.destination)
                        .dropDestination(for: URL.self) { urls, _ in drop(urls, setDestination) }
                    Button("Choisir…") { pick(setDestination) }
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(locked)

            if isActive { StatusView() }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Contenu de la source").font(.headline)
                    Text("Cliquez sur la flèche pour ignorer un élément").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Ignorer les fichiers cachés", isOn: $preset.ignoreHidden)
                        .toggleStyle(.checkbox)
                }
                SourceTree(preset: $preset)
                    .id(preset.source + "|\(preset.ignoreHidden)")
            }
            .disabled(locked)
        }
        .padding(20)
    }

    private func setSource(_ url: URL) {
        preset.source = Mounter.resolveDropped(url).path
    }

    /// Un dossier situé sur le NAS est enregistré en smb:// pour pouvoir remonter le partage automatiquement.
    private func setDestination(_ url: URL) {
        let folder = Mounter.resolveDropped(url)
        preset.destination = Mounter.smbAddress(forLocal: folder) ?? folder.path
    }

    private func drop(_ urls: [URL], _ apply: (URL) -> Void) -> Bool {
        guard !locked, let url = urls.first else { return false }
        apply(url)
        return true
    }

    private func pick(_ apply: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        panel.prompt = "Choisir"
        if panel.runModal() == .OK, let url = panel.url { apply(url) }
    }
}

struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StatusView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.phase {
        case .idle, .preview:
            EmptyView()
        case .scanning:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.scanStatus).foregroundStyle(.secondary).monospacedDigit()
            }
        case .running:
            let p = model.progress
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: p.fraction)
                HStack {
                    Text(p.current).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(p.fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    StatTile(label: "Durée", value: Fmt.duration(p.elapsed))
                    StatTile(label: "Restant", value: Fmt.duration(p.remaining))
                    StatTile(label: "Vitesse", value: Fmt.speed(p.speed))
                    StatTile(label: "Transféré", value: "\(Fmt.bytes(p.bytesDone)) / \(Fmt.bytes(p.bytesTotal))")
                }
                counters(copied: p.copied, deleted: p.deleted, unchanged: model.plan?.unchanged ?? 0)
            }
        case .done(let r):
            VStack(alignment: .leading, spacing: 8) {
                Label(r.cancelled ? "Synchronisation arrêtée" : (r.errors.isEmpty ? "Synchronisation terminée" : "Terminée avec \(r.errors.count) erreur(s)"),
                      systemImage: r.cancelled ? "stop.circle" : (r.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                    .foregroundStyle(r.cancelled ? Color.secondary : (r.errors.isEmpty ? Color.green : Color.orange))
                    .font(.headline)
                HStack(spacing: 8) {
                    StatTile(label: "Durée", value: Fmt.duration(r.progress.elapsed))
                    StatTile(label: "Vitesse moyenne", value: Fmt.speed(r.averageSpeed))
                    StatTile(label: "Transféré", value: Fmt.bytes(r.progress.bytesDone))
                }
                counters(copied: r.progress.copied, deleted: r.progress.deleted, unchanged: r.unchanged)
                if !r.errors.isEmpty {
                    ScrollView {
                        Text(r.errors.prefix(200).joined(separator: "\n"))
                            .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 80)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
        }
    }

    private func counters(copied: Int, deleted: Int, unchanged: Int) -> some View {
        HStack(spacing: 16) {
            Label("\(copied.formatted()) copiés", systemImage: "arrow.up").foregroundStyle(.green)
            Label("\(deleted.formatted()) effacés de la destination", systemImage: "trash").foregroundStyle(.red)
            Label("\(unchanged.formatted()) inchangés", systemImage: "equal").foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

struct PreviewSheet: View {
    @EnvironmentObject var model: AppModel
    let plan: SyncPlan
    private var tabStorage = State<Int>(initialValue: 0)
    private var tab: Int {
        get { tabStorage.wrappedValue }
        nonmutating set { tabStorage.wrappedValue = newValue }
    }

    private var blocked: Bool { plan.sourceFiles == 0 && !plan.deletes.isEmpty }
    private static let shown = 2000

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Aperçu de la synchronisation").font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                StatTile(label: "À copier", value: "\(plan.copies.count.formatted()) · \(Fmt.bytes(plan.bytesToCopy))")
                StatTile(label: "À effacer de la destination", value: "\(plan.filesToDelete.formatted()) · \(Fmt.bytes(plan.bytesToDelete))")
                StatTile(label: "Inchangés", value: plan.unchanged.formatted())
            }

            if plan.isEmpty {
                Label("Tout est déjà à jour.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
            } else {
                Picker("", selection: tabStorage.projectedValue) {
                    Text("À effacer (\(plan.deletes.count.formatted()))").tag(0)
                    Text("À copier (\(plan.copies.count.formatted()))").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden()

                List {
                    if tab == 0 {
                        ForEach(plan.deletes.prefix(Self.shown), id: \.rel) { e in
                            Label(e.rel, systemImage: e.isDir ? "folder" : "doc").foregroundStyle(.red)
                        }
                        more(plan.deletes.count)
                    } else {
                        ForEach(plan.copies.prefix(Self.shown), id: \.rel) { e in
                            HStack {
                                Label(e.rel, systemImage: "doc")
                                Spacer()
                                Text(Fmt.bytes(e.size)).foregroundStyle(.secondary)
                            }
                        }
                        more(plan.copies.count)
                    }
                }
                .font(.callout)
                .listStyle(.bordered)
            }

            if blocked {
                Label("La source ne contient aucun fichier : la suppression est bloquée par sécurité.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if !plan.deletes.isEmpty {
                Label("Les éléments à effacer seront supprimés définitivement de la destination.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if plan.skippedLinks > 0 {
                Text("\(plan.skippedLinks) lien(s) symbolique(s) ignoré(s).").font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(plan.isEmpty ? "Fermer" : "Annuler", role: .cancel) { model.cancelPreview() }
                    .keyboardShortcut(.cancelAction)
                if !plan.isEmpty {
                    Button(plan.deletes.isEmpty ? "Lancer la copie" : "Copier et effacer") { model.confirm() }
                        .buttonStyle(.borderedProminent)
                        .disabled(blocked)
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .onAppear { tab = plan.deletes.isEmpty ? 1 : 0 }
    }

    @ViewBuilder private func more(_ total: Int) -> some View {
        if total > Self.shown {
            Text("… et \((total - Self.shown).formatted()) autres").foregroundStyle(.secondary)
        }
    }
}

// Note : le SDK macOS 27 fait de @State une macro dont le plugin n'est livré qu'avec Xcode.
// Pour compiler avec les seuls Command Line Tools, le stockage State est déclaré à la main.

// MARK: - Arborescence de la source

struct TreeItem: Identifiable {
    let url: URL
    let rel: String
    let isDir: Bool
    var id: String { rel }
    var name: String { url.lastPathComponent }
}

struct SourceTree: View {
    @Binding var preset: Preset

    var body: some View {
        let path = (preset.source.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                TreeChildren(dir: URL(fileURLWithPath: path), rel: "", depth: 0, inherited: false, preset: $preset)
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

struct TreeChildren: View {
    let dir: URL
    let rel: String
    let depth: Int
    let inherited: Bool
    @Binding var preset: Preset

    private var itemsStorage = State<[TreeItem]?>(initialValue: nil)
    private var items: [TreeItem]? {
        get { itemsStorage.wrappedValue }
        nonmutating set { itemsStorage.wrappedValue = newValue }
    }
    private var hiddenCountStorage = State<Int>(initialValue: 0)
    private var hiddenCount: Int {
        get { hiddenCountStorage.wrappedValue }
        nonmutating set { hiddenCountStorage.wrappedValue = newValue }
    }
    private static let limit = 300

    var body: some View {
        Group {
            if let items {
                if items.isEmpty && depth == 0 {
                    Text("Source vide ou introuvable").foregroundStyle(.secondary).padding(10)
                }
                ForEach(items) { item in
                    TreeRow(item: item, depth: depth, inherited: inherited, preset: $preset)
                }
                if hiddenCount > 0 {
                    Text("… et \(hiddenCount.formatted()) autres éléments")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, CGFloat(depth) * 18 + 34).padding(.vertical, 3)
                }
            } else {
                ProgressView().controlSize(.small).padding(.leading, CGFloat(depth) * 18 + 34).padding(.vertical, 3)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard items == nil else { return }
        let dir = dir, rel = rel, ignoreHidden = preset.ignoreHidden
        let all: [TreeItem] = await Task.detached {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [])) ?? []
            return urls.compactMap { url -> TreeItem? in
                let v = try? url.resourceValues(forKeys: Set(keys))
                let name = url.lastPathComponent
                if Scanner.isIgnoredName(name, hidden: v?.isHidden == true, ignoreHidden: ignoreHidden) { return nil }
                return TreeItem(url: url, rel: Scanner.key(rel.isEmpty ? name : rel + "/" + name), isDir: v?.isDirectory == true)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
        hiddenCount = max(0, all.count - Self.limit)
        items = Array(all.prefix(Self.limit))
    }
}

struct TreeRow: View {
    let item: TreeItem
    let depth: Int
    let inherited: Bool
    @Binding var preset: Preset
    private var expandedStorage = State<Bool>(initialValue: false)
    private var expanded: Bool {
        get { expandedStorage.wrappedValue }
        nonmutating set { expandedStorage.wrappedValue = newValue }
    }
    private var hoveringStorage = State<Bool>(initialValue: false)
    private var hovering: Bool {
        get { hoveringStorage.wrappedValue }
        nonmutating set { hoveringStorage.wrappedValue = newValue }
    }

    private var excluded: Bool { preset.excludes.contains(item.rel) }
    private var ignored: Bool { inherited || excluded }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold)).frame(width: 12)
                }
                .buttonStyle(.plain)
                .opacity(item.isDir ? 1 : 0)
                .disabled(!item.isDir)

                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable().frame(width: 16, height: 16)
                Text(item.name).lineLimit(1).truncationMode(.middle).strikethrough(ignored)
                Spacer()
                Button(action: toggle) {
                    Image(systemName: ignored ? "xmark" : "arrow.right")
                        .fontWeight(.semibold)
                        .foregroundStyle(ignored ? Color.secondary : Color.accentColor)
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(inherited)
                .help(inherited ? "Ignoré par un dossier parent" : (excluded ? "Ignoré — cliquer pour synchroniser" : "Synchronisé — cliquer pour ignorer"))
            }
            .opacity(ignored ? 0.5 : 1)
            .padding(.leading, CGFloat(depth) * 18 + 8)
            .padding(.trailing, 10)
            .padding(.vertical, 3)
            .background(hovering ? Color.primary.opacity(0.05) : .clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }

            if expanded {
                AnyView(TreeChildren(dir: item.url, rel: item.rel, depth: depth + 1, inherited: ignored, preset: $preset))
            }
        }
    }

    private func toggle() {
        if let i = preset.excludes.firstIndex(of: item.rel) {
            preset.excludes.remove(at: i)
        } else {
            preset.excludes.append(item.rel)
        }
    }
}
