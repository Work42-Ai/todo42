// Widget.swift — the To-Dos widget (WOR-382; ported from Work42's built-in To-Dos widget).
//
// The whole To-Dos collection of the project: one flat list in the store's order (completing a row never
// re-sorts it), an inline add row, inline rename, a due-date and a link editor, scheduled-slot chips that can be
// removed, and a context menu (Open / Complete / date / Delete). Everything is read and written through the
// `todo42` CLI over the session's shell service; the widget never touches the store.
//
// A To-Do that links to a Work42 session shows that session's workflow stage, asked of Work42's own
// `work42-session` tools (`services.tools`). The widget also carries the background agent that archives
// To-Dos whose linked session is archived (see `TodoArchiveAgent`).

import Foundation
import Observation
import SwiftUI
import Work42UI
import Work42PluginKit

// MARK: - Widget

@Observable
@MainActor
final class TodosWidget: Work42Widget, Work42WidgetBackground {

    let id = "todos"
    let title = "To-Dos"
    let icon = "checklist"
    var linkIntents: [WidgetLinkIntentSpec] { [] }
    var minSize: WidgetMinSize { WidgetMinSize(width: 280, height: 220) }

    func activate(services: SessionServices) {}
    func deactivate() {}

    func makeView(services: SessionServices) -> AnyView {
        AnyView(TodosView(services: services))
    }

    func makeBackgroundAgent() -> any WidgetBackgroundAgent { TodoArchiveAgent() }
}

// MARK: - Model

@Observable
@MainActor
final class TodosModel {

    private(set) var todos: [Todo42Item] = []
    /// Linked-session workflow stage by To-Do id (task and session links only).
    private(set) var stages: [String: String] = [:]
    private(set) var failure: Todo42Failure?
    private(set) var loaded = false
    var addRowVisible = false

    @ObservationIgnored private let services: SessionServices
    @ObservationIgnored private var slug = ""
    /// session id -> (stage, when it was asked). Sessions change stage rarely; asking every poll would be wasteful.
    @ObservationIgnored private var stageCache: [String: (stage: String?, at: Date)] = [:]

    init(services: SessionServices) {
        self.services = services
    }

    // MARK: Read

    func reload() async {
        do {
            let result = try await Todo42CLI.list(shell: services.shell)
            slug = result.slug
            if result.todos != todos { todos = result.todos }
            failure = nil
            loaded = true
            await refreshStages()
        } catch let error as Todo42Failure {
            failure = error
            loaded = true
        } catch {
            failure = .failed(command: "todo42 todos list --json", message: error.localizedDescription)
            loaded = true
        }
    }

    private func refreshStages() async {
        var next: [String: String] = [:]
        let now = Date()
        for todo in todos {
            guard let sessionId = Todo42Link.sessionId(url: todo.url, slug: slug) else { continue }
            if let cached = stageCache[sessionId], now.timeIntervalSince(cached.at) < 30 {
                if let stage = cached.stage { next[todo.id] = stage }
                continue
            }
            let stage = await sessionStage(sessionId)
            stageCache[sessionId] = (stage, now)
            if let stage { next[todo.id] = stage }
        }
        if next != stages { stages = next }
    }

    /// The session's workflow stage, or nil when Work42 does not know the session (archived rows still answer).
    private func sessionStage(_ sessionId: String) async -> String? {
        let value = try? await services.tools.call(
            server: "work42-session", tool: "session_show", arguments: [:], session: sessionId)
        guard case .object(let object)? = value, case .string(let stage)? = object["stage"], !stage.isEmpty else { return nil }
        return stage
    }

    // MARK: Writes (optimistic where the row should not jump, then reload)

    func commitAdd(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        run { try await Todo42CLI.add(title: trimmed, shell: $0) }
    }

    func toggle(_ todo: Todo42Item) {
        let completed = !todo.isCompleted
        if let index = todos.firstIndex(where: { $0.id == todo.id }) {
            todos[index].completedAt = completed ? ISO8601DateFormatter().string(from: Date()) : nil
        }
        run { try await Todo42CLI.setCompleted(todo.id, completed, shell: $0) }
    }

    func rename(_ id: String, to title: String) {
        patch(id) { $0.title = title }
        run { try await Todo42CLI.rename(id, to: title, shell: $0) }
    }

