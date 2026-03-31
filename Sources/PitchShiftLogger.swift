import Foundation

final class PitchShiftLogger {
    static let shared = PitchShiftLogger()

    private let queue = DispatchQueue(label: "pitchshift.log.queue")
    private let formatter: DateFormatter
    private let logURL: URL
    private var handle: FileHandle?

    private static let maxLogSize: UInt64 = 2 * 1024 * 1024  // 2 MB

    private init() {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let logsDir = base.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        logURL = logsDir.appendingPathComponent("pitchshift.log")

        rotateIfNeeded()

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: logURL)
        handle?.seekToEndOfFile()
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? UInt64,
              size > Self.maxLogSize else { return }
        let oldURL = logURL.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.moveItem(at: logURL, to: oldURL)
    }

    var logPath: String { logURL.path }

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        print(message)
        queue.async { [weak self] in
            guard let self = self, let data = line.data(using: .utf8) else { return }
            self.handle?.write(data)
        }
    }
}
