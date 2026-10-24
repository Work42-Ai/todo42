// Widget.swift — the My Planned Day widget (WOR-382; ported from Work42's built-in Overview widget).
//
// One day's briefing, read through `todo42 planned-day show --json`: the hero summary the daily-planning routine
// writes, the day-structure donut with its legend, and the To-Dos scheduled for that day (a slot that day, or
// due that day). It has its own date navigation (previous, Today, next). Ticking a To-Do goes through
// `todo42 todos complete|reopen`. Nothing here writes the plan: ask the agent to plan the day, or let the
// daily-planning routine do it.

import Charts
import Foundation
import Observation
import SwiftUI
import Work42UI
import Work42PluginKit

// MARK: - Widget

@Observable
@MainActor
final class MyPlannedDayWidget: Work42Widget {

    let id = "my-planned-day"
    let title = "My Planned Day"
    let icon = "sun.max"
    var linkIntents: [WidgetLinkIntentSpec] { [] }
    var minSize: WidgetMinSize { WidgetMinSize(width: 300, height: 260) }

    func activate(services: SessionServices) {}
    func deactivate() {}

    func makeView(services: SessionServices) -> AnyView {
        AnyView(PlannedDayView(services: services))
    }
}

// MARK: - Model

@Observable
@MainActor
final class PlannedDayModel {

    /// The day shown, `YYYY-MM-DD` in the local calendar.
    private(set) var selectedDate = Todo42Format.day(Date())
    private(set) var day: Todo42Day?
    private(set) var failure: Todo42Failure?
    private(set) var loaded = false

    @ObservationIgnored private let services: SessionServices

    init(services: SessionServices) {
        self.services = services
    }

    var isShowingToday: Bool { selectedDate == Todo42Format.day(Date()) }

    var dateLabel: String {
        guard let date = Todo42Format.date(fromDay: selectedDate) else { return selectedDate }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: date)
    }

    func step(by days: Int) {
        guard let current = Todo42Format.date(fromDay: selectedDate),
              let moved = Calendar.current.date(byAdding: .day, value: days, to: current) else { return }
        select(Todo42Format.day(moved))
    }

    func goToToday() { select(Todo42Format.day(Date())) }

    private func select(_ date: String) {
        guard date != selectedDate else { return }
        selectedDate = date
        day = nil
        loaded = false
        Task { await reload() }
    }

    func reload() async {
        let requested = selectedDate
        do {
            let result = try await Todo42CLI.day(requested, shell: services.shell)
            // The user may have stepped to another day while this was running.
            guard requested == selectedDate else { return }
            day = result
            failure = nil
        } catch let error as Todo42Failure {
            guard requested == selectedDate else { return }
            failure = error
        } catch {
            guard requested == selectedDate else { return }
            failure = .failed(command: "todo42 planned-day show --json", message: error.localizedDescription)
        }
        loaded = true
    }

    func toggle(_ todo: Todo42Item) {
        let completed = !todo.isCompleted
        if var current = day, let index = current.todos.firstIndex(where: { $0.id == todo.id }) {
            current.todos[index].completedAt = completed ? ISO8601DateFormatter().string(from: Date()) : nil
            day = current
        }
        let shell = services.shell
        Task {
            do { try await Todo42CLI.setCompleted(todo.id, completed, shell: shell) } catch let error as Todo42Failure {
                failure = error
            } catch {
                failure = .failed(command: "todo42", message: error.localizedDescription)
            }
            await reload()
        }
    }

    /// Open a link through Work42's Open Link. The summary's `task:<id>` links become `work42://task/<id>`.
    func openLink(_ url: URL) {
        var raw = url.absoluteString
        if url.scheme == "task" { raw = "work42://task/\(url.absoluteString.dropFirst("task:".count))" }
        Task {
            try? await services.intents.execute(id: "global.openLink", params: ["url": .string(raw)])
        }
    }
}

// MARK: - View

struct PlannedDayView: View {
    @State private var model: PlannedDayModel

