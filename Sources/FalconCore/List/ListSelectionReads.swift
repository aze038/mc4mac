import Foundation
import Observation

/// One selected row as the reading pane takes it, wherever the row now is in the list.
public struct ListReadingTarget: Hashable, Sendable {
    public var key: RowKey
    public var kind: SelectedListRow.Kind

    public init(key: RowKey, kind: SelectedListRow.Kind) {
        self.key = key
        self.kind = kind
    }
}

extension SelectedListRow {
    public var target: ListReadingTarget { ListReadingTarget(key: key, kind: kind) }
}

/// What the reading pane shows at once for rows just selected, while their messages are read:
/// what their rows already say (sender, subject, date and preview) and, after the deadline, that
/// the message could not be read yet, with Try Again.
public struct ListReadingPlaceholder: Hashable, Sendable {
    public var targets: [ListReadingTarget]
    public var subject: String
    public var from: EmailAddress?
    public var to: [EmailAddress]
    public var date: Date?
    public var snippet: String
    /// The read took longer than the deadline: the pane offers Try Again.
    public var timedOut: Bool

    public init(targets: [ListReadingTarget], subject: String = "", from: EmailAddress? = nil, to: [EmailAddress] = [],
                date: Date? = nil, snippet: String = "", timedOut: Bool = false) {
        self.targets = targets
        self.subject = subject
        self.from = from
        self.to = to
        self.date = date
        self.snippet = snippet
        self.timedOut = timedOut
    }

    /// The rows' own text, as far as the list holds it. Several rows show only how many.
    public static func of(_ targets: [ListReadingTarget], content: RowContentStore) -> ListReadingPlaceholder {
        var placeholder = ListReadingPlaceholder(targets: targets)
        guard targets.count == 1, let row = content.peek(targets[0].key) else { return placeholder }
        placeholder.subject = row.subject
        placeholder.from = row.from
        placeholder.to = row.to
        placeholder.date = row.date
        placeholder.snippet = row.preview
        return placeholder
    }
}

/// The reads of the table's selection into the app's, and what the reading pane shows meanwhile.
///
/// Selecting a row switches the reading pane to it at once, whatever else is going on: the pane
/// shows what the row says (`placeholder`) until the row's messages have been read, from Gmail if
/// need be, and never waits for the read of an earlier selection. A read not finished by the
/// deadline leaves the pane showing the row's preview with Try Again, though its messages still
/// show if it finishes later; a read that finishes after a newer selection began is thrown away,
/// so the newest selection always wins.
///
/// A command on the selection given while its rows are being read, such as Delete pressed just
/// after moving down a row, waits for the read (`whenRead`), so it acts on the rows the owner
/// sees selected, never on those selected before. It is dropped if the selection moves to other
/// rows first, or if the read runs past its deadline.
@MainActor
@Observable
public final class ListSelectionReads {
    /// A read has begun whose selection has not been handed over yet.
    public private(set) var isReading = false
    /// What the reading pane shows while the rows now selected are read; nil once they are, and
    /// while the pane already shows them, as when a selected row is read again after it changed.
    public private(set) var placeholder: ListReadingPlaceholder?
    /// The rows whose messages the app's selection holds now.
    public private(set) var shownTargets: [ListReadingTarget] = []

    public let deadline: TimeInterval
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var readingTargets: [ListReadingTarget] = []
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var waiting: [@MainActor () -> Void] = []
    @ObservationIgnored private var timedOut = false

    public init(deadline: TimeInterval = 10) {
        self.deadline = deadline
    }

    /// Whether a read of other rows than those the app's selection holds is under way: the pane
    /// shows `placeholder` meanwhile.
    public var switchesRows: Bool { placeholder != nil }

    /// Begins reading the rows `targets`, giving up any read before, and returns its generation.
    /// The pane switches at once to `placeholder` unless it already shows these rows. `read` is
    /// given the generation, which it hands back to `handOver(_:)`; a read overtaken by a newer
    /// one hands nothing over.
    @discardableResult
    public func start(_ targets: [ListReadingTarget], placeholder: ListReadingPlaceholder,
                      _ read: @escaping @MainActor (_ generation: Int) async -> Void) -> Int {
        running?.cancel()
        timer?.cancel()
        generation += 1
        let current = generation
        let same = isReading && targets == readingTargets
        if !same {
            // Other rows: nothing waiting for the rows before may act on these.
            waiting = []
            let next: ListReadingPlaceholder? = targets == shownTargets ? nil : placeholder
            if self.placeholder != next { self.placeholder = next }
        } else if self.placeholder?.timedOut == true {
            self.placeholder?.timedOut = false
        }
        readingTargets = targets
        timedOut = false
        if !isReading { isReading = true }
        running = Task { await read(current) }
        let deadline = deadline
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, deadline) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isCurrent(current) else { return }
            self.runOutOfTime()
        }
        return current
    }

    /// Whether `generation` is the read of the rows selected now.
    public func isCurrent(_ generation: Int) -> Bool { generation == self.generation && isReading }

    /// The read `generation` has read its rows into the app's selection: the pane shows them and
    /// the commands waiting on them run. False, and nothing changes, for a read overtaken by a
    /// newer one.
    @discardableResult
    public func handOver(_ generation: Int) -> Bool {
        guard isCurrent(generation) else { return false }
        finish(showing: readingTargets)
        return true
    }

    /// The app's selection holds `targets` without a read, as when nothing is selected.
    public func handOverAtOnce(_ targets: [ListReadingTarget]) {
        running?.cancel()
        generation += 1
        readingTargets = targets
        finish(showing: targets)
    }

    /// Nothing is read any more, as when the table is hidden. Commands waiting are dropped.
    public func stop() {
        running?.cancel()
        running = nil
        timer?.cancel()
        generation += 1
        waiting = []
        readingTargets = []
        shownTargets = []
        timedOut = false
        if isReading { isReading = false }
        if placeholder != nil { placeholder = nil }
    }

    /// Runs `body` once the rows the table shows selected are in the app's selection: at once
    /// when they are, after the read under way otherwise. False when it is dropped, after the
    /// read ran out of time; it is dropped too if the selection moves to other rows first.
    @discardableResult
    public func whenRead(_ body: @escaping @MainActor () -> Void) -> Bool {
        guard isReading else {
            body()
            return true
        }
        guard !timedOut else { return false }
        waiting.append(body)
        return true
    }

    private func finish(showing targets: [ListReadingTarget]) {
        timer?.cancel()
        timedOut = false
        shownTargets = targets
        if isReading { isReading = false }
        if placeholder != nil { placeholder = nil }
        let run = waiting
        waiting = []
        for body in run { body() }
    }

    private func runOutOfTime() {
        timedOut = true
        waiting = []
        placeholder?.timedOut = true
    }
}

extension ListStatusText {
    /// A command given while the rows selected could not be read in time.
    public static let selectionStillReading = "The selected message hasn't opened yet. Try again in a moment."
}

extension SelectedListRow {
    /// Whether two readings of a selection stand for the same messages as the same kinds of row,
    /// wherever those rows now are, as after new mail arrived above them.
    public static func standForTheSameMessages(_ a: [SelectedListRow]?, _ b: [SelectedListRow]?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.kind == $1.kind }
    }
}
