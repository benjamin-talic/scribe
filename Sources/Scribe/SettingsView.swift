import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var microphones: [AudioInputDevice] = []
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var notificationPermission: UNAuthorizationStatus = .notDetermined
    @AppStorage(microphoneDeviceUIDKey) private var microphoneDeviceUID = ""
    @AppStorage(systemAudioPermissionGrantedKey) private var systemAudioPermissionGranted = false

    var body: some View {
        Form {
            Section("General") {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(get: { launchAtLogin }, set: { enabled in setLaunchAtLogin(enabled) })
                )
                LabeledContent("Meeting apps", value: "Zoom, Arc")
                Picker("Microphone", selection: $microphoneDeviceUID) {
                    Text(systemDefaultMicrophoneLabel).tag("")
                    if !microphoneDeviceUID.isEmpty,
                       !microphones.contains(where: { $0.id == microphoneDeviceUID }) {
                        Text("Selected microphone (disconnected)").tag(microphoneDeviceUID)
                    }
                    ForEach(microphones) { microphone in
                        Text(microphone.name).tag(microphone.id)
                    }
                }
            }

            Section("Permissions") {
                permissionRow("Microphone", status: microphonePermissionText, granted: microphonePermission == .authorized) {
                    openPrivacySettings("Privacy_Microphone")
                }
                permissionRow(
                    "System Audio Recording",
                    status: systemAudioPermissionGranted ? "Available on last recording" : "Checked when recording",
                    granted: systemAudioPermissionGranted
                ) {
                    openPrivacySettings("Privacy_ScreenCapture")
                }
                permissionRow(
                    "Notifications",
                    status: notificationPermissionText,
                    granted: notificationPermission == .authorized
                ) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Section("Processing") {
                LabeledContent("Transcription", value: "Whisper small")
                LabeledContent("Speaker labels", value: "SpeakerKit")
                Picker(
                    "Notes client",
                    selection: Binding(
                        get: { state.notesClient },
                        set: { client in Task { await state.setNotesClient(client) } }
                    )
                ) {
                    ForEach(NotesClient.allCases) { client in
                        Text(client.name).tag(client)
                    }
                }
                LabeledContent("Notes model", value: "openai/gpt-5.6-terra")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    @ViewBuilder
    private func permissionRow(
        _ title: String,
        status: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Text(status).foregroundStyle(granted ? Color.secondary : Color.orange)
                if !granted { Button("Open Settings", action: action) }
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            state.storageError = error.localizedDescription
        }
    }

    private func refresh() async {
        microphones = AudioInputDevice.available()
        microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
        notificationPermission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private var microphonePermissionText: String {
        switch microphonePermission {
        case .authorized: "Granted"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Requested when first recording"
        @unknown default: "Unknown"
        }
    }

    private var notificationPermissionText: String {
        switch notificationPermission {
        case .authorized, .provisional, .ephemeral: "Granted"
        case .denied: "Denied"
        case .notDetermined: "Requested at launch"
        @unknown default: "Unknown"
        }
    }

    private var systemDefaultMicrophoneLabel: String {
        guard let microphone = microphones.first(where: \.isDefault) else { return "System Default" }
        return "System Default (\(microphone.name))"
    }
}
