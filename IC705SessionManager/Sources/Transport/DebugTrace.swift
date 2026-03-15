import Foundation

/// Simple debug trace logging for the IC-705 session manager.
/// In a CLI context, this writes to stderr. In an iOS context, this writes to a file.
public enum DebugTrace {
    private static let queue = DispatchQueue(label: "com.ic705.session.debugtrace")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    #if os(iOS)
    static var logFileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("ic705-debug.log")
    }
    #endif

    public static func clear() {
        #if os(iOS)
        queue.async {
            try? FileManager.default.removeItem(at: logFileURL)
        }
        #endif
    }

    public static func write(_ category: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(category)] \(message)\n"

        #if os(iOS)
        queue.async {
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: logFileURL, options: .atomic)
            }
        }
        #else
        // macOS/CLI: write to stderr
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
        #endif
    }
}
