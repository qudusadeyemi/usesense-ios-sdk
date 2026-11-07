import Foundation

/// Opt-in diagnostic trace. Silent unless the host launches with the
/// environment variable `USESENSE_DEBUG=1` (or sets the `USESENSE_DEBUG`
/// user default), so integrators' apps never log this by default.
///
/// It exists because a hang on a real device left no trace anywhere: the SDK
/// barely logged, and a request that is never sent never reaches the server.
/// Each line carries elapsed time, thread and call site:
///   [UseSense +12.345s bg] upload: request start POST /v1/sessions/…/signals (UseSenseAPIClient.swift:250)
enum USTrace {
    static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["USESENSE_DEBUG"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "USESENSE_DEBUG")
    }()

    private static let start = Date()

    static func log(_ message: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) {
        guard enabled else { return }
        let elapsed = String(format: "%.3f", Date().timeIntervalSince(start))
        let thread = Thread.isMainThread ? "main" : "bg"
        let name = "\(file)".split(separator: "/").last.map(String.init) ?? "\(file)"
        print("[UseSense +\(elapsed)s \(thread)] \(message()) (\(name):\(line))")
    }
}