    init(services: SessionServices) {
        _model = State(initialValue: PlannedDayModel(services: services))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            while !Task.isCancelled {
                await model.reload()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: Header (date navigation)

    private var header: some View {
        HStack(spacing: DT.s8) {
            Button { model.step(by: -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .help("Previous day")
            Text(model.dateLabel)
                .font(.system(size: DT.f13, weight: .semibold))
            Button { model.step(by: 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .help("Next day")
            Spacer()
            if !model.isShowingToday {
                Button("Today") { model.goToToday() }
                    .buttonStyle(.plain)
                    .font(.system(size: DT.f11, weight: .semibold))
                    .foregroundStyle(DT.systemAccent)
            }
            Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .help("Refresh")
        }
        .padding(.horizontal, DT.s16)
        .padding(.vertical, DT.s8)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let failure = model.failure, model.day == nil {
            failureState(failure)
        } else if !model.loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let day = model.day {
            ScrollView {
                VStack(alignment: .leading, spacing: DT.s16) {
                    if let failure = model.failure {
                        Text(failure.message)
                            .font(.system(size: DT.f11))
                            .foregroundStyle(Color(nsColor: .systemRed))
                    }
                    if let summary = day.summary, !summary.isEmpty { hero(summary) }
                    if let structure = day.dayStructure, !DaySegment.present(from: structure).isEmpty {
                        VStack(alignment: .leading, spacing: DT.s8) {
                            sectionHeader("Day structure")
                            DayStructureDonut(structure: structure)
                        }
                    }
                    todosSection(day.todos)
                }
                .padding(DT.s16)
            }
        } else {
            emptyState
        }
    }

    private func hero(_ summary: String) -> some View {
        let attributed = (try? AttributedString(
            markdown: summary,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(summary)
        return Text(attributed)
            .font(.system(size: 15))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                model.openLink(url)
                return .handled
            })
    }

    private func todosSection(_ todos: [Todo42Item]) -> some View {
        VStack(alignment: .leading, spacing: DT.s8) {
            sectionHeader("To-Dos for the day", count: todos.count)
            if todos.isEmpty {
                Text("Nothing scheduled for this day.")
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(todos) { todo in
                    DayTodoRow(
                        todo: todo,
                        onToggle: { model.toggle(todo) },
                        onOpen: { if let raw = todo.url, let url = URL(string: raw) { model.openLink(url) } })
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: DT.s8) {
            Text(title.uppercased())
                .font(.system(size: DT.f11, weight: .bold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            if let count {
                Text("\(count)")
                    .font(.system(size: DT.f11, weight: .semibold))
                    .foregroundStyle(DT.textSecondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: DT.s12) {
            Image(systemName: "sun.max")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No plan yet for \(model.dateLabel)")
                .font(.system(size: DT.f13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("The daily-planning routine writes it, or ask the agent to plan your day.")
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
            Text(failure == .notInstalled ? "todo42 is not installed" : "Couldn\u{2019}t read your planned day")
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

// MARK: - A scheduled To-Do

struct DayTodoRow: View {
    let todo: Todo42Item
    let onToggle: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DT.s12) {
            Button(action: onToggle) {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(todo.isCompleted ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(todo.title)
                    .font(.system(size: 14))
                    .strikethrough(todo.isCompleted)
                    .foregroundStyle(todo.isCompleted ? Color(nsColor: .tertiaryLabelColor) : Color.primary)
                    .lineLimit(2)
                let ranges = todo.slots.compactMap(Todo42Format.slotRange)
                if !ranges.isEmpty || todo.dueDate != nil {
                    Text(timing(ranges))
                        .font(.system(size: DT.f11))
                        .foregroundStyle(DT.textSecondary)
                }
                if let reason = todo.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: DT.f11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if todo.url != nil {
                Button(action: onOpen) {
                    Image(systemName: todo.kind.glyph)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
                .buttonStyle(.plain)
                .help("Open")
            }
        }
        .opacity(todo.isCompleted ? 0.7 : 1)
    }

    private func timing(_ ranges: [String]) -> String {
        if !ranges.isEmpty { return ranges.joined(separator: ", ") }
        if let due = todo.dueDate { return "All day \u{00B7} due \(Todo42Format.dueLabel(due))" }
        return ""
    }
}

// MARK: - Day structure donut

/// One wedge of the donut: a category with its minutes, in legend order.
struct DaySegment: Identifiable {

    enum Category: String, CaseIterable {
        case focus = "Focus"
        case reviews = "Reviews"
        case meetings = "Meetings"
        case personal = "Personal"
        case free = "Free"

        func minutes(in structure: Todo42DayStructure) -> Int {
            switch self {
            case .focus: return structure.focus
            case .reviews: return structure.reviews
            case .meetings: return structure.meetings
            case .personal: return structure.personal
            case .free: return structure.free
            }
        }

        var color: Color {
            switch self {
            case .focus: return DT.systemAccent
            case .reviews: return DT.systemAccent.opacity(0.45)
            case .meetings: return DT.magentaMid
            case .personal: return Color(red: 0.20, green: 0.55, blue: 0.92)
            case .free: return Color.secondary.opacity(0.30)
            }
        }
    }

    let category: Category
    let minutes: Int
    var id: String { category.rawValue }
    var label: String { category.rawValue }
    var color: Color { category.color }

    /// The categories with a positive duration, in legend order; empty for a nil or all-zero structure.
    static func present(from structure: Todo42DayStructure?) -> [DaySegment] {
        guard let structure else { return [] }
        return Category.allCases
            .map { DaySegment(category: $0, minutes: $0.minutes(in: structure)) }
            .filter { $0.minutes > 0 }
    }
}

struct DayStructureDonut: View {
    let structure: Todo42DayStructure

    private var segments: [DaySegment] { DaySegment.present(from: structure) }

    var body: some View {
        HStack(alignment: .center, spacing: DT.s20) {
            ZStack {
                Chart(segments) { segment in
                    SectorMark(angle: .value("Minutes", segment.minutes), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .cornerRadius(2)
                        .foregroundStyle(segment.color)
                }
                .chartLegend(.hidden)
                // The headline is real work (Focus + Reviews + Meetings); on a 24h day the all-but-free
                // total would be a meaningless ~20h.
                VStack(spacing: 1) {
                    Text(Todo42Format.minutes(structure.workMinutes))
                        .font(.system(size: DT.f17, weight: .bold))
                    Text("work")
                        .font(.system(size: DT.f9))
                        .foregroundStyle(DT.textSecondary)
                }
            }
            .frame(width: 132, height: 132)
            Spacer()
            VStack(alignment: .leading, spacing: DT.s8) {
                ForEach(segments) { segment in
                    HStack(spacing: DT.s8) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(segment.color)
                            .frame(width: 10, height: 10)
                        Text(segment.label).font(.system(size: DT.f11))
                        Spacer(minLength: DT.s12)
                        Text(Todo42Format.minutes(segment.minutes))
                            .font(.system(size: DT.f11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DT.textSecondary)
                    }
                }
            }
            .frame(maxWidth: 160, alignment: .leading)
        }
    }
}

// MARK: - Plugin entry points

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(MyPlannedDayWidget())
    }
    return result
}
