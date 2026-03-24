import Foundation

final class RetuneLogger {
    static let shared = RetuneLogger()

    private let queue = DispatchQueue(label: "retune.log.queue")
    private let formatter: DateFormatter
    private let logURL: URL
    private var handle: FileHandle?

    private init() {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let logsDir = base.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        logURL = logsDir.appendingPathComponent("retune.log")

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: logURL)
        handle?.seekToEndOfFile()
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
