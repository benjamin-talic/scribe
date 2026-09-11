import AppKit
import Testing
@testable import Scribe

@MainActor
struct MeetingNotificationsTests {
    @Test
    func offersAreVisibleNonactivatingAndDismissedIndependently() throws {
        _ = NSApplication.shared
        let notifications = MeetingNotifications()
        let zoom = MeetingApplication(bundleID: "test.zoom", name: "Test Zoom")
        let arc = MeetingApplication(bundleID: "test.arc", name: "Test Arc")
        defer { notifications.clearOffers() }

        notifications.offerRecording(for: zoom)
        notifications.offerRecording(for: zoom)
        notifications.offerRecording(for: arc)
        let panels = NSApp.windows.filter { $0.isVisible && $0.title.hasPrefix("Scribe — Meeting detected in Test") }
        try #require(panels.count == 2)
        #expect(panels.allSatisfy { $0.styleMask.contains(.nonactivatingPanel) && $0.level == .floating })
        #expect(panels.allSatisfy { $0.frame.width == 360 && $0.frame.height > 100 })
        #expect(!panels[0].frame.intersects(panels[1].frame))

        if let path = ProcessInfo.processInfo.environment["SCRIBE_TOAST_SCREENSHOT"] {
            let view = try #require(panels[0].contentView)
            view.display()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(filePath: path))
        }

        notifications.clearOffer(for: zoom)
        #expect(panels.filter(\.isVisible).count == 1)
        notifications.clearOffers()
        #expect(panels.allSatisfy { !$0.isVisible })
    }
}
