import SwiftUI
import AppKit
import Foundation
import Darwin

@main
struct PitchShiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var engine: AudioEngine

    init() {
        let eng = AudioEngine()
        _engine = StateObject(wrappedValue: eng)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.engine = eng
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(engine: engine)
        } label: {
            let name = engine.isRunning ? "menubar_active" : "menubar_inactive"
            if let img = loadMenuBarPDF(name) {
                Image(nsImage: img)
            } else {
                Text(engine.isRunning ? "♮" : "#")
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
            }
        }
        .menuBarExtraStyle(.window)
    }

    private func loadMenuBarPDF(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "pdf") else { return nil }
        guard let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        return img
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private let instanceGuard = SingleInstanceGuard()
    weak var engine: AudioEngine?

    func applicationWillFinishLaunching(_ notification: Notification) {
        switch instanceGuard.acquire() {
        case .acquired:
            break
        case .alreadyRunning:
            PitchShiftLogger.shared.log("[PitchShift] Another instance is already running. Exiting.")
            NSApp.terminate(nil)
        case .failed(let reason):
            // Refuse to launch rather than risk a second global process tap:
            // two instances each exclude only their own PID, so they capture
            // each other's output and the audio doubles back on itself.
            PitchShiftLogger.shared.log("[PitchShift] ERROR: instance lock unavailable (\(reason)). Exiting.")
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        instanceGuard.release()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

enum InstanceLockResult {
    case acquired
    case alreadyRunning
    case failed(String)
}

final class SingleInstanceGuard {
    private let lockURL: URL
    private var lockFD: Int32 = -1

    init() {
        // Per-user Application Support, not /tmp: /tmp is world-writable, so a
        // lock file owned by another user (or a stale root-owned one) would make
        // open() fail for every launch.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("PitchShift", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lockURL = dir.appendingPathComponent("pitchshift.lock")
    }

    func acquire() -> InstanceLockResult {
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        if fd < 0 {
            let err = String(cString: strerror(errno))
            return .failed("\(lockURL.path): \(err)")
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return .alreadyRunning
        }
        lockFD = fd
        let pid = String(getpid()) + "\n"
        _ = ftruncate(fd, 0)
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return .acquired
    }

    func release() {
        if lockFD >= 0 {
            _ = flock(lockFD, LOCK_UN)
            close(lockFD)
            lockFD = -1
        }
    }
}
