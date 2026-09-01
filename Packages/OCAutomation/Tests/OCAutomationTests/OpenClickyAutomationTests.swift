import XCTest
@testable import OCAutomation

final class OpenClickyAutomationTests: XCTestCase {
    // MARK: Schedule

    func testScheduleDisplayString() {
        XCTAssertEqual(OpenClickyAutomationSchedule.interval(seconds: 1800).displayString, "every 30m")
        XCTAssertEqual(OpenClickyAutomationSchedule.interval(seconds: 7200).displayString, "every 2h")
        XCTAssertEqual(OpenClickyAutomationSchedule.interval(seconds: 5400).displayString, "every 1h 30m")
        // Sub-minute intervals truncate to 0m; locked as current behavior.
        XCTAssertEqual(OpenClickyAutomationSchedule.interval(seconds: 30).displayString, "every 0m")
        XCTAssertEqual(OpenClickyAutomationSchedule.cron("0 9 * * *").displayString, "cron 0 9 * * *")
    }

    func testScheduleCodableRoundTrip() throws {
        for schedule in [OpenClickyAutomationSchedule.interval(seconds: 900), .cron("*/5 * * * *")] {
            let data = try JSONEncoder().encode(schedule)
            XCTAssertEqual(try JSONDecoder().decode(OpenClickyAutomationSchedule.self, from: data), schedule)
        }
    }

    func testScheduleEncodesKindAndValueKeys() throws {
        let data = try JSONEncoder().encode(OpenClickyAutomationSchedule.cron("0 9 * * MON"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "cron")
        XCTAssertEqual(object["value"] as? String, "0 9 * * MON")
    }

    func testScheduleDecodingUnknownKindThrows() {
        let data = Data(#"{"kind":"weekly","value":"x"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(OpenClickyAutomationSchedule.self, from: data)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
        }
    }

    // MARK: Automation

    func testAutomationCodableRoundTrip() throws {
        let original = OpenClickyAutomation(
            name: "Morning brief",
            schedule: .cron("0 9 * * MON-FRI"),
            prompt: "Summarise overnight activity",
            agentSlug: "researcher",
            enabled: false,
            lastRun: Date(timeIntervalSince1970: 1_700_000_000),
            nextRun: Date(timeIntervalSince1970: 1_700_003_600)
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(OpenClickyAutomation.self, from: data), original)
    }

    func testAutomationDefaultsAreEnabledWithNoAgentOrRuns() {
        let a = OpenClickyAutomation(name: "x", schedule: .interval(seconds: 60), prompt: "p")
        XCTAssertTrue(a.enabled)
        XCTAssertNil(a.agentSlug)
        XCTAssertNil(a.lastRun)
        XCTAssertNil(a.nextRun)
    }

    func testDecodesLegacyPayloadWithoutOptionalFields() throws {
        // Older on-disk automations predate agentSlug/lastRun/nextRun.
        let json = """
        {"id":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8","name":"n","prompt":"p","enabled":true,
         "schedule":{"kind":"interval","value":300}}
        """
        let a = try JSONDecoder().decode(OpenClickyAutomation.self, from: Data(json.utf8))
        XCTAssertEqual(a.name, "n")
        XCTAssertEqual(a.schedule, .interval(seconds: 300))
        XCTAssertNil(a.agentSlug)
        XCTAssertNil(a.nextRun)
    }

    // MARK: computingNextRun — interval branch

    func testIntervalWithNoLastRunSchedulesFromReference() {
        let ref = Date(timeIntervalSince1970: 1_000_000)
        let a = OpenClickyAutomation(name: "x", schedule: .interval(seconds: 600), prompt: "p")
        XCTAssertEqual(a.computingNextRun(after: ref), ref.addingTimeInterval(600))
    }

    func testIntervalWithRecentLastRunSchedulesFromLastRun() {
        let ref = Date(timeIntervalSince1970: 1_000_000)
        let a = OpenClickyAutomation(name: "x", schedule: .interval(seconds: 600), prompt: "p",
                                     lastRun: ref.addingTimeInterval(-100))
        XCTAssertEqual(a.computingNextRun(after: ref), ref.addingTimeInterval(500))
    }

    func testIntervalWithStaleLastRunSchedulesFromReference() {
        let ref = Date(timeIntervalSince1970: 1_000_000)
        let a = OpenClickyAutomation(name: "x", schedule: .interval(seconds: 600), prompt: "p",
                                     lastRun: ref.addingTimeInterval(-5000))
        XCTAssertEqual(a.computingNextRun(after: ref), ref.addingTimeInterval(600))
    }

    // MARK: computingNextRun — cron branch

    func testCronBranchDelegatesToCronExpression() throws {
        let cal = Calendar(identifier: .gregorian)
        let ref = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 8, minute: 0))!
        let a = OpenClickyAutomation(name: "x", schedule: .cron("0 9 * * *"), prompt: "p")
        let next = try XCTUnwrap(a.computingNextRun(after: ref))
        let k = cal.dateComponents([.day, .hour, .minute], from: next)
        XCTAssertEqual([k.day, k.hour, k.minute], [1, 9, 0])
    }

    func testInvalidCronYieldsNilNextRun() {
        let a = OpenClickyAutomation(name: "x", schedule: .cron("not a cron"), prompt: "p")
        XCTAssertNil(a.computingNextRun(after: Date(timeIntervalSince1970: 0)))
    }
}
