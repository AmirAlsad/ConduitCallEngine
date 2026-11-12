//
//  VoIPPushRegistering.swift
//  ConduitCallEngine
//
//  The engine's seam over PushKit: start receiving VoIP pushes, read the current
//  token, and hand token updates and incoming pushes to the engine. The real
//  `SystemVoIPPushRegistry` wraps `PKPushRegistry`; `FakeVoIPPushRegistry` drives
//  the same callbacks without PushKit.
//
//  NOTE (device): iOS terminates the host unless `reportNewIncomingCall` is invoked
//  before the push callback returns. An incoming push is therefore handed to the
//  engine synchronously, inside the PushKit callback — no Task in between — and the
//  engine reports before returning and calls PushKit's completion after CallKit's.
//  Keep that invariant if this is refactored.
//

import Foundation
import PushKit

@MainActor
package protocol VoIPPushRegistering: AnyObject {
    /// The current VoIP token, once PushKit has issued one.
    var pushToken: Data? { get }
    /// Start receiving VoIP pushes. Called once.
    func start(
        onTokenUpdate: @escaping @MainActor (Data) -> Void,
        onIncomingPush: @escaping @MainActor (_ payload: [AnyHashable: Any], _ completion: @escaping () -> Void) -> Void
    )
}

/// Device-only: PushKit doesn't deliver in the simulator.
@MainActor
final class SystemVoIPPushRegistry: NSObject, VoIPPushRegistering, PKPushRegistryDelegate {
    private var registry: PKPushRegistry?
    private var onTokenUpdate: (@MainActor (Data) -> Void)?
    private var onIncomingPush: (@MainActor ([AnyHashable: Any], @escaping () -> Void) -> Void)?

    var pushToken: Data? { registry?.pushToken(for: .voIP) }

    func start(
        onTokenUpdate: @escaping @MainActor (Data) -> Void,
        onIncomingPush: @escaping @MainActor ([AnyHashable: Any], @escaping () -> Void) -> Void
    ) {
        guard registry == nil else { return }
        self.onTokenUpdate = onTokenUpdate
        self.onIncomingPush = onIncomingPush
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    // MARK: - PKPushRegistryDelegate (delivered on the main queue)

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        let token = pushCredentials.token
        MainActor.assumeIsolated { onTokenUpdate?(token) }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            guard type == .voIP, let onIncomingPush else {
                completion()
                return
            }
            onIncomingPush(payload.dictionaryPayload, completion)
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        Log.warning(.callKit, "VoIP push token invalidated")
    }
}
