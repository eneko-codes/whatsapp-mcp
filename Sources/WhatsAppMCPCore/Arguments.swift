import Foundation

/// Typed access to a `tools/call` argument bag.
///
/// A class, not a struct, so that reading a quantity can also record that it was moved into
/// its range without every reader having to be `mutating`. One instance serves one call and
/// never leaves it. The tool puts `notices` before the data.
///
/// Every tool on this server is a read, so no argument ever names a field to be emptied: an
/// absent argument, or JSON null, simply means the filter is not applied. A value of the
/// wrong type is refused with the form expected, never read as absent, because a filter
/// that is quietly dropped widens the answer and nothing in it says so.
public final class Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    /// One sentence for each quantity that was moved into its range, in the order read.
    public private(set) var notices: [String] = []

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    /// Refuses a name the tool's schema does not list. Without it a caller still using a
    /// renamed argument (`after`, `before`) would run an unfiltered call and read the answer
    /// as filtered.
    public func refuseUnknown(tool: String, allowed: [String]) throws {
        guard let stray = values.keys.sorted().first(where: { !allowed.contains($0) }) else {
            return
        }
        throw ToolError.unknownArgument(name: stray, tool: tool, allowed: allowed.sorted())
    }

    /// Whether the caller gave `name` at all, null counting as not given.
    public func isGiven(_ name: String) -> Bool { given(name) != nil }

    /// `nil` when the argument is absent or null, which mean the same: not given.
    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    // MARK: Text

    public func requiredString(_ name: String) throws -> String {
        guard let text = try optionalString(name) else {
            throw ToolError.missingArgument(name)
        }
        return text
    }

    /// Empty or blank text is "not given", as JSON null is.
    public func optionalString(_ name: String) throws -> String? {
        guard let raw = given(name) else { return nil }
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "text was expected")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func stringArray(_ name: String) throws -> [String] {
        guard let raw = given(name) else { return [] }
        // A single string where an array is expected is a common and harmless slip.
        if let single = raw.stringValue {
            let trimmed = single.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        guard let entries = raw.arrayValue, entries.allSatisfy({ $0.stringValue != nil }) else {
            throw ToolError.badArgument(name: name, reason: "an array of strings was expected")
        }
        return entries.compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: Flags

    public func bool(_ name: String, default fallback: Bool = false) throws -> Bool {
        try optionalBool(name) ?? fallback
    }

    /// Nil when absent, which is what separates "only messages I sent" from "any
    /// message". A tri-state has to stay a tri-state.
    public func optionalBool(_ name: String) throws -> Bool? {
        guard let raw = given(name) else { return nil }
        guard let flag = raw.boolValue else {
            throw ToolError.badArgument(name: name, reason: "true or false was expected")
        }
        return flag
    }

    // MARK: Numbers

    private func wholeNumber(_ name: String) throws -> Int? {
        guard let raw = given(name) else { return nil }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "a whole number was expected")
        }
        return number
    }

    /// An identifier: a chat, message or label id. Outside its range it is refused, not
    /// moved, because the nearest allowed value would name something else than what was
    /// asked for.
    public func optionalIdentifier(_ name: String, in range: ClosedRange<Int>) throws -> Int64? {
        guard let raw = given(name) else { return nil }
        guard let number = raw.intValue, range.contains(number) else {
            throw ToolError.badArgument(
                name: name,
                reason:
                    "an id, a whole number from \(range.lowerBound) to \(range.upperBound), was expected")
        }
        return Int64(number)
    }

    public func requiredIdentifier(_ name: String, in range: ClosedRange<Int>) throws -> Int64 {
        guard let number = try optionalIdentifier(name, in: range) else {
            throw ToolError.missingArgument(name)
        }
        return number
    }

    /// A quantity: a page size, a count to skip, a window. Outside its range it is moved to
    /// the nearest allowed value, and `notices` gains the sentence that says which was used.
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let number = try wholeNumber(name) else { return fallback }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// The `limit` and `offset` of a listing, read the same way by every tool that pages.
    public func page(defaultLimit: Int, limits: ClosedRange<Int>) throws -> (limit: Int, offset: Int) {
        (
            try int("limit", default: defaultLimit, in: limits),
            try int("offset", default: 0, in: Configuration.offsetRange)
        )
    }

    /// The `character_offset` and `max_characters` of a window on one long text.
    public func window() throws -> (characterOffset: Int, maxCharacters: Int) {
        (
            try int("character_offset", default: 0, in: Configuration.offsetRange),
            try int(
                "max_characters", default: Configuration.defaultMaxCharacters,
                in: Configuration.maxCharactersRange)
        )
    }

    // MARK: Dates

    public func optionalDate(_ name: String) throws -> ParsedDate? {
        guard let raw = try optionalString(name) else { return nil }
        return try DateParsing.parse(raw, argument: name, calendar: calendar)
    }

    /// `from_date` and `to_date`, both inclusive: the range starts where `from_date` starts
    /// and ends where the precision `to_date` was written in ends, so "to 2026-08-12"
    /// includes all of that day. `before` is that end, the first instant left out.
    public func dateRange() throws -> (from: Date?, before: Date?) {
        let from = try optionalDate("from_date")
        let to = try optionalDate("to_date")
        if let from, let to, to.end <= from.date { throw ToolError.rangeInverted }
        return (from?.date, to?.end)
    }

    // MARK: Choices

    /// Media kinds by name. Unknown names are refused rather than ignored: a filter that
    /// silently drops the one term the caller cared about returns a confident wrong answer.
    public func mediaKinds(_ name: String) throws -> [MediaKind] {
        try stringArray(name).map { raw in
            guard let kind = MediaKind(rawValue: raw.lowercased()) else {
                throw ToolError.badArgument(
                    name: name,
                    reason:
                        "\"\(ToolStandard.echo(raw))\" is not a media kind; expected one of "
                        + MediaKind.allCases.map(\.rawValue).joined(separator: ", "))
            }
            return kind
        }
    }

    public func chatKinds(_ name: String) throws -> [ChatKind] {
        try stringArray(name).map { raw in
            guard let kind = ChatKind(rawValue: raw.lowercased()), kind != .unknown else {
                throw ToolError.badArgument(
                    name: name,
                    reason:
                        "\"\(ToolStandard.echo(raw))\" is not a chat kind; expected one of "
                        + ChatKind.allCases.filter { $0 != .unknown }.map(\.rawValue)
                        .joined(separator: ", "))
            }
            return kind
        }
    }

    /// `order` is `newest` or `oldest`. Newest first by default, because a conversation
    /// is read from its end.
    public func newestFirst() throws -> Bool {
        guard let raw = try optionalString("order") else { return true }
        switch raw.lowercased() {
        case "newest": return true
        case "oldest": return false
        default:
            throw ToolError.badArgument(
                name: "order",
                reason: "expected \"newest\" or \"oldest\", got \"\(ToolStandard.echo(raw))\"")
        }
    }
}
