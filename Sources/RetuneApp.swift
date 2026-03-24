import SwiftUI
import AppKit
import Foundation
import Darwin

@main
struct RetuneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var engine: AudioEngine

    init() {
        let eng = AudioEngine()
        _engine = StateObject(wrappedValue: eng)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            eng.start()
        }
    }
    
    var body: some Scene {
        MenuBarExtra("Retune", systemImage: "music.note") {
            MenuBarView(engine: engine)
        }
        .menuBarExtraStyle(.window)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private let instanceGuard = SingleInstanceGuard()

    func applicationWillFinishLaunching(_ notification: Notification) {
        if !instanceGuard.acquire() {
            RetuneLogger.shared.log("[Retune] Another instance is already running. Exiting.")
            NSApp.terminate(nil)
            return
        }
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = false
        ProcessInfo.processInfo.disableAutomaticTermination("Retune audio processing")
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
    private let lockPath = "/tmp/retune.lock"
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
