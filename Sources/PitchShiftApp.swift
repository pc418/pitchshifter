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
        if !instanceGuard.acquire() {
            PitchShiftLogger.shared.log("[PitchShift] Another instance is already running. Exiting.")
            NSApp.terminate(nil)
            return
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

final class SingleInstanceGuard {
    private let lockPath = "/tmp/pitchshift.lock"
    private var lockFD: Int32 = -1

    func acquire() -> Bool {
        let fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        if fd < 0 { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockFD = fd
        let pid = String(getpid()) + "\n"
        _ = ftruncate(fd, 0)
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return true
    }

    func release() {
        if lockFD >= 0 {
            _ = flock(lockFD, LOCK_UN)
            close(lockFD)
            lockFD = -1
        }
    }
}
