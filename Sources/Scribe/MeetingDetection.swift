import AppKit
import CoreAudio
import Darwin
import Foundation

struct MeetingApplication: Hashable, Sendable {
    let bundleID: String
    let name: String

    static let defaults: Set<Self> = [
        MeetingApplication(bundleID: "us.zoom.xos", name: "Zoom"),
        MeetingApplication(bundleID: "company.thebrowser.Browser", name: "Arc"),
    ]

    static func matching(_ bundleID: String, in configured: Set<Self>) -> Self? {
        let candidate = bundleID.lowercased()
        return configured.first {
            let configuredID = $0.bundleID.lowercased()
            return candidate == configuredID || candidate.hasPrefix(configuredID + ".")
        }
    }
}

enum MeetingEvent: Equatable, Sendable {
    case started(MeetingApplication)
    case ended(MeetingApplication)
}

@MainActor
final class MeetingDetector {
    private let scan: () throws -> Set<MeetingApplication>
    private let stopDelay: Duration
    private var active: Set<MeetingApplication> = []
    private var observed: Set<MeetingApplication> = []
    private var pendingStops: [MeetingApplication: Task<Void, Never>] = [:]
    private var pollingTask: Task<Void, Never>?

    var onEvent: ((MeetingEvent) -> Void)?
    var onError: ((String?) -> Void)?

    init(
        configuredApplications: Set<MeetingApplication> = MeetingApplication.defaults,
        scanner: CoreAudioMicScanner = CoreAudioMicScanner(),
        stopDelay: Duration = .seconds(10),
        scan: (() throws -> Set<MeetingApplication>)? = nil
    ) {
        self.scan = scan ?? { try scanner.activeApplications(from: configuredApplications) }
        self.stopDelay = stopDelay
    }

    deinit {
        pollingTask?.cancel()
        pendingStops.values.forEach { $0.cancel() }
    }

    func start() {
        guard pollingTask == nil else { return }

        // ponytail: one-second polling avoids listener lifetime hazards; switch if profiling shows material idle cost.
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        pendingStops.values.forEach { $0.cancel() }
        pendingStops.removeAll()
    }

    func refresh() {
        let current: Set<MeetingApplication>
        do {
            current = try scan()
            onError?(nil)
        } catch {
            onError?(error.localizedDescription)
            return
        }
        observed = current

        for application in current {
            pendingStops.removeValue(forKey: application)?.cancel()
            if active.insert(application).inserted {
                onEvent?(.started(application))
            }
        }

        for application in active.subtracting(current) where pendingStops[application] == nil {
            pendingStops[application] = Task { [weak self] in
                try? await Task.sleep(for: self?.stopDelay ?? .seconds(10))
                guard !Task.isCancelled, let self, !self.observed.contains(application) else { return }
                self.pendingStops[application] = nil
                self.active.remove(application)
                self.onEvent?(.ended(application))
            }
        }
    }
}

@MainActor
struct CoreAudioMicScanner {
    enum Error: LocalizedError {
        case property(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .property(status): "Core Audio process detection failed with status \(status)."
            }
        }
    }

    func activeApplications(from configured: Set<MeetingApplication>) throws -> Set<MeetingApplication> {
        var active: Set<MeetingApplication> = []

        for objectID in try processObjectIDs() {
            guard objectID != kAudioObjectUnknown,
                  let running = try? readUInt32(objectID, kAudioProcessPropertyIsRunningInput),
                  running != 0,
                  let pid = try? readPID(objectID) else { continue }
            if let application = configuredApplication(for: pid, processObjectID: objectID, configured: configured) {
                active.insert(application)
            }
        }

        return active
    }

    func processObjectIDs(for application: MeetingApplication) throws -> [AudioObjectID] {
        try processObjectIDs().filter { objectID in
            guard objectID != kAudioObjectUnknown, let pid = try? readPID(objectID) else { return false }
            return configuredApplication(
                for: pid,
                processObjectID: objectID,
                configured: [application]
            ) != nil
        }
    }

    private func configuredApplication(
        for pid: pid_t,
        processObjectID: AudioObjectID,
        configured: Set<MeetingApplication>
    ) -> MeetingApplication? {
        if let bundleID = try? readBundleID(processObjectID),
           let match = MeetingApplication.matching(bundleID, in: configured) {
            return match
        }

        var currentPID = pid
        for _ in 0..<8 where currentPID > 1 {
            if let bundleID = NSRunningApplication(processIdentifier: currentPID)?.bundleIdentifier,
               let match = MeetingApplication.matching(bundleID, in: configured) {
                return match
            }
            currentPID = parentPID(of: currentPID)
        }
        return nil
    }

    private func parentPID(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
        return size == MemoryLayout.size(ofValue: info) ? pid_t(info.pbi_ppid) : 0
    }

    private func processObjectIDs() throws -> [AudioObjectID] {
        var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size))
        var objectIDs = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objectIDs))
        return Array(objectIDs.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private func readUInt32(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
        var address = propertyAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value))
        return value
    }

    private func readPID(_ objectID: AudioObjectID) throws -> pid_t {
        var address = propertyAddress(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value))
        return value
    }

    private func readBundleID(_ objectID: AudioObjectID) throws -> String? {
        var address = propertyAddress(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value))
        return value?.takeRetainedValue() as String?
    }

    private func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw Error.property(status) }
    }
}
