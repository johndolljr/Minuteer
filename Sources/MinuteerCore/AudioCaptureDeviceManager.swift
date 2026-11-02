import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics

/// Discovers selectable hardware microphones and running applications on macOS.
public final class AudioCaptureDeviceManager: @unchecked Sendable {
    public static let shared = AudioCaptureDeviceManager()

    public init() {}

    public static func availableMicrophones() -> [AudioSourceDescriptor] {
        shared.availableMicrophones()
    }

    public static func availableApplications() async -> [AudioSourceDescriptor] {
        await shared.availableApplications()
    }

    public static func systemAudio() -> AudioSourceDescriptor {
        AudioSourceDescriptor.systemAudio
    }

    /// Discovers all currently available physical and virtual input microphones.
    public func availableMicrophones() -> [AudioSourceDescriptor] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.map { device in
            AudioSourceDescriptor.microphone(id: device.uniqueID, name: device.localizedName)
        }
    }

    /// Discovers all currently running applications available for ScreenCaptureKit audio capture.
    public func availableApplications() async -> [AudioSourceDescriptor] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let ownBundleID = Bundle.main.bundleIdentifier ?? "com.ragingcoders.Minuteer"

            var results: [AudioSourceDescriptor] = []
            var seenBundleIDs = Set<String>()

            for app in content.applications {
                let name = app.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let bundleID = app.bundleIdentifier
                guard bundleID != ownBundleID else { continue }
                guard !bundleID.hasPrefix("com.apple.controlcenter"),
                      !bundleID.hasPrefix("com.apple.dock"),
                      !bundleID.hasPrefix("com.apple.notificationcenterui") else { continue }

                if !seenBundleIDs.contains(bundleID) {
                    seenBundleIDs.insert(bundleID)
                    results.append(
                        AudioSourceDescriptor.application(
                            bundleID: bundleID,
                            pid: app.processID,
                            name: name
                        )
                    )
                }
            }

            return results.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } catch {
            return []
        }
    }

    /// Checks if Screen Recording permission has been granted.
    public func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Requests Screen Recording access from the user.
    public func requestScreenRecordingPermission() {
        CGRequestScreenCaptureAccess()
    }

    /// Checks if Microphone access has been granted.
    public func checkMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}