    func setURL(_ id: String, _ url: String?) {
        patch(id) { $0.url = url }
        run { try await Todo42CLI.setURL(id, url, shell: $0) }
    }

    func setDueDate(_ id: String, _ date: String?) {
        patch(id) { $0.dueDate = date }
        run { try await Todo42CLI.setDueDate(id, date, shell: $0) }
    }

    func removeSlot(_ id: String, at index: Int) {
        guard let todo = todos.first(where: { $0.id == id }), todo.slots.indices.contains(index) else { return }
        var remaining = todo.slots
        remaining.remove(at: index)
        patch(id) { $0.slots = remaining }
        run { try await Todo42CLI.setSlots(id, remaining, shell: $0) }
    }

    func remove(_ id: String) {
        todos.removeAll { $0.id == id }
        stages.removeValue(forKey: id)
        run { try await Todo42CLI.remove(id, shell: $0) }
    }

    func openLink(_ raw: String) {
        Task {
            try? await services.intents.execute(id: "global.openLink", params: ["url": .string(raw)])
        }
    }

    private func patch(_ id: String, _ change: (inout Todo42Item) -> Void) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        change(&todos[index])
    }

    /// Run a write, then re-read so the list shows what the store has. A failure is shown, never swallowed.
    private func run(_ write: @escaping @MainActor (any WidgetShellService) async throws -> Void) {
        let shell = services.shell
        Task {
            do { try await write(shell) } catch let error as Todo42Failure { failure = error } catch {
                failure = .failed(command: "todo42", message: error.localizedDescription)
            }
            await reload()
        }
    }
}

// MARK: - View

struct TodosView: View {
    @State private var model: TodosModel

