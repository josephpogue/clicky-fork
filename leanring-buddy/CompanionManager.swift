//
//  CompanionManager.swift
//  leanring-buddy
//
//  Tracks the three macOS permissions the app needs (Accessibility, Screen
//  Recording, Microphone) and keeps polling them so the menu bar panel updates
//  as soon as the user grants one. It asks the system what is granted and
//  starts no capture of any kind. Sessions live in `SessionCoordinator`.
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false

    private var permissionPollTimer: Timer?

    /// True when all required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show the permissions section.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission
    }

    /// Reads the current permission state and keeps polling it.
    func start() {
        refreshAllPermissions()
        print("Clicky Fork start: accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission)")
        startPermissionPolling()
    }

    func stop() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission

        hasAccessibilityPermission = WindowPositionManager.hasAccessibilityPermission()
        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()
        hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("Permissions: accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission)")
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception:
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }
}
