import Testing
@testable import Scribe

struct MeetingDetectionTests {
    @Test
    func defaultApplicationsIncludeZoomAndArc() {
        #expect(MeetingApplication.defaults.map(\.bundleID).contains("us.zoom.xos"))
        #expect(MeetingApplication.defaults.map(\.bundleID).contains("company.thebrowser.Browser"))
    }

    @Test
    func helperBundleIDsMatchTheirConfiguredApplication() {
        let match = MeetingApplication.matching(
            "company.thebrowser.Browser.helper.GPU",
            in: MeetingApplication.defaults
        )

        #expect(match?.name == "Arc")
    }

    @MainActor
    @Test
    func detectorEmitsOncePerCycleAndCancelsTransientStops() async {
        let zoom = MeetingApplication(bundleID: "us.zoom.xos", name: "Zoom")
        var observed: Set<MeetingApplication> = [zoom]
        var events: [MeetingEvent] = []
        let detector = MeetingDetector(stopDelay: .milliseconds(20)) { observed }
        detector.onEvent = { events.append($0) }

        detector.refresh()
        detector.refresh()
        observed = []
        detector.refresh()
        observed = [zoom]
        detector.refresh()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(events == [.started(zoom)])

        observed = []
        detector.refresh()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while events.count < 2 && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(events == [.started(zoom), .ended(zoom)])
    }

    @MainActor
    @Test
    func coreAudioProcessPropertiesCanBeRead() throws {
        _ = try CoreAudioMicScanner().activeApplications(from: MeetingApplication.defaults)
    }
}