    init(services: SessionServices) {
        _model = State(initialValue: TodosModel(services: services))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            while !Task.isCancelled {
                await model.reload()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: DT.s8) {
            Text("To-Dos")
                .font(.system(size: DT.f13, weight: .semibold))
            if !model.todos.isEmpty {
                Text("\(model.todos.filter { !$0.isCompleted }.count) open")
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .help("Refresh")
            Button { model.addRowVisible = true } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .help("New To-Do")
        }
        .padding(.horizontal, DT.s16)
        .padding(.vertical, DT.s8)
    }

    @ViewBuilder
    private var content: some View {
        if let failure = model.failure, model.todos.isEmpty {
            failureState(failure)
        } else if !model.loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.todos.isEmpty && !model.addRowVisible {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let failure = model.failure {
                    Text(failure.message)
                        .font(.system(size: DT.f11))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .padding(.horizontal, DT.s16)
                        .padding(.vertical, DT.s8)
                }
                if model.addRowVisible {
                    AddRowView(
                        onCommit: { model.commitAdd(title: $0) },
                        onDismiss: { model.addRowVisible = false })
                    Divider().padding(.leading, 20).opacity(0.5)
                }
                ForEach(model.todos) { todo in
                    TodoRowView(
                        todo: todo,
                        stage: model.stages[todo.id],
                        onOpenLink: { model.openLink($0) },
                        onToggle: { model.toggle(todo) },
                        onUpdateTitle: { model.rename(todo.id, to: $0) },
                        onUpdateURL: { model.setURL(todo.id, $0) },
                        onUpdateDueDate: { model.setDueDate(todo.id, $0) },
                        onDelete: { model.remove(todo.id) },
                        onRemoveSlot: { model.removeSlot(todo.id, at: $0) })
                    if todo.id != model.todos.last?.id {
                        Divider().padding(.leading, 56).opacity(0.5)
                    }
                }
            }
            .padding(.vertical, DT.s8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DT.s12) {
            Image(systemName: "checklist")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No To-Dos yet")
                .font(.system(size: DT.f13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Plan your day, or add one with the + button or `todo42 todos add`.")
                .font(.system(size: DT.f11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DT.s24)
    }

    private func failureState(_ failure: Todo42Failure) -> some View {
        VStack(spacing: DT.s12) {
            Image(systemName: failure == .notInstalled ? "square.and.arrow.down" : "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(failure == .notInstalled ? "todo42 is not installed" : "Couldn\u{2019}t read your To-Dos")
                .font(.system(size: DT.f13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(failure == .notInstalled
                 ? "Ask the agent to set up todo42 (the todo42-setup skill)."
                 : failure.message)
                .font(.system(size: DT.f11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button("Retry") { Task { await model.reload() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DT.s24)
    }
}

// MARK: - Animated checkmark

/// The animated circle-with-tick used by each row and the ghost add row.
struct TodoCheckmark: View {
    let isCompleted: Bool
    let isGhost: Bool
    let action: () -> Void

    init(isCompleted: Bool, isGhost: Bool = false, action: @escaping () -> Void) {
        self.isCompleted = isCompleted
        self.isGhost = isGhost
        self.action = action
    }

    @State private var isHovering = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    isGhost && !isHovering ? Color(nsColor: .separatorColor) : Color.accentColor,
                    lineWidth: 2)
            Circle()
                .fill(Color.accentColor)
                .scaleEffect(isCompleted ? 1.0 : 0.001, anchor: .center)
                .animation(.spring(response: 0.28, dampingFraction: 0.65), value: isCompleted)
            CheckmarkShape()
                .trim(from: 0, to: isCompleted ? 1.0 : 0.0)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .animation(.easeOut(duration: 0.26).delay(isCompleted ? 0.08 : 0), value: isCompleted)
        }
        .frame(width: 23, height: 23)
        .contentShape(Circle())
        .onHover { isHovering = $0 }
        .onTapGesture { action() }
    }
}

/// The checkmark tick path (M6.5 12.2 L10 15.6 L16.4 8 in a 23x23 box); supports `trim` for a progressive draw.
struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) * 0.5 / 11.5
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.midX + (x - 11.5) * scale, y: rect.midY + (y - 11.5) * scale)
        }
        var path = Path()
        path.move(to: point(6.5, 12.2))
        path.addLine(to: point(10.0, 15.6))
        path.addLine(to: point(16.4, 8.0))
        return path
    }
}

// MARK: - Add row

/// The ghost "New To-Do" row revealed by the + button. Return commits and reopens (continuous add); Esc or an
/// empty blur dismisses.
struct AddRowView: View {
    let onCommit: (String) -> Void
    let onDismiss: () -> Void

    @State private var text = ""
    /// Guards the focus-loss handler from committing twice right after an explicit Return.
    @State private var justCommitted = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            TodoCheckmark(isCompleted: false, isGhost: true) { isFocused = true }
            TextField("New To-Do", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($isFocused)
                .onSubmit {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        onDismiss()
                    } else {
                        justCommitted = true
                        onCommit(trimmed)
                        text = ""
                        justCommitted = false
                        isFocused = true
                    }
                }
                .onExitCommand { onDismiss() }
                .onChange(of: isFocused) { _, focused in
                    guard !focused, !justCommitted else { return }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { onDismiss() } else { onCommit(trimmed) }
                }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .onAppear { DispatchQueue.main.async { isFocused = true } }
    }
}

// MARK: - Row

struct TodoRowView: View {
    let todo: Todo42Item
    /// The linked session's workflow stage, when the link has one.
    let stage: String?
    let onOpenLink: (String) -> Void
    let onToggle: () -> Void
    let onUpdateTitle: (String) -> Void
    let onUpdateURL: (String?) -> Void
    let onUpdateDueDate: (String?) -> Void
    let onDelete: () -> Void
    var onRemoveSlot: (Int) -> Void = { _ in }

    @State private var editingTitle = false
    @State private var editText = ""
    @FocusState private var titleFocused: Bool
    @State private var showLinkEditor = false
    @State private var linkEditorText = ""
    @State private var showDueDateEditor = false
    @State private var dueDateEditorText = ""

    private var isCompleted: Bool { todo.isCompleted }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            TodoCheckmark(isCompleted: isCompleted) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.68)) { onToggle() }
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                titleView
                subRow
            }

            Spacer(minLength: 0)

            if let rawURL = todo.url, URL(string: rawURL) != nil {
                Button { onOpenLink(rawURL) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
                .buttonStyle(.plain)
                .padding(.top, 3)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !editingTitle else { return }
            switch todo.kind {
            case .task, .review, .session:
                if let rawURL = todo.url { onOpenLink(rawURL) }
            case .link, .todo:
                break
            }
        }
        .contextMenu { contextMenuItems }
        .popover(isPresented: $showLinkEditor, arrowEdge: .bottom) { linkEditor }
        .popover(isPresented: $showDueDateEditor, arrowEdge: .bottom) { dueDateEditor }
    }

    // MARK: Title

