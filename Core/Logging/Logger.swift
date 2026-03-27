import Foundation

struct Logger {
    let subsystem: String
    let logRepository: LogRepository?

    init(
        subsystem: String = "com.bitcare.bithub.ios",
        logRepository: LogRepository? = nil
    ) {
        self.subsystem = subsystem
        self.logRepository = logRepository
    }

    func debug(_ message: @autoclosure () -> String) {
        log(.debug, message())
    }

    func info(_ message: @autoclosure () -> String) {
        log(.info, message())
    }

    func warning(_ message: @autoclosure () -> String) {
        log(.warning, message())
    }

    func error(_ message: @autoclosure () -> String) {
        log(.error, message())
    }

    private func log(_ level: LogLevel, _ message: String) {
        let prefix: String
        switch level {
        case .debug:
            prefix = "DEBUG"
        case .info:
            prefix = "INFO"
        case .warning:
            prefix = "WARN"
        case .error:
            prefix = "ERROR"
        }

        print("[\(prefix)] [\(subsystem)] \(message)")
        guard let logRepository else {
            return
        }
        Task {
            await logRepository.append(level: level, tag: subsystem, message: message, callerID: nil)
        }
    }
}
