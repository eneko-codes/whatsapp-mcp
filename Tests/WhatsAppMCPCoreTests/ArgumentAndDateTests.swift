import Foundation
import Testing

@testable import WhatsAppMCPCore

@Suite("Strict arguments and dates")
struct ArgumentAndDateTests {

    private let madrid: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }()

    private func parse(_ text: String) throws -> Date {
        try DateParsing.parse(text, argument: "from_date", calendar: madrid).date
    }

    // MARK: Dates

    @Test("A day that does not exist is refused, never moved to another one")
    func impossibleDaysAreRefused() {
        for text in [
            "2026-02-30", "2026-02-31", "2026-04-31", "2025-02-29", "2100-02-29",
            "2026-02-30T10:00", "2026-04-31T23:59:59", "0000-01-01", "1899-12-31", "2201-01-01",
            // The offset and Z forms go through a different, equally lenient parser.
            "2026-02-30T09:00:00+02:00", "2026-04-31T09:00:00Z", "2025-02-29T00:00:00+01:00",
            "0000-01-01T00:00:00Z", "1899-12-31T23:00:00Z", "2026-13-01T00:00:00Z",
        ] {
            #expect(throws: ToolError.badDate(argument: "from_date", value: text), "\(text)") {
                try parse(text)
            }
        }
    }

    @Test("A real day is accepted, including a leap day")
    func realDaysAreAccepted() throws {
        let leap = try parse("2024-02-29")
        #expect(madrid.dateComponents([.month, .day], from: leap).day == 29)
        _ = try parse("2026-12-31T23:59")
        _ = try parse("1900-01-01")
        _ = try parse("2024-02-29T12:00:00+01:00")
        _ = try parse("2026-12-31T23:59:59Z")
    }

    @Test("A zone that goes back by thirty minutes is ambiguous too, and says which half-hour it is")
    func halfHourFallBack() throws {
        var lordHowe = Calendar(identifier: .gregorian)
        lordHowe.timeZone = TimeZone(identifier: "Australia/Lord_Howe")!
        let first = try DateParsing.parse("2026-04-04T14:45:00Z", argument: "from_date", calendar: lordHowe).date
        let second = try DateParsing.parse("2026-04-04T15:15:00Z", argument: "from_date", calendar: lordHowe).date
        let firstText = DateParsing.roundTrip(first, calendar: lordHowe)
        let secondText = DateParsing.roundTrip(second, calendar: lordHowe)
        #expect(firstText != secondText, "\(firstText)")
        #expect(firstText.contains("+") && secondText.contains("+"))
        #expect(try DateParsing.parse(firstText, argument: "from_date", calendar: lordHowe).date == first)
        #expect(try DateParsing.parse(secondText, argument: "from_date", calendar: lordHowe).date == second)
        let ordinary = try DateParsing.parse("2026-04-05T10:00", argument: "from_date", calendar: lordHowe).date
        #expect(DateParsing.roundTrip(ordinary, calendar: lordHowe) == "2026-04-05T10:00")
    }

    @Test("A local time that the spring clock change skips is refused, and its day is not")
    func springGapIsRefused() throws {
        #expect(throws: ToolError.badDate(argument: "from_date", value: "2026-03-29T02:30")) {
            try parse("2026-03-29T02:30")
        }
        let day = try DateParsing.parse("2026-03-29", argument: "from_date", calendar: madrid)
        // A day that loses an hour is 23 hours long, and to_date covers all of it.
        #expect(day.end.timeIntervalSince(day.date) == 23 * 3600)
    }

    @Test("to_date is inclusive at the precision it was written in")
    func toDateIsInclusive() throws {
        let day = try DateParsing.parse("2026-08-12", argument: "to_date", calendar: madrid)
        #expect(day.end == Fixtures.date(2026, 8, 13))
        let minute = try DateParsing.parse("2026-08-12T09:00", argument: "to_date", calendar: madrid)
        #expect(minute.end.timeIntervalSince(minute.date) == 60)
        let second = try DateParsing.parse(
            "2026-08-12T09:00:05", argument: "to_date", calendar: madrid)
        #expect(second.end.timeIntervalSince(second.date) == 1)
        let explicit = try DateParsing.parse(
            "2026-08-12T09:00:00+02:00", argument: "to_date", calendar: madrid)
        #expect(explicit.end.timeIntervalSince(explicit.date) == 1)

        let range = try arguments(["from_date": .string("2026-08-12"), "to_date": .string("2026-08-12")])
            .dateRange()
        #expect(range.from == Fixtures.date(2026, 8, 12) && range.before == Fixtures.date(2026, 8, 13))
        #expect(throws: ToolError.rangeInverted) {
            try arguments(["from_date": .string("2026-08-12"), "to_date": .string("2026-08-11")])
                .dateRange()
        }
    }

    @Test("In the hour the clocks go back, a printed time says which of the two it was")
    func ambiguousHourCarriesItsOffset() throws {
        let first = try parse("2026-10-25T02:30:00+02:00")  // still summer time
        let second = try parse("2026-10-25T02:30:00+01:00")  // after the change
        #expect(first != second)

        let firstText = DateParsing.roundTrip(first, calendar: madrid)
        let secondText = DateParsing.roundTrip(second, calendar: madrid)
        #expect(firstText == "2026-10-25T02:30:00+02:00")
        #expect(secondText == "2026-10-25T02:30:00+01:00")
        // Pasting either back lands on the same instant, which the plain form could not do.
        #expect(try parse(firstText) == first)
        #expect(try parse(secondText) == second)
        #expect(DateParsing.stamp(second, calendar: madrid).hasSuffix("(+01:00)"))
    }

    @Test("Every other time keeps the short form, so ordinary output does not change")
    func ordinaryTimesStayShort() throws {
        for text in ["2026-08-12T09:00", "2026-10-25T04:30", "2026-10-25T01:59", "2026-01-01T00:00"] {
            let moment = try parse(text)
            #expect(DateParsing.roundTrip(moment, calendar: madrid) == text)
        }
    }

    // MARK: Booleans

    private func arguments(_ values: [String: Value]) -> Arguments {
        Arguments(values, calendar: madrid)
    }

    @Test("A boolean argument is a boolean or an error, never text that looks like one")
    func booleansAreStrict() throws {
        #expect(try arguments(["from_me": .bool(true)]).optionalBool("from_me") == true)
        #expect(try arguments(["from_me": .bool(false)]).optionalBool("from_me") == false)
        #expect(try arguments([:]).optionalBool("from_me") == nil)
        // JSON null means "not set". An empty string does not: it is a filter that got lost.
        #expect(try arguments(["from_me": .null]).optionalBool("from_me") == nil)
        #expect(try arguments(["starred_only": .null]).bool("starred_only") == false)
        #expect(try arguments([:]).bool("starred_only") == false)

        for wrong: Value in [
            .string("yes"), .string("1"), .string(""), .string("   "), .string("true"), .int(1),
            .double(0.5), .array([]),
        ] {
            #expect(throws: ToolError.self, "\(wrong)") {
                _ = try arguments(["from_me": wrong]).optionalBool("from_me")
            }
        }
    }

    @Test("A mistyped filter fails the call instead of widening the answer")
    func mistypedFilterFailsTheCall() async {
        let store = FakeWhatsAppStore()
        store.chatsValue = [Fixtures.chat(id: 1, name: "Ane")]
        store.messagesValue = [
            Fixtures.message(id: 10, chatID: 1, chatName: "Ane", text: "mine", fromMe: true),
            Fixtures.message(id: 11, chatID: 1, chatName: "Ane", text: "theirs"),
        ]
        let tools = WhatsAppTools(store: store, calendar: Fixtures.calendar)

        func run(_ arguments: [String: Value]) async -> (String, Bool) {
            let result = await tools.handle(.init(name: ToolCatalog.chatGetName, arguments: arguments))
            guard case .text(let text) = result.content.first else { return ("", true) }
            return (text, result.isError)
        }

        func runChats(_ arguments: [String: Value]) async -> (String, Bool) {
            let result = await tools.handle(.init(name: ToolCatalog.chatsName, arguments: arguments))
            guard case .text(let text) = result.content.first else { return ("", true) }
            return (text, result.isError)
        }

        let (typo, typoError) = await run(["chat_id": .int(1), "from_me": .string("maybe")])
        #expect(typoError)
        #expect(typo.contains("from_me"))
        let (starred, starredError) = await run(["chat_id": .int(1), "starred_only": .string("yes")])
        #expect(starredError, Comment(rawValue: starred))

        for filter in ["include_archived", "include_hidden"] {
            let (text, isError) = await runChats([filter: .string("maybe")])
            #expect(isError, Comment(rawValue: "\(filter): \(text)"))
            #expect(text.contains(filter))
        }

        let (mine, mineError) = await run(["chat_id": .int(1), "from_me": .bool(true)])
        #expect(!mineError)
        #expect(mine.contains("mine") && !mine.contains("theirs"))
    }
}
