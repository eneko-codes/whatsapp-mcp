import Foundation

/// Parsing and rendering of the three date forms this server accepts.
///
/// Deliberately strict. A lenient parser that guesses at `10/08/2026` will one day read
/// it as 8 October for a caller who meant 10 August, and a search that silently answers
/// about the wrong two months is worse than one that refuses the input.
public enum DateParsing {

    public static let acceptedForms = """
        - 2026-08-12                  midnight local time
        - 2026-08-12T09:00            local time
        - 2026-08-12T09:00:00+02:00   explicit offset
        """

    public static func parse(_ raw: String, argument: String, calendar: Calendar) throws -> Date {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let components = dayComponents(text) {
            guard let day = calendar.date(from: components), sameDay(day, components, calendar)
            else { throw ToolError.badDate(argument: argument, value: text) }
            return calendar.startOfDay(for: day)
        }

        if let components = localComponents(text) {
            guard let moment = calendar.date(from: components),
                sameDay(moment, components, calendar)
            else { throw ToolError.badDate(argument: argument, value: text) }
            return moment
        }

        // Only reached for a string carrying its own offset or Z suffix, where the
        // machine's time zone is irrelevant.
        let optionSets: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime],
            [.withInternetDateTime, .withFractionalSeconds],
        ]
        for options in optionSets {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            // ISO8601DateFormatter is as lenient as Calendar: 2026-02-30T09:00:00+02:00 is 2
            // March. The day the string names must be a real one, whatever its offset.
            if let moment = formatter.date(from: text), namesARealDay(text) { return moment }
        }

        throw ToolError.badDate(argument: argument, value: text)
    }

    /// `Calendar.date(from:)` is lenient: 2026-02-30 becomes 2 March and nothing says so, so
    /// the caller reads an answer about a range they did not ask for. Reading the date back
    /// and comparing it to what was typed refuses every day that does not exist. Only the
    /// day is compared, not the hour: a local time that falls in a spring-forward gap does
    /// not exist either, and moving it to the next valid minute is the one adjustment that
    /// is both unambiguous and what the clock on the wall did.
    private static func sameDay(_ date: Date, _ components: DateComponents, _ calendar: Calendar)
        -> Bool
    {
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == components.year && back.month == components.month
            && back.day == components.day
    }

    /// The leading `YYYY-MM-DD` of an offset-bearing timestamp exists in the Gregorian
    /// calendar, and its year is one the server accepts.
    private static func namesARealDay(_ text: String) -> Bool {
        guard text.count >= 10, let components = dayComponents(String(text.prefix(10))) else {
            return false
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let day = utc.date(from: components) else { return false }
        return sameDay(day, components, utc)
    }

    /// `YYYY-MM-DD` and nothing else.
    private static func dayComponents(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            (1900...2200).contains(year), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    /// `YYYY-MM-DDTHH:MM` or `YYYY-MM-DDTHH:MM:SS`, with no offset suffix.
    private static func localComponents(_ text: String) -> DateComponents? {
        let halves = text.split(separator: "T", omittingEmptySubsequences: false)
        guard halves.count == 2, var day = dayComponents(String(halves[0])) else { return nil }

        let time = halves[1]
        // A trailing Z or offset means the string is absolute; that is the ISO path.
        guard !time.contains("Z"), !time.contains("+"), time.filter({ $0 == "-" }).isEmpty
        else { return nil }

        let pieces = time.split(separator: ":")
        guard (2...3).contains(pieces.count), pieces.allSatisfy({ $0.count == 2 }),
            let hour = Int(pieces[0]), let minute = Int(pieces[1]),
            (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        let second = pieces.count == 3 ? Int(pieces[2]) : 0
        guard let second, (0...59).contains(second) else { return nil }

        day.hour = hour
        day.minute = minute
        day.second = second
        return day
    }

    // MARK: Rendering

    /// `2026-08-12 09:30`, in local time.
    ///
    /// Hand-rolled rather than `DateFormatter` so output does not change shape with the
    /// machine's locale, and numeric throughout so no reader has to know whether `ago` is
    /// August or a typo.
    public static func stamp(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let text = String(
            format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0,
            parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
        return isAmbiguousLocalTime(date, calendar: calendar)
            ? text + " (" + offsetText(date, calendar: calendar) + ")" : text
    }

    /// `2026-08-12T09:00` — the form the tools accept, so an echoed bound can be pasted
    /// straight back into the next call.
    ///
    /// In the one hour a year when the clocks go back, the same wall-clock time happens
    /// twice and the plain form cannot say which. Pasting it back would land an hour early
    /// or late and page across that hour would duplicate or skip messages, so those times
    /// alone carry their offset (and seconds, which the offset form requires).
    public static func roundTrip(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        if isAmbiguousLocalTime(date, calendar: calendar) {
            return String(
                format: "%04d-%02d-%02dT%02d:%02d:%02d%@", parts.year ?? 0, parts.month ?? 0,
                parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
                offsetText(date, calendar: calendar))
        }
        return String(
            format: "%04d-%02d-%02dT%02d:%02d", parts.year ?? 0, parts.month ?? 0,
            parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }

    /// True when another instant shows the same local day and clock time — which happens
    /// only when the zone's offset drops (clocks go back), by one hour in most zones and by
    /// thirty minutes in Lord Howe. The candidates are the instants the zone's offsets a day
    /// either side would give the same wall clock; each is checked.
    static func isAmbiguousLocalTime(_ date: Date, calendar: Calendar) -> Bool {
        let zone = calendar.timeZone
        func wallClock(_ moment: Date) -> DateComponents {
            calendar.dateComponents([.year, .month, .day, .hour, .minute], from: moment)
        }
        let here = wallClock(date)
        let current = zone.secondsFromGMT(for: date)
        let offsets = Set([
            zone.secondsFromGMT(for: date.addingTimeInterval(-86_400)),
            zone.secondsFromGMT(for: date.addingTimeInterval(86_400)), current,
        ])
        for offset in offsets where offset != current {
            let other = date.addingTimeInterval(TimeInterval(current - offset))
            if zone.secondsFromGMT(for: other) == offset, wallClock(other) == here { return true }
        }
        return false
    }

    static func offsetText(_ date: Date, calendar: Calendar) -> String {
        let seconds = calendar.timeZone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        return String(format: "%@%02d:%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
    }
}
