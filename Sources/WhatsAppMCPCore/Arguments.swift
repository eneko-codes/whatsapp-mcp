import Foundation
import MCP

/// Typed access to a `tools/call` argument bag.
///
/// Nothing here has a "clear this field" affordance, unlike the sibling servers: every
/// tool on this server is a read, so no argument ever names a field to be emptied. An
/// absent key simply means the filter is not applied.
public struct Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    // MARK: Scalars

    public func requiredString(_ name: String) throws -> String {
        guard let raw = values[name]?.stringValue else { throw ToolError.missingArgument(name) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    public func optionalString(_ name: String) -> String? {
        guard let text = values[name]?.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func bool(_ name: String, default fallback: Bool = false) -> Bool {
        values[name]?.boolValue ?? fallback
    }

    /// Nil when absent, which is what separates "only messages I sent" from "any
    /// message". A tri-state has to stay a tri-state.
    public func optionalBool(_ name: String) -> Bool? {
        values[name]?.boolValue
    }

    public func requiredInt(_ name: String) throws -> Int64 {
        guard let raw = values[name] else { throw ToolError.missingArgument(name) }
        if let number = raw.intValue { return Int64(number) }
        // Ids travel through JSON and come back as strings often enough that rejecting
        // "42" would be a pointless round trip.
        if let text = raw.stringValue, let number = Int64(text) { return number }
        throw ToolError.badArgument(name: name, reason: "an integer id was expected")
    }

    /// Nil when absent, for an id that narrows a search rather than naming its subject.
    ///
    /// Accepts a number or a numeric string for the same reason `requiredInt` does. Reading
    /// such an id as a string only would silently drop it — the schema declares these as
    /// numbers, so the filter would never be applied and the answer would look like an
    /// unfiltered search that simply found more than expected.
    public func optionalInt(_ name: String) throws -> Int64? {
        guard let raw = values[name] else { return nil }
        if let number = raw.intValue { return Int64(number) }
        if let text = raw.stringValue {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if let number = Int64(trimmed) { return number }
        }
        throw ToolError.badArgument(name: name, reason: "an integer id was expected")
    }

    /// Clamps rather than rejects: a model asking for 500 results means "as many as you
    /// will give me".
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = values[name] else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return Swift.min(Swift.max(number, range.lowerBound), range.upperBound)
    }

    public func stringArray(_ name: String) throws -> [String] {
        guard let raw = values[name] else { return [] }
        if case .null = raw { return [] }
        // A single string where an array is expected is a common and harmless slip.
        if let single = raw.stringValue {
            let trimmed = single.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        guard let entries = raw.arrayValue else {
            throw ToolError.badArgument(name: name, reason: "an array of strings was expected")
        }
        return entries.compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: Dates

    public func optionalDate(_ name: String) throws -> Date? {
        guard let raw = optionalString(name) else { return nil }
        return try DateParsing.parse(raw, argument: name, calendar: calendar)
    }

    // MARK: Enumerations

    /// Media kinds by name. Unknown names are refused rather than ignored: a filter that
    /// silently drops the one term the caller cared about returns a confident wrong answer.
    public func mediaKinds(_ name: String) throws -> [MediaKind] {
        try stringArray(name).map { raw in
            guard let kind = MediaKind(rawValue: raw.lowercased()) else {
                throw ToolError.badArgument(
                    name: name,
                    reason:
                        "\"\(raw)\" is not a media kind; expected one of "
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
                        "\"\(raw)\" is not a chat kind; expected one of "
                        + ChatKind.allCases.filter { $0 != .unknown }.map(\.rawValue)
                        .joined(separator: ", "))
            }
            return kind
        }
    }

    // MARK: Ordering

    /// `order` is `newest` or `oldest`. Newest first by default, because a conversation
    /// is read from its end.
    public func newestFirst() throws -> Bool {
        guard let raw = optionalString("order") else { return true }
        switch raw.lowercased() {
        case "newest": return true
        case "oldest": return false
        default:
            throw ToolError.badArgument(
                name: "order", reason: "expected \"newest\" or \"oldest\", got \"\(raw)\"")
        }
    }
}
