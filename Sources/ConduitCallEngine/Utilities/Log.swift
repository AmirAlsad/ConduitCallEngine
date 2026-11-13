//
//  Log.swift
//  ConduitCallEngine
//
//  The package's logging. Every line the engine and the bundled adapters log goes
//  through `Log`, which drops events below `CallEngineLog.minimumLevel` before their
//  message is built, removes credentials from the message (`CredentialRedaction`),
//  and hands the event to the host's `CallEngineLog.handler`, or, without one, to
//  Apple's unified logging (os.Logger, one category per domain).
//

import Foundation
import OSLog
import Synchronization

/// Where the log events of the engine and the bundled adapters go.
///
/// By default they are written to Apple's unified logging under the app's bundle
/// identifier, in categories such as `📞 [Call]` (`writeToOSLog(_:)`), and only
/// warnings and errors are logged in release builds of the package. Set `handler` to
/// receive the events yourself (for a diagnostic trace, or to forward them to your
/// own logging) and `minimumLevel` to choose how much you get.
///
/// Every member is nonisolated and safe to use from any thread. The package never
/// puts a credential in a message: tokens, bearer values, URL queries and user info
/// are removed from every message before it is delivered, including the error
/// descriptions of SDKs and of your own `CallTarget.connect`.
public enum CallEngineLog {
    /// How severe an event is.
    ///
    /// Closed: the package adds no case to this enum within a minor version while it is
    /// 0.x (from 1.0, within a major version).
    public enum Level: Int, Comparable, CaseIterable, Sendable {
        /// Verbose detail.
        case debug
        /// A checkpoint: a call connected, CallKit activated the audio session.
        case info
        /// Something recoverable went wrong, or something was ignored.
        case warning
        /// A failure.
        case error

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Which part of the package an event comes from.
    ///
    /// Open: later versions may add cases. End a `switch` over it with
    /// `@unknown default`, which keeps it compiling, with a warning that names the new
    /// case, when one is added.
    public enum Category: String, CaseIterable, Sendable {
        /// The call state machine.
        case call
        /// CallKit and PushKit, including CallKit's audio-session activations.
        case callKit
        /// The transport: joining, leaving, signals.
        case transport
        /// Audio: attach, detach, routes.
        case audio
        /// HTTP requests the engine makes itself (ring-status receipts).
        case network
    }

    /// One log event.
    public struct Event: Equatable, Sendable {
        public let level: Level
        public let category: Category
        /// The message, with credentials already removed.
        public let message: String

        public init(level: Level, category: Category, message: String) {
            self.level = level
            self.category = category
            self.message = message
        }
    }

    /// Receives log events. Called synchronously on the thread that logs, which is
    /// the main actor for the engine and can be an SDK's callback queue for an
    /// adapter, so it must be quick and must not block.
    public typealias Handler = @Sendable (Event) -> Void

    /// Receives every event at or above `minimumLevel`, instead of unified logging;
    /// nil (the default) writes them to unified logging. A handler that also wants
    /// Console output calls `writeToOSLog(_:)`.
    public static var handler: Handler? {
        get { settings.withLock { $0.handler } }
        set { settings.withLock { $0.handler = newValue } }
    }

    /// The least severe events that are delivered. Events below it are dropped
    /// before their message is built. Default `.debug` in debug builds of the
    /// package and `.warning` in release builds; lower it in a release build to get
    /// `.info` events too.
    public static var minimumLevel: Level {
        get { settings.withLock { $0.minimumLevel } }
        set { settings.withLock { $0.minimumLevel = newValue } }
    }

    /// Writes `event` to unified logging as the package does without a handler: under
    /// the app's bundle identifier, in the event's category, with the message public.
    public static func writeToOSLog(_ event: Event) {
        let logger = osLoggers[event.category] ?? Logger(subsystem: subsystem, category: event.category.osLogLabel)
        logger.log(level: event.level.osLogType, "\(event.message, privacy: .public)")
    }

    private struct Settings {
        var handler: Handler?
        #if DEBUG
        var minimumLevel = Level.debug
        #else
        var minimumLevel = Level.warning
        #endif
    }

    private static let settings = Mutex(Settings())

    private static let subsystem = Bundle.main.bundleIdentifier ?? "ConduitCallEngine"

    /// One `Logger` per category, reused across calls.
    private static let osLoggers: [Category: Logger] = Dictionary(
        uniqueKeysWithValues: Category.allCases.map { ($0, Logger(subsystem: subsystem, category: $0.osLogLabel)) }
    )

    /// Deliver an event, building its message only if it will be delivered.
    fileprivate static func emit(_ level: Level, _ category: Category, _ message: () -> String) {
        let (handler, minimumLevel) = settings.withLock { ($0.handler, $0.minimumLevel) }
        guard level >= minimumLevel else { return }
        let event = Event(level: level, category: category, message: CredentialRedaction.redact(message()))
        if let handler {
            handler(event)
        } else {
            writeToOSLog(event)
        }
    }
}

extension CallEngineLog.Level {
    fileprivate var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .warning: .default
        case .error: .error
        }
    }
}

extension CallEngineLog.Category {
    /// The category name in Console, emoji-prefixed for fast scanning.
    fileprivate var osLogLabel: String {
        switch self {
        case .call: "📞 [Call]"
        case .callKit: "☎️ [CallKit]"
        case .transport: "🔌 [Transport]"
        case .audio: "🔊 [Audio]"
        case .network: "🌐 [Network]"
        }
    }
}

package typealias LogCategory = CallEngineLog.Category

/// The package's logging calls. Each message is an autoclosure, built only when the
/// event is at or above `CallEngineLog.minimumLevel`.
package enum Log {
    /// A verbose detail.
    package static func debug(_ category: LogCategory, _ message: @autoclosure () -> String) {
        CallEngineLog.emit(.debug, category, message)
    }

    /// A key checkpoint.
    package static func info(_ category: LogCategory, _ message: @autoclosure () -> String) {
        CallEngineLog.emit(.info, category, message)
    }

    /// A recoverable issue.
    package static func warning(_ category: LogCategory, _ message: @autoclosure () -> String) {
        CallEngineLog.emit(.warning, category, message)
    }

    /// A failure.
    package static func error(_ category: LogCategory, _ message: @autoclosure () -> String) {
        CallEngineLog.emit(.error, category, message)
    }
}
