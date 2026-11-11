//
//  Log.swift
//  ConduitCallEngine
//
//  The engine's logging, built on Apple's unified logging (os.Logger) with the same
//  shape and category labels as the host app's `Log`, so call sites read the same
//  and Console filtering looks the same. `debug` / `info` are compiled out of
//  release builds; `warning` / `error` always log.
//

import Foundation
import OSLog

private enum LogLevel {
    case debug
    case info
    case warning
    case error

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }
}

/// A logging domain with an emoji-prefixed label for fast console scanning.
package enum LogCategory: String {
    /// Call session state machine and orchestration.
    case call = "📞 [Call]"
    /// CallKit integration (provider, call controller, system call UI).
    case callkit = "☎️ [CallKit]"
    /// Signaling / transport layer (Pipecat connection, room join/leave).
    case transport = "🔌 [Transport]"
    /// Audio session, routing, and playback/capture.
    case audio = "🔊 [Audio]"
    /// Outbound HTTP / API requests.
    case network = "🌐 [Network]"
}

package enum Log {
    /// One `Logger` per category, reused across calls. The subsystem is the host
    /// app's bundle identifier, so engine logs group with the app's in Console.
    private static let loggers: [LogCategory: Logger] = {
        let subsystem = Bundle.main.bundleIdentifier ?? "com.conduit.app"
        var map: [LogCategory: Logger] = [:]
        for category in [LogCategory.call, .callkit, .transport, .audio, .network] {
            map[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        return map
    }()

    /// Logs a verbose detail. Compiled out of release builds.
    package static func debug(_ category: LogCategory, _ message: @autoclosure () -> String) {
        #if DEBUG
        emit(.debug, category, message())
        #endif
    }

    /// Logs a key checkpoint. Compiled out of release builds.
    package static func info(_ category: LogCategory, _ message: @autoclosure () -> String) {
        #if DEBUG
        emit(.info, category, message())
        #endif
    }

    /// Logs a recoverable issue. Always emitted.
    package static func warning(_ category: LogCategory, _ message: @autoclosure () -> String) {
        emit(.warning, category, message())
    }

    /// Logs a failure. Always emitted.
    package static func error(_ category: LogCategory, _ message: @autoclosure () -> String) {
        emit(.error, category, message())
    }

    /// The message is logged as `public` so it remains readable in Console; do not
    /// pass raw PII.
    private static func emit(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        let logger = loggers[category] ?? Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.conduit.app",
            category: category.rawValue
        )
        logger.log(level: level.osLogType, "\(message, privacy: .public)")
    }
}