    @ViewBuilder
    private var titleView: some View {
        if editingTitle {
            TextField("", text: $editText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($titleFocused)
                .onSubmit { commitEdit() }
                .onExitCommand { editingTitle = false }
                .onChange(of: titleFocused) { _, focused in
                    if !focused { commitEdit() }
                }
        } else {
            Text(todo.title)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(isCompleted ? Color(nsColor: .tertiaryLabelColor) : Color.primary)
                .lineLimit(2)
                .overlay(alignment: .leading) {
                    // Animated left-to-right strikeout.
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color(nsColor: .tertiaryLabelColor))
                            .frame(width: isCompleted ? geo.size.width : 0, height: 1.5)
                            .offset(y: geo.size.height * 0.5 - 0.75)
                            .animation(.easeInOut(duration: 0.32), value: isCompleted)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: isCompleted)
                .onTapGesture {
                    editText = todo.title
                    editingTitle = true
                    DispatchQueue.main.async { titleFocused = true }
                }
        }
    }

    // MARK: Chips

    @ViewBuilder
    private var subRow: some View {
        let kind = todo.kind
        let hasLink = (kind == .link && todo.url != nil) || kind == .todo
        if stage != nil || hasLink || todo.dueDate != nil || !todo.slots.isEmpty {
            HStack(spacing: 7) {
                if let stage {
                    chip(Text(stage), foreground: DT.textSecondary, background: DT.textSecondary.opacity(0.14))
                }
                if kind == .link, let rawURL = todo.url {
                    Button {
                        linkEditorText = rawURL
                        showLinkEditor = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                            Text(Todo42Format.host(rawURL)).lineLimit(1)
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(Color(nsColor: .systemGreen).opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                    .opacity(isCompleted ? 0.55 : 1)
                } else if kind == .todo {
                    Button {
                        linkEditorText = ""
                        showLinkEditor = true
                    } label: {
                        Text("\u{FF0B} Link")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    }
                    .buttonStyle(.plain)
                    .opacity(isCompleted ? 0.55 : 1)
                }
                if let due = todo.dueDate {
                    chip(Text("\u{25F7} Due \(Todo42Format.dueLabel(due))"),
                         foreground: Color(nsColor: .systemOrange), background: Color(nsColor: .systemOrange).opacity(0.18))
                }
                ForEach(Array(todo.slots.enumerated()), id: \.offset) { index, slot in
                    if let range = Todo42Format.slotRange(slot) {
                        Button { onRemoveSlot(index) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "clock").font(.system(size: DT.f10, weight: .semibold))
                                Text(range).lineLimit(1)
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).opacity(0.7)
                            }
                            .font(.system(size: DT.f11, weight: .semibold))
                            .foregroundStyle(DT.textSecondary)
                            .padding(.horizontal, DT.s8)
                            .padding(.vertical, 3)
                            .background(Capsule(style: .continuous).fill(DT.textSecondary.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                        .help("Unschedule \(range)")
                        .opacity(isCompleted ? 0.55 : 1)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: isCompleted)
        }
    }

    private func chip(_ label: Text, foreground: Color, background: Color) -> some View {
        label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(background))
            .opacity(isCompleted ? 0.55 : 1)
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenuItems: some View {
        if let rawURL = todo.url, URL(string: rawURL) != nil {
            Button { onOpenLink(rawURL) } label: { Label("Open", systemImage: "arrow.up.right") }
            Divider()
        }
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.68)) { onToggle() }
        } label: {
            if isCompleted {
                Label("Mark not done", systemImage: "circle")
            } else {
                Label("Complete", systemImage: "checkmark.circle")
            }
        }
        Button {
            dueDateEditorText = todo.dueDate ?? ""
            showDueDateEditor = true
        } label: {
            if todo.dueDate == nil {
                Label("Set date\u{2026}", systemImage: "calendar.badge.plus")
            } else {
                Label("Change date\u{2026}", systemImage: "calendar")
            }
        }
        if todo.dueDate != nil {
            Button { onUpdateDueDate(nil) } label: { Label("Clear date", systemImage: "xmark.circle") }
        }
        Divider()
        Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: Popovers

    private var linkEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LINK")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            TextField("https://\u{2026}  \u{B7}  work42://task/\u{2026}", text: $linkEditorText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit {
                    let trimmed = linkEditorText.trimmingCharacters(in: .whitespacesAndNewlines)
                    onUpdateURL(trimmed.isEmpty ? nil : trimmed)
                    showLinkEditor = false
                }
                .onExitCommand { showLinkEditor = false }
            if todo.url != nil {
                Button("Remove link") {
                    onUpdateURL(nil)
                    showLinkEditor = false
                }
                .foregroundStyle(Color(nsColor: .systemRed))
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
            }
        }
        .padding(12)
    }

    private var dueDateEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DUE DATE")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            TextField("YYYY-MM-DD", text: $dueDateEditorText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .onSubmit {
                    let trimmed = dueDateEditorText.trimmingCharacters(in: .whitespacesAndNewlines)
                    onUpdateDueDate(trimmed.isEmpty ? nil : trimmed)
                    showDueDateEditor = false
                }
                .onExitCommand { showDueDateEditor = false }
            if todo.dueDate != nil {
                Button("Clear date") {
                    onUpdateDueDate(nil)
                    showDueDateEditor = false
                }
                .foregroundStyle(Color(nsColor: .systemRed))
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
            }
        }
        .padding(12)
    }

    private func commitEdit() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != todo.title { onUpdateTitle(trimmed) }
        editingTitle = false
    }
}

