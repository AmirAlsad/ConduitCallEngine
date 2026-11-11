//
//  CallEngineConfiguration.swift
//  ConduitCallEngine
//
//  The host's settings for the call engine. `isPushToTalkEnabled` is a closure so a
//  mid-call settings flip is honoured on the next mic decision.
//

import Foundation

public struct CallEngineConfiguration {
    /// The caller name a ring shows when the push carries none.
    public var unknownCallerName: String
    public var isPushToTalkEnabled: @MainActor () -> Bool

    public init(
        unknownCallerName: String = "Unknown",
        isPushToTalkEnabled: @escaping @MainActor () -> Bool = { false }
    ) {
        self.unknownCallerName = unknownCallerName
        self.isPushToTalkEnabled = isPushToTalkEnabled
    }
}
