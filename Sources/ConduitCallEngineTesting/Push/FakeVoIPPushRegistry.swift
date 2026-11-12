//
//  FakeVoIPPushRegistry.swift
//  ConduitCallEngine
//
//  Fake conforming to `VoIPPushRegistering`: counts starts and lets a test
//  deliver token updates and pushes through the same callbacks PushKit would.
//

import Foundation
import ConduitCallEngine

@MainActor
package final class FakeVoIPPushRegistry: VoIPPushRegistering {
    package init() {}

    package var pushToken: Data?
    package private(set) var startCount = 0
    private var onTokenUpdate: (@MainActor (Data) -> Void)?
    private var onTokenInvalidated: (@MainActor () -> Void)?
    private var onIncomingPush: (@MainActor ([AnyHashable: Any], @escaping () -> Void) -> Void)?

    package func start(
        onTokenUpdate: @escaping @MainActor (Data) -> Void,
        onTokenInvalidated: @escaping @MainActor () -> Void,
        onIncomingPush: @escaping @MainActor ([AnyHashable: Any], @escaping () -> Void) -> Void
    ) {
        startCount += 1
        self.onTokenUpdate = onTokenUpdate
        self.onTokenInvalidated = onTokenInvalidated
        self.onIncomingPush = onIncomingPush
    }

    /// PushKit issued (or rotated) the token.
    package func simulateTokenUpdate(_ token: Data) {
        pushToken = token
        onTokenUpdate?(token)
    }

    /// PushKit invalidated the token: it has none until it issues a new one.
    package func simulateTokenInvalidation() {
        pushToken = nil
        onTokenInvalidated?()
    }

    /// PushKit delivered a VoIP push.
    package func simulateIncomingPush(_ payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        onIncomingPush?(payload, completion)
    }
}
