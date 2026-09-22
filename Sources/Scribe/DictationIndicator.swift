import AppKit
import SwiftUI

/// Shows/hides a non-activating panel in lockstep with `AppState.dictationState`.
@MainActor
final class DictationIndicatorController {
    private let panel: DictationIndicatorPanel
    private let state: AppState

    init(state: AppState) {
        self.state = state
        let panel = DictationIndicatorPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let view = NSHostingView(rootView: DictationIndicatorView().environment(state))
        panel.contentView = view
        self.panel = panel
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = state.dictationState
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.sync()
                self?.observe()
            }
        }
    }

    private func sync() {
        guard state.dictationState != .idle else {
            panel.orderOut(nil)
            return
        }
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        position()
        panel.orderFrontRegardless()
    }

    private func position() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            return
        }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 48))
    }
}

private final class DictationIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct DictationIndicatorView: View {
    @Environment(AppState.self) private var state
    @State private var date = Date.now

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 220, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        switch state.dictationState {
        case .idle:
            EmptyView()

        case .starting:
            ProgressView()
                .controlSize(.small)
            Text("Waiting for permission…")
            Spacer(minLength: 12)
            Button("Cancel") { state.cancelDictation() }
                .buttonStyle(.bordered)

        case let .recording(startedAt):
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
            Text(elapsed(since: startedAt))
                .monospacedDigit()
                .task(id: state.dictationState) {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled else { return }
                        date = .now
                    }
                }
            Spacer(minLength: 12)
            Button("Cancel") { state.cancelDictation() }
                .buttonStyle(.bordered)
            Button("Stop") { state.requestStopDictation() }
                .buttonStyle(.borderedProminent)

        case .processing:
            ProgressView()
                .controlSize(.small)
            Text("Transcribing…")
            Spacer(minLength: 12)
            Button("Cancel") { state.cancelDictation() }
                .buttonStyle(.bordered)

        case .copied:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Copied to clipboard")

        case let .failed(message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .lineLimit(2)
            Spacer(minLength: 12)
            Button("Dismiss") { state.cancelDictation() }
                .buttonStyle(.bordered)
        }
    }

    private func elapsed(since startedAt: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
