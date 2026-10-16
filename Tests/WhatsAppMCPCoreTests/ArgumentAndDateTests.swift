import Foundation
import MCP
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
        try DateParsing.parse(text, argument: "after", calendar: madrid)
    }

    // MARK: Dates

    @Test("A day that does not exist is refused, never moved to another one")
    func impossibleDaysAreRefused() {
        for text in [
            "2026-02-30", "2026-02-31", "2026-04-31", "2025-02-29", "2100-02-29",
            "2026-02-30T10:00", "2026-04-31T23:59:59", "0000-01-01", "1899-12-31", "2201-01-01",
        ] {
            #expect(throws: ToolError.badDate(argument: "after", value: text), "\(text)") {
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
    }

    @Test("A local time that the spring clock change skips moves to the next valid minute")
    func springGapStaysOnTheSameDay() throws {
        let moment = try parse("2026-03-29T02:30")
        let parts = madrid.dateComponents([.month, .day, .hour], from: moment)
        #expect(parts.month == 3 && parts.day == 29 && parts.hour == 3)
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

    @Test("A boolean argument is a boolean, or the strings true and false, or an error")
    func booleansAreStrict() throws {
        #expect(try arguments(["from_me": .bool(true)]).optionalBool("from_me") == true)
        #expect(try arguments(["from_me": .string("TRUE")]).optionalBool("from_me") == true)
        #expect(try arguments(["from_me": .string(" false ")]).optionalBool("from_me") == false)
        #expect(try arguments([:]).optionalBool("from_me") == nil)
        #expect(try arguments(["from_me": .string("")]).optionalBool("from_me") == nil)
        #expect(try arguments([:]).bool("starred_only") == false)

        for wrong: Value in [.string("yes"), .string("1"), .int(1), .double(0.5), .null, .array([])] {
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
            guard case .text(let text, _, _) = result.content.first else { return ("", true) }
            return (text, result.isError ?? false)
        }

        let (typo, typoError) = await run(["chat_id": .int(1), "from_me": .string("maybe")])
        #expect(typoError)
        #expect(typo.contains("from_me"))
        let (starred, starredError) = await run(["chat_id": .int(1), "starred_only": .string("yes")])
        #expect(starredError, Comment(rawValue: starred))

        // The string form of a real boolean still filters.
        let (mine, mineError) = await run(["chat_id": .int(1), "from_me": .string("true")])
        #expect(!mineError)
        #expect(mine.contains("mine") && !mine.contains("theirs"))
    }
}
