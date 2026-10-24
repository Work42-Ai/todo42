// PlanSummaryMarkdown.swift — shared hero markdown parsing for PlannedDay.summary.
// Extracted from Work42App/Home/MyPlannedDayWidget.swift (earnest-ridge.38) so the
// menu can reuse the same markdown parsing + bare-task-id linkification without
// duplicating code. The app's MyPlannedDayWidget refactors to call these instead.
//
// Menu link handling: `task:` link tapped → caller posts open-session deep link
// for the resolved task session; `http(s)` links return to the host's Open
// Link action.
// App link handling: both tap types route through the view's coordinator.

import Foundation

/// Parse `summary` as inline-only markdown (preserving whitespace) and
/// auto-linkify bare `T-xxx` task-id tokens into `task:<id>` URLs.
/// Returns an `AttributedString` ready for `Text(attr)` with an `openURL`
/// handler. Pure — no side effects; the caller supplies all routing.
public func planSummaryAttributed(_ summary: String) -> AttributedString {
    var attr: AttributedString
    if let parsed = try? AttributedString(
        markdown: summary,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    ) {
        attr = parsed
    } else {
        attr = AttributedString(summary)
    }
    TaskRefLinker.linkify(&attr)
    return attr
}

/// Turns bare `T-xxx` task references in the AI summary into tappable
/// `task:<id>` links. Extracted from Work42App/Home/MyPlannedDayWidget.swift
/// (earnest-ridge.38) so both the app and the menu share the same logic.
///
/// A task id is `T-` + digits, optionally `.` + digits (e.g. `T-003`,
/// `T-003.20`). Only bare tokens — ones that markdown parsing hasn't already
/// wrapped in a link — are linkified.
public enum TaskRefLinker {

    /// The custom URL scheme for an in-app task link (`task:T-003`).
    public static let scheme = "task"

    /// `T-` + digits + optional `.digits`, on a word boundary so we don't
    /// match inside a larger token.
    private static let regex = try? NSRegularExpression(
        pattern: #"(?<![\w-])T-\d+(?:\.\d+)?(?![\w])"#
    )

    /// Build a `task:<id>` URL for a bare task id.
    public static func url(forTaskId id: String) -> URL? {
        URL(string: "\(scheme):\(id)")
    }

    /// Recover the task id from a `task:<id>` URL. The id is stored in the
    /// scheme-specific part, so read it back from the absolute string.
    public static func taskId(from url: URL) -> String {
        let s = url.absoluteString
        guard s.hasPrefix("\(scheme):") else { return "" }
        return String(s.dropFirst(scheme.count + 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Find every bare `T-xxx` run in `attr` that ISN'T already a link and
    /// attach a `task:<id>` link to it, so it renders and taps like a markdown
    /// link beside it. Applied right-to-left so earlier ranges stay valid.
    public static func linkify(_ attr: inout AttributedString) {
        guard let regex else { return }
        let plain = String(attr.characters)
        let ns = plain as NSString
        let matches = regex.matches(
            in: plain, range: NSRange(location: 0, length: ns.length)
        )
        for match in matches.reversed() {
            guard let swiftRange = Range(match.range, in: plain) else { continue }
            let id = String(plain[swiftRange])
            guard let attrRange = Range(swiftRange, in: attr) else { continue }
            // Don't re-link a token the markdown parser already linked.
            if attr[attrRange].link != nil { continue }
            guard let link = url(forTaskId: id) else { continue }
            attr[attrRange].link = link
        }
    }
}
