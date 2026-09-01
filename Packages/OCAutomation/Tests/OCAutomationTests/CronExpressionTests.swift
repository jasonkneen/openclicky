import XCTest
@testable import OCAutomation

/// The evaluator uses `Calendar(identifier: .gregorian)` in the current time
/// zone, so every fixture here is built with the same calendar. Dates are
/// chosen in January/February to stay clear of DST transitions.
final class CronExpressionTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    private func comps(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
    }

    // MARK: Parsing

    func testParsesWildcardsAndSteps() throws {
        let c = try XCTUnwrap(CronExpression("*/15 * * * *"))
        XCTAssertEqual(c.minutes, [0, 15, 30, 45])
        XCTAssertEqual(c.hours.count, 24)
        XCTAssertEqual(c.days.count, 31)
        XCTAssertEqual(c.months.count, 12)
        XCTAssertEqual(c.weekdays.count, 7)
    }

    func testParsesNamedMonthsAndWeekdays() throws {
        XCTAssertEqual(try XCTUnwrap(CronExpression("0 0 * JAN,JUL *")).months, [1, 7])
        XCTAssertEqual(try XCTUnwrap(CronExpression("0 9 * * MON")).weekdays, [2])
        XCTAssertEqual(try XCTUnwrap(CronExpression("0 9 * * mon-fri")).weekdays, [2, 3, 4, 5, 6])
    }

    func testSundayAliasesToCalendarWeekdayOne() throws {
        XCTAssertEqual(try XCTUnwrap(CronExpression("0 0 * * 0")).weekdays, [1])
        XCTAssertEqual(try XCTUnwrap(CronExpression("0 0 * * 7")).weekdays, [1])
        XCTAssertEqual(try XCTUnwrap(CronExpression("0 0 * * SUN")).weekdays, [1])
    }

    func testParsesListsAndRangesWithSteps() throws {
        let c = try XCTUnwrap(CronExpression("1,2,3 8-17/3 1-5 * *"))
        XCTAssertEqual(c.minutes, [1, 2, 3])
        XCTAssertEqual(c.hours, [8, 11, 14, 17])
        XCTAssertEqual(c.days, [1, 2, 3, 4, 5])
    }

    func testRejectsMalformedExpressions() {
        let bad = [
            "* * * *",          // 4 fields
            "* * * * * *",      // 6 fields
            "60 * * * *",       // minute out of range
            "* 24 * * *",       // hour out of range
            "* * 0 * *",        // day-of-month below range
            "* * 32 * *",       // day-of-month above range
            "* * * 13 *",       // month out of range
            "* * * * 8",        // weekday out of range
            "*/0 * * * *",      // zero step
            "5-1 * * * *",      // inverted range
            "x * * * *",        // unknown token
            "* * * FOO *",      // unknown month name
            "",                 // empty
        ]
        for expr in bad {
            XCTAssertNil(CronExpression(expr), "expected nil for \(expr.debugDescription)")
        }
    }

    // MARK: Day matching (Vixie semantics, M12)

    func testBothRestricted_FiresOnDayOfMonthArm() throws {
        // 2026-01-01 is a Thursday; pre-M12 AND semantics would have skipped it.
        let c = try XCTUnwrap(CronExpression("0 0 1 * 1"))
        let next = try XCTUnwrap(c.nextFireDate(after: date(2025, 12, 31, 12, 0)))
        let k = comps(next)
        XCTAssertEqual([k.year, k.month, k.day, k.hour, k.minute], [2026, 1, 1, 0, 0])
    }

    func testBothRestricted_FiresOnWeekdayArm() throws {
        // From just after Monday 2026-01-05 00:00 the next hit is Monday the 12th, not Feb 1st.
        let c = try XCTUnwrap(CronExpression("0 0 1 * 1"))
        let next = try XCTUnwrap(c.nextFireDate(after: date(2026, 1, 5, 0, 1)))
        let k = comps(next)
        XCTAssertEqual([k.year, k.month, k.day, k.hour, k.minute], [2026, 1, 12, 0, 0])
        XCTAssertEqual(k.weekday, 2)
    }

    func testOnlyDayOfMonthRestricted() throws {
        let c = try XCTUnwrap(CronExpression("0 0 1 * *"))
        let next = try XCTUnwrap(c.nextFireDate(after: date(2026, 1, 2)))
        let k = comps(next)
        XCTAssertEqual([k.year, k.month, k.day, k.hour, k.minute], [2026, 2, 1, 0, 0])
    }

    func testOnlyWeekdayRestricted() throws {
        let c = try XCTUnwrap(CronExpression("0 0 * * 1"))
        let next = try XCTUnwrap(c.nextFireDate(after: date(2026, 1, 1)))
        let k = comps(next)
        XCTAssertEqual([k.year, k.month, k.day], [2026, 1, 5])
        XCTAssertEqual(k.weekday, 2)
    }

    func testExplicitFullDayRangeIsTreatedAsUnrestricted() throws {
        // Documented divergence from Vixie: "1-31" yields days.count == 31, so the
        // evaluator treats day-of-month as unrestricted and ANDs with the weekday.
        // This locks CURRENT behavior so a change is deliberate, not accidental.
        let c = try XCTUnwrap(CronExpression("0 0 1-31 * 1"))
        let next = try XCTUnwrap(c.nextFireDate(after: date(2026, 1, 1)))
        XCTAssertEqual(comps(next).weekday, 2)
        XCTAssertEqual(comps(next).day, 5)
    }

    func testReturnsNilWhenNoMatchWithinAYear() throws {
        let c = try XCTUnwrap(CronExpression("0 0 30 2 *"))
        XCTAssertNil(c.nextFireDate(after: date(2026, 1, 1)))
    }

    func testNextFireIsStrictlyAfterReference() throws {
        let c = try XCTUnwrap(CronExpression("0 9 * * *"))
        let next = try XCTUnwrap(c.nextFireDate(after: date(2026, 1, 1, 9, 0)))
        let k = comps(next)
        XCTAssertEqual([k.year, k.month, k.day, k.hour, k.minute], [2026, 1, 2, 9, 0])
    }

    // MARK: Seconds handling

    func testReferenceWithNonZeroSecondsRoundsToNextWholeMinute() throws {
        // `date(bySetting: .second, value: 0)` is a FORWARD search in Foundation,
        // so from 12:00:30 the evaluator currently lands on 12:02 rather than 12:01.
        // The production store ticks on a 30s timer with arbitrary wall-clock
        // seconds, so this skips a real fire. Expected to fail until fixed.
        XCTExpectFailure("nextFireDate skips a minute when the reference has non-zero seconds")
        let c = try XCTUnwrap(CronExpression("* * * * *"))
        let next = try XCTUnwrap(c.nextFireDate(after: date(2026, 1, 1, 12, 0, 30)))
        let k = comps(next)
        XCTAssertEqual([k.hour, k.minute, k.second], [12, 1, 0])
    }

    func testReferenceWithNonZeroSecondsDoesNotMissADailyFire() throws {
        XCTExpectFailure("nextFireDate misses a whole day when the reference has non-zero seconds")
        let c = try XCTUnwrap(CronExpression("1 12 * * *"))
        let next = try XCTUnwrap(c.nextFireDate(after: date(2026, 1, 1, 12, 0, 30)))
        let k = comps(next)
        XCTAssertEqual([k.year, k.month, k.day, k.hour, k.minute], [2026, 1, 1, 12, 1])
    }

    func testReferenceOnWholeMinuteIsUnaffected() throws {
        let c = try XCTUnwrap(CronExpression("* * * * *"))
        let next = try XCTUnwrap(c.nextFireDate(after: date(2026, 1, 1, 12, 0, 0)))
        let k = comps(next)
        XCTAssertEqual([k.hour, k.minute, k.second], [12, 1, 0])
    }
}
