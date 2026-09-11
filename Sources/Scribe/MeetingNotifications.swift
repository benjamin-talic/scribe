import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class MeetingNotifications {
    private var panels: [MeetingApplication: NSPanel] = [:]

    var onStart: ((MeetingApplication) async -> Void)?

    func configure() {
        // Remove banners left over from the system-notification implementation.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    func offerRecording(for application: MeetingApplication) {
        guard panels[application] == nil else { return }
        let panel = MeetingToastPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.title = "Scribe — Meeting detected in \(application.name)"
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let view = NSHostingView(rootView: MeetingToast(
            application: application,
            start: { [weak self] in
                self?.clearOffers()
                Task { await self?.onStart?(application) }
            },
            dismiss: { [weak self] in self?.clearOffer(for: application) }
        ))
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        panels[application] = panel
        positionOffers()
        panel.orderFrontRegardless()
    }

    func clearOffer(for application: MeetingApplication) {
        panels.removeValue(forKey: application)?.close()
        positionOffers()
    }

    func clearOffers() {
        panels.values.forEach { $0.close() }
        panels.removeAll()
    }

    private func positionOffers() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            return
        }
        var top = screen.visibleFrame.maxY - 16
        for application in panels.keys.sorted(by: { $0.bundleID < $1.bundleID }) {
            guard let panel = panels[application] else { continue }
            panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 16, y: top))
            top -= panel.frame.height + 12
        }
    }
}

private final class MeetingToastPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct MeetingToast: View {
    let application: MeetingApplication
    let start: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Meeting detected")
                        .font(.headline)
                    Text("Ready to take notes in \(application.name)?")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: dismiss) {
                    Label("Dismiss", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss recording prompt")
            }
            Button(action: start) {
                Label("Start recording", systemImage: "record.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .environment(\.controlActiveState, .active)
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: 10))
        }
        .padding(16)
        .frame(width: 360)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary, lineWidth: 1))
    }
}