// MARK: - Background agent: archive To-Dos whose session is archived

/// One per session: every 12 hours asks Work42 which of the sessions the To-Dos link to are archived and has
/// `todo42 todos sweep` stamp those To-Dos and purge archived ones older than the app's archive window. It does
/// what Work42's own archive timer did for To-Dos before the plugin existed. Fail-soft: a lookup that fails
/// archives nothing.
@Observable
@MainActor
final class TodoArchiveAgent: WidgetBackgroundAgent {

    private(set) var headerLabels: [WidgetHeaderLabel] = []

    @ObservationIgnored private var task: Task<Void, Never>?

    /// The app-wide "archive wait" setting (hours). -1 is Never, which skips the sweep entirely.
    private static let archiveHoursKey = "work42.archive.autoArchiveHours"
    /// Archived To-Dos are kept at least this long, whatever the session wait is.
    private static let minimumPurgeHours = 24
    private static let sweepInterval: Duration = .seconds(12 * 3600)

    func start(services: WidgetBackgroundServices) {
        task?.cancel()
        task = Task { [weak self] in
            // Let the app finish launching before the first sweep.
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                await self?.sweep(services)
                try? await Task.sleep(for: Self.sweepInterval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func sweep(_ services: WidgetBackgroundServices) async {
        let stored = UserDefaults.standard.object(forKey: Self.archiveHoursKey) as? Int ?? 0
        guard stored != -1 else { return }
        let purgeAfter = max(Self.minimumPurgeHours, stored)

        guard let listed = try? await listTodos(services.shell) else { return }
        var taskIds = Set<String>(), sessionIds = Set<String>()
        var asked: [String: Bool] = [:]
        for todo in listed.todos {
            switch Todo42Link.target(url: todo.url, slug: listed.slug) {
            case .none:
                continue
            case .task(let id):
                if await isArchived(id, services, cache: &asked) { taskIds.insert(id) }
            case .session(let id):
                if await isArchived(id, services, cache: &asked) { sessionIds.insert(id) }
            }
        }

        var arguments = ["todos", "sweep", "--purge-after-hours", String(purgeAfter)]
        for id in taskIds.sorted() { arguments += ["--archived-task", id] }
        for id in sessionIds.sorted() { arguments += ["--archived-session", id] }
        _ = try? await Todo42CLI.run(arguments, shell: services.shell)
    }

    private func listTodos(_ shell: any WidgetShellService) async throws -> (slug: String, todos: [Todo42Item]) {
        try await Todo42CLI.list(shell: shell)
    }

    /// Whether Work42 reports the session archived (`session_show` carries `archived_at`). Unknown sessions and
    /// failed lookups count as not archived.
    private func isArchived(_ sessionId: String, _ services: WidgetBackgroundServices,
                            cache: inout [String: Bool]) async -> Bool {
        if let known = cache[sessionId] { return known }
        let value = try? await services.tools.call(
            server: "work42-session", tool: "session_show", arguments: [:], session: sessionId)
        var archived = false
        if case .object(let object)? = value, case .string(let stamp)? = object["archived_at"], !stamp.isEmpty {
            archived = true
        }
        cache[sessionId] = archived
        return archived
    }
}

// MARK: - Plugin entry points

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(TodosWidget())
    }
    return result
}
