import AppKit
import SwiftUI
import SynchroCore

/// État local d'une vue. Tient lieu de @State : avec le SDK macOS 27, @State est une macro dont le module
/// n'est livré qu'avec Xcode, alors que ce projet se compile avec les seuls Command Line Tools.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private var storage: State<Value>

    init(wrappedValue: Value) { storage = State(initialValue: wrappedValue) }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}

// MARK: - Fenêtre principale

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Local private var pendingDelete: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section("Tâches") {
                    ForEach(model.presets) { preset in
                        TaskRow(preset: preset)
                            .tag(preset.id)
                            .contextMenu {
                                Button("Dupliquer") { model.duplicate(preset.id) }
                                Button("Supprimer…", role: .destructive) { pendingDelete = preset.id }
                                    .disabled(model.isActive(preset.id))
                            }
                    }
                }
            }
            .onDeleteCommand { askDelete(model.selection) }
            .navigationSplitViewColumnWidth(min: 240, ideal: 260)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { model.addPreset() } label: { Label("Ajouter", systemImage: "plus") }
                    Spacer()
                    Button { askDelete(model.selection) } label: {
                        Label("Supprimer la tâche", systemImage: "minus").labelStyle(.iconOnly)
                    }
                    .disabled(model.selection.map(model.isActive) ?? true)
                    .help(model.selection.map(model.isActive) == true ? "Arrêtez d'abord la synchronisation" : "Supprimer la tâche")
                }
                .buttonStyle(.borderless)
                .padding(10)
            }
        } detail: {
            Group {
                if let id = model.selection, let preset = binding(for: id) {
                    PresetDetail(preset: preset)
                } else if model.presets.isEmpty {
                    ContentUnavailableView {
                        Label("Aucune tâche", systemImage: "arrow.triangle.2.circlepath")
                    } description: {
                        Text("Une tâche relie un dossier source à sa sauvegarde.")
                    } actions: {
                        Button("Ajouter une tâche") { model.addPreset() }
                    }
                } else {
                    ContentUnavailableView("Sélectionnez une tâche", systemImage: "sidebar.left",
                                           description: Text("Choisissez une tâche dans la liste de gauche."))
                }
            }
            // Le titre que macOS place dans la barre d'outils est décalé par rapport au contenu : on cache
            // le sien et on pose le nôtre, aligné sur la marge du détail (voir PresetDetail.margin).
            .background(WindowTitleHider())
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Text("Synchro").font(.headline).padding(.leading, PresetDetail.margin - 5)
                }
            }
        }
        .onAppear { model.reopenWindow = { openWindow(id: "main") } }
        .alert("Supprimer la tâche « \(model.presets.first(where: { $0.id == pendingDelete })?.name ?? "") » ?",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Supprimer", role: .destructive) { if let id = pendingDelete { model.remove(id) } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("La tâche sera retirée de l'app. Aucun fichier n'est touché, ni sur la source ni sur la destination.")
        }
        .alert("Tâches",
               isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.notice ?? "")
        }
        .alert("Problème avec les tâches enregistrées",
               isPresented: Binding(get: { model.storeAlert != nil }, set: { if !$0 { model.storeAlert = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.storeAlert ?? "")
        }
        .sheet(isPresented: Binding(get: { model.isPreview }, set: { if !$0 { model.cancelPreview() } })) {
            if let plan = model.plan { PreviewSheet(plan: plan, context: model.context) }
        }
    }

    /// La liste garde toujours une tâche sélectionnée : cliquer dans le vide ne fait pas disparaître le détail.
    private var selection: Binding<UUID?> {
        Binding(get: { model.selection },
                set: { if $0 != nil || model.presets.isEmpty { model.selection = $0 } })
    }

    private func askDelete(_ id: UUID?) {
        guard let id, !model.isActive(id) else { return }
        pendingDelete = id
    }

    private func binding(for id: UUID) -> Binding<Preset>? {
        guard let current = model.presets.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { model.drafts[id] ?? model.presets.first(where: { $0.id == id }) ?? current },
            set: { model.edit($0) })
    }
}

/// Masque le titre que la fenêtre affiche elle-même (la fenêtre garde son nom dans le menu Fenêtre et le Dock).
struct WindowTitleHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.titleVisibility = .hidden }
    }
}

struct TaskRow: View {
    @EnvironmentObject var model: AppModel
    let preset: Preset

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name + (model.isDirty(preset.id) ? " •" : ""))
                Text(caption).font(.caption).foregroundStyle(.secondary)
                if let issue = preset.lastIssue, !model.isActive(preset.id) {
                    // Une tentative ratée doit rester visible, même quand une autre tâche est affichée.
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).labelStyle(.titleAndIcon)
                }
            }
        } icon: {
            if model.isActive(preset.id) {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
        }
        .padding(.vertical, 2)
    }

    private var caption: String {
        if model.isActive(preset.id) {
            switch model.phase {
            case .scanning: return "Analyse en cours…"
            case .preview: return "Confirmation requise"
            default: return "Synchronisation en cours…"
            }
        }
        // Date absolue : un « il y a 2 minutes » resterait affiché tel quel des jours plus tard.
        return preset.lastSync.map { "Dernière synchro : " + Fmt.dateTime($0) } ?? "Jamais synchronisée"
    }
}

// MARK: - Détail d'une tâche

struct PresetDetail: View {
    @EnvironmentObject var model: AppModel
    @Binding var preset: Preset
    /// Marge du contenu, sur laquelle le titre de la fenêtre est aligné.
    static let margin: CGFloat = 20

    private var isActive: Bool { model.activePreset == preset.id }
    private var locked: Bool { model.isActive(preset.id) }
    private var dirty: Bool { model.isDirty(preset.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                TextField("Nom de la tâche", text: $preset.name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .disabled(locked)
                Spacer()
                if locked {
                    Button(model.stopping ? "Arrêt en cours…" : "Arrêter", role: .cancel) { model.stop() }
                        .disabled(model.stopping || model.isPreview)
                } else {
                    Menu {
                        Button("Synchroniser en comparant tout le contenu (lent)…") { model.analyze(preset, verifyAll: true) }
                    } label: {
                        Label("Synchroniser…", systemImage: "arrow.triangle.2.circlepath")
                    } primaryAction: {
                        model.analyze(preset)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .disabled(model.isBusy || dirty || preset.source.isEmpty || preset.destination.isEmpty)
                    .help(startHelp)
                }
            }

            VStack(spacing: 8) {
                PathRow(label: "Source", text: $preset.source, kind: .source, apply: setSource)
                PathRow(label: "Destination", text: $preset.destination, kind: .destination, apply: setDestination)
                HStack(spacing: 10) {
                    Text("Ignorés").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                    Picker("Éléments ignorés déjà présents sur la destination", selection: $preset.mirrorIgnored) {
                        Text("Copie").tag(false)
                        Text("Image").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Copie : un élément ignoré déjà présent sur la destination y reste. Image : il en est effacé, dossier compris.")
                    Text(preset.mirrorIgnored
                         ? "Déjà sur la destination : effacé, dossier compris."
                         : "Déjà sur la destination : laissé tel quel.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Toggle("Ignorer les fichiers cachés", isOn: $preset.ignoreHidden)
                        .toggleStyle(.checkbox)
                }
            }
            .disabled(locked)

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

            if isActive { StatusView() }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Button { model.treeCollapsed.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: model.treeCollapsed ? "chevron.right" : "chevron.down")
                                .font(.caption.weight(.semibold)).frame(width: 12)
                            Text("Contenu de la source").font(.headline)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.treeCollapsed ? "Afficher le contenu de la source" : "Replier le contenu de la source")
                    IgnoredList(preset: $preset)
                    Spacer()
                    Menu {
                        let n = model.treeSelection.count
                        Button("Ignorer la sélection (\(n))") { Batch.ignore(Array(model.treeSelection), in: $preset) }
                            .disabled(n == 0)
                        Button("Synchroniser la sélection (\(n))") { Batch.allow(Array(model.treeSelection), in: $preset) }
                            .disabled(n == 0)
                        Button("Ignorer tout sauf la sélection") {
                            Batch.ignoreAll(in: URL(fileURLWithPath: preset.sourcePath), rel: "", except: model.treeSelection, preset: $preset)
                        }
                        .disabled(n == 0)
                        Divider()
                        Button("Tout ignorer (premier niveau)") {
                            Batch.ignoreAll(in: URL(fileURLWithPath: preset.sourcePath), rel: "", except: [], preset: $preset)
                        }
                        Button("Ne plus rien ignorer") { preset.excludes = [] }.disabled(preset.excludes.isEmpty)
                    } label: {
                        Label("Par lot", systemImage: "checklist")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Sélectionnez des lignes avec ⌘ (ou ⇧ pour une plage), puis ignorez ou synchronisez d'un coup. Clic droit sur une ligne : mêmes actions.")
                    Menu {
                        Section("Afficher dans la liste") {
                            Toggle("● Identiques sur la destination", isOn: $model.listFilter.same)
                            Toggle("● Différents", isOn: $model.listFilter.different)
                            Toggle("● Absents de la destination", isOn: $model.listFilter.missing)
                            Toggle("✕ Ignorés", isOn: $model.listFilter.ignored)
                        }
                        Divider()
                        Button("Tout afficher") { model.listFilter = ListFilter() }.disabled(model.listFilter.isDefault)
                    } label: {
                        Label("Afficher", systemImage: model.listFilter.isDefault ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Choisir ce que la liste montre : identiques, différents, absents, ignorés. Les éléments sans pastille restent affichés.")
                    Button { model.treeToken += 1 } label: {
                        Label("Actualiser la liste", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Relire le contenu de la source")
                }
                if !model.treeCollapsed {
                    SourceTree(preset: $preset)
                        .id(preset.source + "|\(preset.ignoreHidden)")
                    (Text("→ synchronisé · ")
                     + Text("→ jaune : synchronisé, sauf des éléments ignorés à l'intérieur").foregroundColor(TreeRow.partialColor)
                     + Text(" · ✕ ignoré. Cliquez sur le symbole pour changer. Un élément ignoré n'est jamais copié ; ")
                     + Text(preset.mirrorIgnored
                            ? "mode Image : s'il se trouve sur la destination, il en est effacé, dossier compris."
                            : "mode Copie : s'il se trouve sur la destination, il y reste tel quel.")
                     + Text(" Pastille : ") + Text("● identique").foregroundColor(.green) + Text(" · ")
                     + Text("● différent").foregroundColor(.orange) + Text(" · ")
                     + Text("● absent").foregroundColor(.red) + Text(" sur la destination."))
                        .font(.caption).foregroundStyle(.secondary)
                        // Trois lignes au plus, servies avant la liste. Surtout pas de fixedSize ici : la hauteur
                        // minimale de la fenêtre se calculerait sur un texte replié à l'extrême, et tout déborderait.
                        .lineLimit(3)
                        .layoutPriority(1)
                }
            }
            .disabled(locked)

            if model.treeCollapsed { Spacer(minLength: 0) }
        }
        .padding(Self.margin)
    }

    private var startHelp: String {
        if dirty { return "Enregistrez ou annulez les modifications avant de synchroniser" }
        if model.isBusy { return "Une autre tâche est en cours : \(model.activeName)" }
        return "Analyse la source et la destination, puis affiche un aperçu avant de modifier quoi que ce soit"
    }

    private func setSource(_ url: URL) {
        preset.source = Mounter.resolveDropped(url).path
    }

    /// Un dossier situé sur le NAS est enregistré en smb:// pour pouvoir remonter le partage automatiquement.
    private func setDestination(_ url: URL) {
        let folder = Mounter.resolveDropped(url)
        preset.destination = Mounter.smbAddress(forLocal: folder) ?? folder.path
    }
}

/// Ligne Source ou Destination : un cadre non éditable qui reçoit les dossiers glissés, un bouton pour choisir,
/// et la saisie d'une adresse dans une fenêtre à part. Un champ de texte éditable intercepterait les dépôts
/// et insérerait le chemin au milieu du texte existant.
struct PathRow: View {
    enum Kind { case source, destination }

    @EnvironmentObject var model: AppModel
    let label: String
    @Binding var text: String
    let kind: Kind
    let apply: (URL) -> Void

    @Local private var targeted = false
    @Local private var editing = false
    @Local private var typed = ""

    private var trimmed: String { text.trimmingCharacters(in: .whitespaces) }
    private var path: String { (trimmed as NSString).expandingTildeInPath }
    private var isSMB: Bool { Mounter.isSMB(trimmed) }

    var body: some View {
        HStack(spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            HStack(spacing: 8) {
                Image(systemName: isSMB ? "externaldrive.connected.to.line.below" : "folder")
                    .foregroundStyle(.secondary)
                if trimmed.isEmpty {
                    Text("Glissez un dossier ici, ou cliquez sur Choisir…").foregroundStyle(.tertiary)
                } else {
                    Text(trimmed).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if let note {
                    Text(note.text).font(.caption).foregroundStyle(note.warning ? Color.orange : Color.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(targeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: targeted ? 2 : 1))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label) : \(trimmed.isEmpty ? "non définie" : trimmed)")

            Button("Choisir…") { pick() }
            Button {
                typed = text
                editing = true
            } label: {
                Label("Saisir l'adresse", systemImage: "pencil").labelStyle(.iconOnly)
            }
            .help(kind == .source ? "Saisir le chemin de la source" : "Saisir une adresse, par exemple smb://serveur/partage/dossier")
            .popover(isPresented: $editing, arrowEdge: .bottom) { editor }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            apply(url)
            return true
        } isTargeted: { targeted = $0 }
    }

    /// Indication d'état à droite du chemin. `model.treeToken` change quand un disque est branché ou retiré.
    private var note: (text: String, warning: Bool)? {
        _ = model.treeToken
        guard !trimmed.isEmpty, !isSMB else { return nil }
        guard path.hasPrefix("/") else { return ("Chemin incomplet", true) }
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return nil }
        // Un dossier de destination absent sera créé, mais seulement si son dossier parent existe.
        let parent = (path as NSString).deletingLastPathComponent
        // « /Volumes/Nom » absent : c'est un disque qui n'est pas branché, pas un dossier à créer.
        if kind == .destination, parent != "/Volumes", fm.fileExists(atPath: parent) { return ("Sera créé", false) }
        return ("Introuvable — disque débranché ?", true)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(kind == .source ? "Chemin du dossier source" : "Adresse de la destination").font(.headline)
            TextField(kind == .source ? "/Volumes/MonDisque" : "smb://serveur/partage/dossier", text: $typed)
                .textFieldStyle(.roundedBorder)
                .frame(width: 400)
                .onSubmit(commit)
            Text(kind == .source
                 ? "Un dossier de ce Mac ou d'un disque branché."
                 : "Un dossier, ou l'adresse d'un partage réseau : smb://serveur/partage/dossier. Le partage sera connecté au besoin.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { editing = false }.keyboardShortcut(.cancelAction)
                Button("OK", action: commit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 428)
    }

    private func commit() {
        text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        panel.prompt = "Choisir"
        if panel.runModal() == .OK, let url = panel.url { apply(url) }
    }
}

/// Liste des éléments ignorés, pour les revoir et les retirer sans dépendre de l'arborescence
/// (un élément renommé ou absent de la source n'y apparaît plus).
struct IgnoredList: View {
    @Binding var preset: Preset
    @Local private var shown = false

    var body: some View {
        Button(preset.excludes.isEmpty ? "Aucun élément ignoré" : Fmt.count(preset.excludes.count, "élément ignoré", "éléments ignorés")) {
            shown = true
        }
        .buttonStyle(.link)
        .font(.caption)
        .disabled(preset.excludes.isEmpty)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Éléments ignorés").font(.headline)
                Text("Ni copiés, ni effacés de la destination.").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(preset.excludes.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { rel in
                            let present = FileManager.default.fileExists(atPath: preset.sourcePath + "/" + rel)
                            HStack(spacing: 8) {
                                Image(systemName: "xmark").foregroundStyle(.secondary).font(.caption)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(rel).lineLimit(1).truncationMode(.middle)
                                    if !present {
                                        Text("Absent de la source").font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                Button("Ne plus ignorer") { preset.excludes.removeAll { $0 == rel } }
                                    .buttonStyle(.link).font(.caption)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            .padding(14)
            .frame(width: 460)
        }
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(tint ?? Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - État d'une analyse ou d'une synchronisation

struct StatusView: View {
    @EnvironmentObject var model: AppModel
    /// Tuile de vitesse : moyenne depuis le début, ou débit instantané ; un clic bascule, le choix est mémorisé.
    @Local private var instantSpeed = UserDefaults.standard.bool(forKey: "vitesseInstantanee")

    var body: some View {
        switch model.phase {
        case .idle, .preview:
            EmptyView()
        case .scanning:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.stopping ? "Arrêt en cours…" : model.scanStatus).foregroundStyle(.secondary).monospacedDigit()
            }
        case .running:
            running(model.progress)
        case .done(let outcome):
            DoneView(outcome: outcome)
        case .failed(let message):
            HStack(alignment: .top) {
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
                Spacer()
                CloseButton()
            }
        }
    }

    private func running(_ p: SyncProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.stopping ? "Arrêt en cours…" : step(p)).font(.callout.weight(.medium))
                Spacer()
                Text(p.fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: p.fraction)
            Text(p.current.isEmpty ? " " : p.current)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 8) {
                // L'horloge avance seule : une longue suppression ne doit pas donner l'impression d'un blocage.
                TimelineView(.periodic(from: p.startedAt, by: 1)) { timeline in
                    StatTile(label: "Durée", value: Fmt.duration(max(0, timeline.date.timeIntervalSince(p.startedAt))))
                }
                if p.bytesTotal > 0 {
                    StatTile(label: "Restant", value: p.phase == .copying ? Fmt.duration(p.remaining) : "—")
                    Button {
                        instantSpeed.toggle()
                        UserDefaults.standard.set(instantSpeed, forKey: "vitesseInstantanee")
                    } label: {
                        StatTile(label: instantSpeed ? "Vitesse instantanée ⇄" : "Vitesse moyenne ⇄",
                                 value: Fmt.speed(instantSpeed ? p.instantSpeed : p.speed))
                    }
                    .buttonStyle(.plain)
                    .help(instantSpeed ? "Débit des cinq dernières secondes. Cliquer pour la moyenne depuis le début de la copie."
                                       : "Moyenne depuis le début de la copie. Cliquer pour le débit instantané.")
                    StatTile(label: "Transféré", value: "\(Fmt.bytes(p.bytesDone)) / \(Fmt.bytes(p.bytesTotal))")
                }
            }
            Counters(copied: p.copied, deleted: p.deleted, unchanged: model.plan?.unchanged ?? 0, failed: p.failed)
        }
    }

    private func step(_ p: SyncProgress) -> String {
        switch p.phase {
        case .preparing: return "Préparation…"
        case .deleting: return "Suppression — \(p.deleteItemsDone.formatted()) / \(p.deleteItemsTotal.formatted())"
        case .folders: return "Création des dossiers…"
        case .copying: return "Copie"
        case .verifying: return "Vérification des dates…"
        case .finished: return "Finalisation…"
        }
    }
}

struct Counters: View {
    let copied: Int
    let deleted: Int
    let unchanged: Int
    let failed: Int

    var body: some View {
        HStack(spacing: 16) {
            Label(Fmt.count(copied, "copié", "copiés"), systemImage: "arrow.up").foregroundStyle(.green)
            Label(Fmt.count(deleted, "effacé de la destination", "effacés de la destination"), systemImage: "trash")
                .foregroundStyle(.red)
            Label(Fmt.count(unchanged, "inchangé", "inchangés"), systemImage: "equal").foregroundStyle(.secondary)
            if failed > 0 {
                Label(Fmt.count(failed, "en échec", "en échec"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        .font(.caption)
    }
}

struct CloseButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button { model.dismissResult() } label: {
            Label("Masquer ce résultat", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Masquer ce résultat")
    }
}

struct DoneView: View {
    let outcome: Outcome
    private static let shownErrors = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Label(headline.text, systemImage: headline.symbol).foregroundStyle(headline.color).font(.headline)
                Spacer()
                if let journal = outcome.journal {
                    Button("Afficher le journal") { NSWorkspace.shared.open(journal) }
                        .buttonStyle(.link)
                } else if outcome.result != nil {
                    Text("Journal non enregistré").font(.caption).foregroundStyle(.secondary)
                }
                CloseButton()
            }
            if let result = outcome.result {
                if let reason = result.abortReason {
                    Text(reason).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    StatTile(label: "Durée", value: Fmt.duration(result.progress.elapsed))
                    StatTile(label: "Vitesse moyenne", value: Fmt.speed(result.averageSpeed))
                    StatTile(label: "Transféré", value: Fmt.bytes(result.progress.bytesDone))
                }
                Counters(copied: result.progress.copied, deleted: result.progress.deleted,
                         unchanged: result.unchanged, failed: result.progress.failed)
                let errors = result.errors.filter { $0 != result.abortReason }
                if !errors.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(errors.prefix(Self.shownErrors).joined(separator: "\n"))
                                .foregroundStyle(.red).textSelection(.enabled)
                            if errors.count > Self.shownErrors {
                                Text("… et \(Fmt.count(errors.count - Self.shownErrors, "autre erreur", "autres erreurs")), dans le journal.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: min(80, CGFloat(min(errors.count, Self.shownErrors) + (errors.count > Self.shownErrors ? 1 : 0)) * 16 + 4))
                }
            } else if !outcome.sourceEmpty {
                Text("\(Fmt.count(outcome.unchanged, "fichier identique", "fichiers identiques")) sur la source et la destination.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var headline: (text: String, symbol: String, color: Color) {
        let time = Fmt.dateTime(outcome.finishedAt)
        guard let result = outcome.result else {
            if outcome.sourceEmpty {
                return ("Rien à synchroniser : la source ne contient aucun fichier", "info.circle", .secondary)
            }
            return ("Tout est à jour — vérifié le \(time)", "checkmark.circle.fill", .green)
        }
        if result.cancelled { return ("Synchronisation arrêtée le \(time)", "stop.circle", .secondary) }
        if result.abortReason != nil { return ("Synchronisation interrompue le \(time)", "xmark.octagon.fill", .red) }
        if result.errors.isEmpty { return ("Synchronisation terminée le \(time)", "checkmark.circle.fill", .green) }
        return ("Terminée le \(time) avec \(Fmt.count(result.errors.count, "erreur", "erreurs"))", "exclamationmark.triangle.fill", .orange)
    }
}

// MARK: - Aperçu avant exécution

struct PreviewSheet: View {
    @EnvironmentObject var model: AppModel
    let plan: SyncPlan
    let context: PreviewContext?
    @Local private var tab = 0
    @Local private var acknowledged = false

    private static let shown = 2000
    private var canRun: Bool { plan.blockedReason == nil && (plan.risks.isEmpty || acknowledged) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Aperçu — \(context?.taskName ?? "synchronisation")").font(.title2.weight(.semibold))

            if let context {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow {
                        Text("De").foregroundStyle(.secondary)
                        Text(context.source).lineLimit(1).truncationMode(.middle)
                    }
                    GridRow {
                        Text("Vers").foregroundStyle(.secondary)
                        Text(context.destination == context.resolvedDestination
                             ? context.resolvedDestination
                             : "\(context.resolvedDestination)  (\(context.destination))")
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.callout)
            }

            HStack(spacing: 8) {
                StatTile(label: "À copier", value: "\(plan.copies.count.formatted()) · \(Fmt.bytes(plan.bytesToCopy))")
                StatTile(label: "À effacer de la destination",
                         value: "\(plan.filesToDelete.formatted()) · \(Fmt.bytes(plan.bytesToDelete))",
                         tint: plan.filesToDelete > 0 ? .red : nil)
                StatTile(label: "Inchangés", value: plan.unchanged.formatted())
            }

            if plan.isEmpty {
                Label(plan.conflicts.isEmpty ? "Tout est déjà à jour." : "Rien à copier ni à effacer.",
                      systemImage: plan.conflicts.isEmpty ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(plan.conflicts.isEmpty ? Color.green : Color.secondary)
            } else {
                Picker("Liste affichée", selection: $tab) {
                    Text("À effacer (\(plan.deletes.count.formatted()))").tag(0)
                    Text("À copier (\(plan.copies.count.formatted()))").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden()

                // Lignes simples, sans sélection : un défilement paresseux suffit et évite la lourdeur d'une table.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if tab == 0 {
                            ForEach(plan.deletes.prefix(Self.shown)) { item in
                                row(item.rel, item.isDir ? "folder" : "doc", .red,
                                    item.isDir ? "\(Fmt.count(item.files, "fichier", "fichiers")) · \(Fmt.bytes(item.bytes))" : Fmt.bytes(item.bytes))
                            }
                            more(plan.deletes.count)
                        } else {
                            ForEach(plan.copies.prefix(Self.shown), id: \.rel) { entry in
                                row(entry.rel, "doc", .primary, Fmt.bytes(entry.size))
                            }
                            more(plan.copies.count)
                        }
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
                .overlay(Rectangle().strokeBorder(.separator))
            }

            notes

            if plan.isEmpty { Spacer(minLength: 0) }

            HStack {
                Spacer()
                Button(plan.isEmpty ? "Fermer" : "Annuler", role: .cancel) { model.cancelPreview() }
                    .keyboardShortcut(.cancelAction)
                if !plan.isEmpty {
                    // Jamais le bouton par défaut quand il y a des suppressions : la touche Retour ne doit rien effacer.
                    if plan.deletes.isEmpty {
                        Button(runTitle) { model.confirm(acknowledged: acknowledged) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canRun)
                    } else {
                        Button(runTitle) { model.confirm(acknowledged: acknowledged) }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(!canRun)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 700, height: 620)
        .onAppear { tab = plan.deletes.isEmpty ? 1 : 0 }
    }

    private var runTitle: String {
        var parts: [String] = []
        if !plan.deletes.isEmpty {
            parts.append(plan.filesToDelete == 0
                         ? "effacer \(Fmt.count(plan.deletes.count, "dossier vide", "dossiers vides"))"
                         : "effacer \(Fmt.count(plan.filesToDelete, "fichier", "fichiers"))")
        }
        if !plan.copies.isEmpty { parts.append("copier \(Fmt.count(plan.copies.count, "fichier", "fichiers"))") }
        if parts.isEmpty {
            if !plan.dirs.isEmpty { parts.append("créer \(Fmt.count(plan.dirs.count, "dossier", "dossiers"))") }
            if !plan.renames.isEmpty { parts.append("renommer \(Fmt.count(plan.renames.count, "élément", "éléments"))") }
        }
        guard let first = parts.first else { return "Nettoyer" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: " et ")
    }

    @ViewBuilder private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !plan.destinationExists {
                note("Le dossier de destination n'existe pas encore : il sera créé.", "folder.badge.plus", .secondary)
            }
            if context?.mirrorIgnored == true {
                note("Mode Image : les éléments ignorés qui se trouvent sur la destination sont effacés avec le reste.",
                     "xmark.bin", .secondary)
            }
            ForEach(plan.openCatalogs, id: \.self) { catalog in
                note("Le catalogue Lightroom « \((catalog as NSString).lastPathComponent) » semble ouvert. Quittez Lightroom puis relancez l'analyse pour que sa copie soit fiable.",
                     "exclamationmark.triangle.fill", .orange)
            }
            if let missing = plan.spaceShortfall, let free = plan.freeSpace {
                note("Espace insuffisant sur la destination : il manque environ \(Fmt.bytes(missing)) (libre : \(Fmt.bytes(free))). La copie s'arrêtera quand elle sera pleine.",
                     "exclamationmark.triangle.fill", .orange)
            }
            if plan.contentMismatches > 0 {
                note("\(Fmt.count(plan.contentMismatches, "fichier a", "fichiers ont")) la même taille et la même date sur la destination, mais un contenu différent : recopie prévue.",
                     "doc.on.doc", .secondary)
            } else if plan.verified > 0 {
                note("Le contenu de \(Fmt.count(plan.verified, "fichier ambigu a été comparé", "fichiers ambigus a été comparé")) : aucune différence.",
                     "doc.on.doc", .secondary)
            }
            if !plan.keptDirs.isEmpty {
                note(plan.keptDirs.count == 1
                     ? "Le dossier « \(plan.keptDirs[0]) », absent de la source, est conservé : il contient un élément ignoré."
                     : "\(plan.keptDirs.count.formatted()) dossiers absents de la source sont conservés, car ils contiennent un élément ignoré : \(sample(plan.keptDirs)).",
                     "lock", .secondary)
            }
            if !plan.conflicts.isEmpty {
                note("\(Fmt.count(plan.conflicts.count, "élément ne sera pas copié", "éléments ne seront pas copiés")) : "
                     + plan.conflicts.prefix(3).map { "« \($0.rel) » (\($0.reason))" }.joined(separator: " ; ")
                     + (plan.conflicts.count > 3 ? "…" : "."),
                     "exclamationmark.triangle.fill", .orange)
            }
            if !plan.renames.isEmpty {
                note((plan.renames.count == 1
                      ? "1 élément sera renommé sur la destination, seules les majuscules de son nom ont changé : "
                      : "\(plan.renames.count.formatted()) éléments seront renommés sur la destination, seules les majuscules de leur nom ont changé : ")
                     + plan.renames.prefix(3).map { "« \($0.from) » → « \(($0.to as NSString).lastPathComponent) »" }.joined(separator: ", ")
                     + (plan.renames.count > 3 ? "…" : "."),
                     "character.cursor.ibeam", .secondary)
            }
            if !plan.temps.isEmpty {
                note("\(Fmt.count(plan.temps.count, "reste de copie interrompue sera nettoyé", "restes de copies interrompues seront nettoyés")).",
                     "wand.and.stars", .secondary)
            }
            if plan.skippedLinks > 0 {
                note(Fmt.count(plan.skippedLinks, "lien symbolique n'est pas copié.", "liens symboliques ne sont pas copiés."), "link", .secondary)
            }
            if let blocked = plan.blockedReason {
                note(blocked, "hand.raised.fill", .red)
            } else if !plan.risks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(plan.risks, id: \.self) { risk in
                        note(risk, "exclamationmark.octagon.fill", .red)
                    }
                    Toggle(plan.filesToDelete > 0
                           ? "Je confirme l'effacement définitif de \(Fmt.count(plan.filesToDelete, "fichier", "fichiers")) (\(Fmt.bytes(plan.bytesToDelete)))"
                           : "J'ai vérifié la destination : lancer quand même",
                           isOn: $acknowledged)
                        .toggleStyle(.checkbox)
                }
                .padding(10)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else if !plan.deletes.isEmpty {
                note("Les éléments à effacer seront supprimés définitivement de la destination.", "trash", .secondary)
            }
        }
        .font(.callout)
    }

    private func row(_ text: String, _ symbol: String, _ color: Color, _ detail: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label(text, systemImage: symbol).foregroundStyle(color).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(detail).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            Divider()
        }
    }

    private func note(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sample(_ items: [String]) -> String {
        items.prefix(3).joined(separator: ", ") + (items.count > 3 ? "…" : "")
    }

    @ViewBuilder private func more(_ total: Int) -> some View {
        if total > Self.shown {
            Text("… et \((total - Self.shown).formatted()) autres. La liste complète figurera dans le journal de la synchronisation.")
                .foregroundStyle(.secondary).padding(8)
        }
    }
}

// MARK: - Arborescence de la source

struct TreeItem: Identifiable, Sendable {
    /// Dossier qui le contient (le même objet pour tous les éléments d'un dossier) et nom : garder une URL par élément
    /// coûte une dizaine de Ko chacune, soit plus d'un demi-gigaoctet pour un dossier de 50 000 fichiers.
    let dir: URL
    let name: String
    let rel: String
    let isDir: Bool
    var size: Int64 = 0
    var mtime = Date.distantPast
    var id: String { rel }
    var url: URL { dir.appendingPathComponent(name, isDirectory: isDir) }
}

enum TreeListing: Sendable {
    case loading
    case items([TreeItem])
    case missing
    case denied
}

/// Icônes par type de fichier, mises en cache : les demander au système pour chaque ligne à chaque affichage coûte cher.
@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: TreeItem) -> NSImage {
        let key = (item.isDir ? "dossier." : "fichier.") + (item.name as NSString).pathExtension.lowercased()
        if let hit = cache[key] { return hit }
        let image = NSWorkspace.shared.icon(forFile: item.url.path)
        cache[key] = image
        return image
    }
}

/// État de la liste de la source : dossiers dépliés et contenu lu de chacun. La liste est plate et paresseuse :
/// seules les lignes visibles à l'écran sont construites, même pour un dossier de dizaines de milliers de fichiers
/// (construire d'un coup toutes les lignes d'un dossier déplié faisait planter l'app vers 40 000 éléments).
struct TreeState {
    /// Dossiers dépliés : chemin relatif → dossier.
    var expanded: [String: URL] = [:]
    /// Contenu lu de la racine ("") et de chaque dossier déplié.
    var listings: [String: TreeListing] = [:]
    /// Change à chaque relecture complète : le résultat d'une lecture lancée avant est ignoré.
    var generation = 0
}

/// Une ligne de la liste plate : un élément, ou une indication (chargement, dossier vide, filtre…).
struct TreeLine: Identifiable {
    enum Kind {
        case item(TreeItem, inherited: Bool, siblings: [String])
        case loading
        case note(String)
    }
    let id: String
    let depth: Int
    let kind: Kind
}

struct SourceTree: View {
    @EnvironmentObject var model: AppModel
    @Binding var preset: Preset
    @Local private var tree = TreeState()

    private var root: URL { URL(fileURLWithPath: preset.sourcePath) }

    var body: some View {
        let path = preset.sourcePath
        Group {
            if path.isEmpty {
                message("Choisissez d'abord un dossier source : bouton « Choisir… », ou glissez un dossier sur la ligne Source.")
            } else if !path.hasPrefix("/") {
                message("Le chemin de la source est incomplet.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines()) { line in
                            switch line.kind {
                            case .item(let item, let inherited, let siblings):
                                TreeRow(item: item, depth: line.depth, inherited: inherited, siblings: siblings,
                                        preset: $preset, expanded: tree.expanded[item.rel] != nil) { toggle(item) }
                            case .loading:
                                ProgressView().controlSize(.small).padding(.leading, Self.indent(line.depth)).padding(.vertical, 3)
                            case .note(let text):
                                note(text, depth: line.depth)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .overlay(alignment: .topLeading) { if model.demoMenu { DemoMenu().offset(x: 180, y: 100) } }
                .task(id: model.treeToken) { reload() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    private static func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * 18 + 34 }

    private func message(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).padding(12)
    }

    private func note(_ text: String, depth: Int) -> some View {
        Text(text).font(depth == 0 ? .body : .caption).foregroundStyle(.secondary)
            .padding(.leading, depth == 0 ? 12 : Self.indent(depth)).padding(.vertical, depth == 0 ? 10 : 3)
    }

    /// Aplatit l'arborescence : chaque dossier déplié insère ses enfants, filtrés, sous sa propre ligne.
    private func lines() -> [TreeLine] {
        var out: [TreeLine] = []
        let ignoredKeys = Set(preset.excludes.map(Scanner.excludeKey))
        let filter = model.listFilter, statuses = model.destinationStatus
        func note(_ text: String, _ tag: String, _ rel: String, _ depth: Int) {
            out.append(TreeLine(id: "/\(tag)/" + rel, depth: depth, kind: .note(text)))
        }
        func append(rel: String, depth: Int, inherited: Bool) {
            switch tree.listings[rel] ?? .loading {
            case .loading:
                out.append(TreeLine(id: "/chargement/" + rel, depth: depth, kind: .loading))
            case .missing:
                if depth == 0 {
                    note("Disque ou dossier introuvable. Branchez le disque : la liste se mettra à jour toute seule.", "introuvable", rel, depth)
                }
            case .denied:
                note("Accès refusé par macOS. Autorisez Synchro dans Réglages Système → Confidentialité et sécurité → Fichiers et dossiers.",
                     "refus", rel, depth)
            case .items(let all):
                if all.isEmpty && depth == 0 { note("Ce dossier est vide.", "vide", rel, depth) }
                var shown: [(TreeItem, Bool)] = []
                shown.reserveCapacity(all.count)
                for item in all {
                    let ignored = inherited || ignoredKeys.contains(Scanner.excludeKey(item.rel))
                    if filter.shows(ignored: ignored, status: statuses[item.rel]) { shown.append((item, ignored)) }
                }
                let siblings = shown.map(\.0.rel)
                for (item, ignored) in shown {
                    out.append(TreeLine(id: item.rel, depth: depth, kind: .item(item, inherited: inherited, siblings: siblings)))
                    if item.isDir, tree.expanded[item.rel] != nil { append(rel: item.rel, depth: depth + 1, inherited: ignored) }
                }
                if shown.count < all.count {
                    note("\(Fmt.count(all.count - shown.count, "élément masqué par le filtre", "éléments masqués par le filtre")) (bouton Afficher).",
                         "filtre", rel, depth)
                }
            }
        }
        append(rel: "", depth: 0, inherited: false)
        return out
    }

    /// Déplie ou replie un dossier. Replier oublie son contenu et ses sous-dossiers dépliés : la prochaine ouverture le relit.
    private func toggle(_ item: TreeItem) {
        if tree.expanded.removeValue(forKey: item.rel) != nil {
            let prefix = item.rel + "/"
            tree.listings[item.rel] = nil
            tree.expanded = tree.expanded.filter { !$0.key.hasPrefix(prefix) }
            tree.listings = tree.listings.filter { !$0.key.hasPrefix(prefix) }
        } else {
            tree.expanded[item.rel] = item.url
            load(rel: item.rel, dir: item.url)
        }
    }

    /// Relit la racine et tous les dossiers dépliés : au premier affichage, puis chaque fois que les disques ont pu changer.
    private func reload() {
        tree.generation += 1
        tree.listings = [:]
        if tree.expanded.isEmpty, let demo = ProcessInfo.processInfo.environment["SYNCHRO_DEPLIE"] {
            // Capture de documentation : dossiers à montrer dépliés, séparés par des virgules.
            for rel in demo.split(separator: ",").map(String.init) { tree.expanded[rel] = root.appendingPathComponent(rel) }
        }
        load(rel: "", dir: root)
        for (rel, dir) in tree.expanded { load(rel: rel, dir: dir) }
    }

    private func load(rel: String, dir: URL) {
        let generation = tree.generation
        let ignoreHidden = preset.ignoreHidden
        let dstRoot = AppModel.destinationRoot(for: preset)
        let known = model.knownDifferences
        tree.listings[rel] = .loading
        Task { @MainActor in
            let (result, statuses) = await Task.detached { () -> (TreeListing, [String: DestinationStatus]?) in
                let result = TreeLoader.list(dir: dir, rel: rel, ignoreHidden: ignoreHidden)
                // Pastilles : une seule lecture du dossier correspondant de la destination, si elle est accessible.
                guard let dstRoot, case .items(let items) = result else { return (result, nil) }
                let dstDir = rel.isEmpty ? dstRoot : dstRoot.appendingPathComponent(rel)
                return (result, StatusCheck.statuses(for: items, in: dstDir, knownDifferences: known))
            }.value
            guard tree.generation == generation else { return }
            tree.listings[rel] = result
            if let statuses { model.destinationStatus.merge(statuses) { _, new in new } }
        }
    }
}

/// Lecture du contenu d'un dossier de la source, hors interface.
enum TreeLoader {
    nonisolated static func list(dir: URL, rel: String, ignoreHidden: Bool) -> TreeListing {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return .missing }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: []) else {
            return .denied
        }
        let items = urls.compactMap { url -> TreeItem? in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            if Scanner.isIgnoredName(name, hidden: v?.isHidden == true, ignoreHidden: ignoreHidden) { return nil }
            return TreeItem(dir: dir, name: name, rel: Scanner.key(rel.isEmpty ? name : rel + "/" + name), isDir: v?.isDirectory == true,
                            size: Int64(v?.fileSize ?? 0), mtime: v?.contentModificationDate ?? .distantPast)
        }
        // Les dossiers d'abord : ce sont eux qu'on ignore le plus souvent, ils ne doivent pas se perdre après des milliers de photos.
        .sorted { a, b in
            a.isDir != b.isDir ? a.isDir : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return .items(items)
    }
}

/// Actions par lot sur les éléments ignorés d'une tâche.
enum Batch {
    static func ignore(_ rels: [String], in preset: Binding<Preset>) {
        var known = Set(preset.wrappedValue.excludes.map(Scanner.excludeKey))
        for rel in rels where known.insert(Scanner.excludeKey(rel)).inserted {
            preset.wrappedValue.excludes.append(rel)
        }
    }

    static func allow(_ rels: [String], in preset: Binding<Preset>) {
        let keys = Set(rels.map(Scanner.excludeKey))
        preset.wrappedValue.excludes.removeAll { keys.contains(Scanner.excludeKey($0)) }
    }

    /// Ignore chaque enfant direct de `dir`, sauf les éléments de `except` et les dossiers qui en contiennent un.
    static func ignoreAll(in dir: URL, rel: String, except: Set<String>, preset: Binding<Preset>) {
        guard case .items(let items) = TreeLoader.list(dir: dir, rel: rel, ignoreHidden: preset.wrappedValue.ignoreHidden) else { return }
        let kept = Set(except.map(Scanner.excludeKey))
        var toIgnore: [String] = []
        for item in items {
            let key = Scanner.excludeKey(item.rel)
            if kept.contains(key) || kept.contains(where: { $0.hasPrefix(key + "/") }) { continue }
            toIgnore.append(item.rel)
        }
        allow(Array(except), in: preset)
        ignore(toIgnore, in: preset)
    }

    /// Lève toute exclusion à l'intérieur de `rel` (et sur lui-même).
    static func allowAll(under rel: String, preset: Binding<Preset>) {
        let key = Scanner.excludeKey(rel)
        preset.wrappedValue.excludes.removeAll { Scanner.excludeKey($0) == key || Scanner.excludeKey($0).hasPrefix(key + "/") }
    }
}

/// Maquette : un menu contextuel « ouvert », dessiné pour la capture de documentation.
struct DemoMenu: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            item("Ignorer la sélection (3)", highlighted: true)
            item("Synchroniser la sélection (3)")
            Divider().padding(.vertical, 4)
            item("Ignorer tout le contenu de « Exports »")
            item("Synchroniser tout le contenu de « Exports »")
            item("Ignorer tout sauf la sélection dans « Exports »")
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
        .fixedSize()
    }

    private func item(_ text: String, highlighted: Bool = false) -> some View {
        Text(text)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(highlighted ? Color.white : Color.primary)
            .background(highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
    }
}

struct TreeRow: View {
    @EnvironmentObject var model: AppModel
    let item: TreeItem
    let depth: Int
    let inherited: Bool
    /// Les éléments du même dossier, dans l'ordre affiché : ⇧-clic sélectionne une plage parmi eux.
    let siblings: [String]
    @Binding var preset: Preset
    /// Dossier déplié ? Décidé par la liste, qui tient l'état de tous les dossiers.
    let expanded: Bool
    /// Déplie ou replie ce dossier.
    let expand: () -> Void
    @Local private var hovering = false

    private var selected: Bool { model.treeSelection.contains(item.rel) }

    private var key: String { Scanner.excludeKey(item.rel) }
    private var excluded: Bool { preset.excludes.contains { Scanner.excludeKey($0) == key } }
    private var ignored: Bool { inherited || excluded }

    /// Nombre d'éléments ignorés à l'intérieur de ce dossier, quand lui-même est synchronisé.
    private var exceptions: Int {
        guard item.isDir, !ignored else { return 0 }
        let prefix = key + "/"
        return preset.excludes.filter { Scanner.excludeKey($0).hasPrefix(prefix) }.count
    }

    /// Flèche bleue : tout est synchronisé. Flèche jaune : synchronisé, sauf des exceptions à l'intérieur.
    private var tint: Color {
        if ignored { return .secondary }
        return exceptions > 0 ? TreeRow.partialColor : .accentColor
    }

    /// Jaune doré : le jaune pur du système se lit mal sur fond clair.
    static let partialColor = Color(red: 0.92, green: 0.64, blue: 0.0)

    private var hint: String {
        if inherited { return "Ignoré par un dossier parent" }
        if excluded { return "Ignoré — cliquer pour synchroniser" }
        if exceptions > 0 {
            return "Synchronisé, sauf \(Fmt.count(exceptions, "élément ignoré", "éléments ignorés")) à l'intérieur — cliquer pour ignorer tout le dossier"
        }
        return "Synchronisé — cliquer pour ignorer"
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: expand) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold)).frame(width: 12)
            }
            .buttonStyle(.plain)
            .opacity(item.isDir ? 1 : 0)
            .disabled(!item.isDir)
            .accessibilityLabel(expanded ? "Replier \(item.name)" : "Déplier \(item.name)")
            .accessibilityHidden(!item.isDir)

            Image(nsImage: Icons.icon(for: item))
                .resizable().frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(item.name).lineLimit(1).truncationMode(.middle).strikethrough(ignored)
            Spacer()
            if !ignored, let status = model.destinationStatus[item.rel] {
                Circle().fill(status.color).frame(width: 9, height: 9)
                    .help(status.label)
                    .accessibilityLabel(status.label)
            }
            if exceptions > 0 {
                Text(Fmt.count(exceptions, "ignoré", "ignorés")).font(.caption).foregroundStyle(TreeRow.partialColor)
            }
            Button(action: toggle) {
                Image(systemName: ignored ? "xmark" : "arrow.right")
                    .fontWeight(exceptions > 0 ? .heavy : .semibold)
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(inherited)
            .help(hint)
            .accessibilityLabel(item.name)
            .accessibilityValue(ignored ? "ignoré" : (exceptions > 0 ? "synchronisé, avec des éléments ignorés à l'intérieur" : "synchronisé"))
            .accessibilityHint(inherited ? "Ignoré par un dossier parent" : "Bascule entre synchronisé et ignoré")
        }
        .opacity(ignored ? 0.5 : 1)
        .padding(.leading, CGFloat(depth) * 18 + 8)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .background(selected ? Color.accentColor.opacity(0.18) : hovering ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { select() }
        .contextMenu { menu }
    }

    private func toggle() {
        if excluded {
            preset.excludes.removeAll { Scanner.excludeKey($0) == key }
        } else {
            preset.excludes.append(item.rel)
        }
    }

    /// Clic : sélectionne cette ligne seule ; ⌘-clic : l'ajoute ou la retire ; ⇧-clic : étend jusqu'à elle,
    /// parmi les éléments du même dossier, depuis la dernière ligne cliquée.
    private func select() {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor = model.treeAnchor,
           let a = siblings.firstIndex(of: anchor), let b = siblings.firstIndex(of: item.rel) {
            model.treeSelection.formUnion(siblings[min(a, b)...max(a, b)])
            return
        }
        if flags.contains(.command) {
            if selected { model.treeSelection.remove(item.rel) } else { model.treeSelection.insert(item.rel) }
        } else {
            model.treeSelection = selected && model.treeSelection.count == 1 ? [] : [item.rel]
        }
        model.treeAnchor = item.rel
    }

    /// Les actions portent sur la sélection si la ligne en fait partie, sinon sur la ligne seule.
    @ViewBuilder private var menu: some View {
        let targets = selected ? Array(model.treeSelection) : [item.rel]
        let what = selected && model.treeSelection.count > 1 ? "la sélection (\(targets.count))" : "« \(item.name) »"
        Button("Ignorer \(what)") { Batch.ignore(targets, in: $preset) }
        Button("Synchroniser \(what)") { Batch.allow(targets, in: $preset) }
        if item.isDir {
            Divider()
            Button("Ignorer tout le contenu de « \(item.name) »") {
                Batch.ignoreAll(in: item.url, rel: item.rel, except: [], preset: $preset)
            }
            Button("Synchroniser tout le contenu de « \(item.name) »") { Batch.allowAll(under: item.rel, preset: $preset) }
            Button("Ignorer tout sauf la sélection dans « \(item.name) »") {
                Batch.ignoreAll(in: item.url, rel: item.rel, except: model.treeSelection, preset: $preset)
            }
            .disabled(model.treeSelection.isEmpty)
        }
    }
}
