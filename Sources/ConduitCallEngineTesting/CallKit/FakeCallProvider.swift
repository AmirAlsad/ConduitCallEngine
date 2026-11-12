//
//  FakeCallProvider.swift
//  ConduitCallEngine
//
//  Fake conforming to `CallProviding`, plus `FakeAudioSession` for driving
//  the activation handshake. A test drives the system → engine direction
//  (`simulateActivate`, `simulateEndCall`, …) and asserts on what was reported.
//  Like CallKit, it holds the ids of the calls it has and refuses to report an
//  incoming call under an id it already holds (`.duplicateCallID`).
//

import Foundation
import ConduitCallEngine

@MainActor
package final class FakeCallProvider: CallProviding {
    package init() {}

    package weak var delegate: CallProviderDelegate?
    package var supportsHolding = true

    package private(set) var startedCalls: [UUID] = []
    package private(set) var startedHandles: [CallHandle] = []
    package private(set) var reportedIncoming: [(id: UUID, handle: CallHandle, displayName: String)] = []
    package private(set) var updatedCalls: [(id: UUID, handle: CallHandle, displayName: String)] = []
    package private(set) var reportedConnecting: [UUID] = []
    package private(set) var reportedConnected: [UUID] = []
    package private(set) var endRequests: [UUID] = []
    package private(set) var reportedEnded: [(id: UUID, reason: CallEndReason)] = []
    package private(set) var muteStates: [UUID: Bool] = [:]
    /// Whether each call was last reported (started, reported or updated) as holdable.
    package private(set) var holdableCalls: [UUID: Bool] = [:]
    /// Every hold or resume the engine requested, in order.
    package private(set) var heldRequests: [(id: UUID, onHold: Bool)] = []
    /// The calls CallKit holds: started or successfully reported, and not yet
    /// ended by the engine, the system UI or a reset.
    package private(set) var liveCallIDs: Set<UUID> = []

    /// When set, the next `startOutgoingCall` throws this.
    package var startError: Error?
    /// When set, `reportIncomingCall` completes with this error. A report under an
    /// id in `liveCallIDs` completes with `.duplicateCallID` regardless.
    package var reportIncomingError: IncomingCallReportError?
    /// When true, `reportIncomingCall` holds its completion until
    /// `completeIncomingReports()` (real CallKit completes later); when false it
    /// completes before returning.
    package var completesIncomingReportsLater = false
    private var pendingIncomingCompletions: [@MainActor () -> Void] = []
    /// Receives a label for each call into the provider, so a test can assert the
    /// order of provider calls against other events in one log.
    package var onEvent: ((String) -> Void)?
    /// The UUID handed back from the next `startOutgoingCall`; a new one after each.
    package var nextCallID = UUID()

    /// When true, `startOutgoingCall` suspends until `releaseStart()` — lets a test
    /// act while CallKit is still starting the call.
    package var suspendStart = false
    package private(set) var pendingStartCount = 0
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

    /// Resume only the oldest suspended `startOutgoingCall`.
    package func releaseFirstStart() {
        guard !startContinuations.isEmpty else { return }
        pendingStartCount -= 1
        startContinuations.removeFirst().resume()
    }

    package func releaseStart() {
        let waiting = startContinuations
        startContinuations = []
        pendingStartCount = 0
        waiting.forEach { $0.resume() }
    }

    package func startOutgoingCall(handle: CallHandle, displayName: String) async throws -> UUID {
        let id = nextCallID
        nextCallID = UUID()
        if suspendStart {
            pendingStartCount += 1
            await withCheckedContinuation { startContinuations.append($0) }
        }
        if let startError { throw startError }
        liveCallIDs.insert(id)
        holdableCalls[id] = supportsHolding
        startedCalls.append(id)
        startedHandles.append(handle)
        return id
    }

    package func reportIncomingCall(
        id: UUID,
        handle: CallHandle,
        displayName: String,
        completion: @escaping @MainActor (IncomingCallReportError?) -> Void
    ) {
        onEvent?("report")
        let error: IncomingCallReportError? = liveCallIDs.contains(id) ? .duplicateCallID : reportIncomingError
        if error == nil {
            liveCallIDs.insert(id)
            holdableCalls[id] = supportsHolding
        }
        reportedIncoming.append((id, handle, displayName))
        let complete: @MainActor () -> Void = { [weak self] in
            self?.onEvent?("report-completed")
            completion(error)
        }
        if completesIncomingReportsLater {
            pendingIncomingCompletions.append(complete)
        } else {
            complete()
        }
    }

    /// Deliver every held `reportIncomingCall` completion, in report order.
    package func completeIncomingReports() {
        let pending = pendingIncomingCompletions
        pendingIncomingCompletions = []
        pending.forEach { $0() }
    }

    package func updateCall(_ id: UUID, handle: CallHandle, displayName: String) {
        onEvent?("update")
        holdableCalls[id] = supportsHolding
        updatedCalls.append((id, handle, displayName))
    }

    package func reportOutgoingCallConnecting(_ id: UUID) { reportedConnecting.append(id) }
    package func reportOutgoingCallConnected(_ id: UUID) {
        onEvent?("reported-connected")
        reportedConnected.append(id)
    }
    package func endCall(_ id: UUID) async {
        onEvent?("end-request")
        endRequests.append(id)
        liveCallIDs.remove(id)
    }

    package func reportCallEnded(_ id: UUID, reason: CallEndReason) {
        onEvent?("ended(\(reason))")
        reportedEnded.append((id, reason))
        liveCallIDs.remove(id)
    }
    package func setMuted(_ id: UUID, muted: Bool) async { muteStates[id] = muted }

    /// Like CallKit, performs the request through the delegate, and only for a
    /// call it holds that was reported as holdable (CallKit is assumed to refuse
    /// the others before they reach the provider).
    package func setHeld(_ id: UUID, onHold: Bool) async {
        onEvent?("held-request(\(onHold))")
        heldRequests.append((id, onHold))
        guard liveCallIDs.contains(id), holdableCalls[id] == true else { return }
        _ = delegate?.providerPerformSetHeld(id, onHold: onHold)
    }

    // MARK: - System → engine drivers (for tests and the simulator)

    package func simulateActivate(_ session: AudioSessionActivating) {
        delegate?.providerDidActivate(session)
    }

    package func simulateDeactivate(_ session: AudioSessionActivating) {
        delegate?.providerDidDeactivate(session)
    }

    package func simulateAnswerCall(_ id: UUID) { delegate?.providerPerformAnswerCall(id) }
    package func simulateEndCall(_ id: UUID) {
        liveCallIDs.remove(id)
        delegate?.providerPerformEndCall(id)
    }
    package func simulateSetMuted(_ id: UUID, muted: Bool) { delegate?.providerPerformSetMuted(id, muted: muted) }
    /// The system performs a hold or resume for `id`; returns whether the engine
    /// fulfilled the action.
    @discardableResult
    package func simulateSetHeld(_ id: UUID, onHold: Bool) -> Bool {
        delegate?.providerPerformSetHeld(id, onHold: onHold) ?? false
    }
    package func simulateReset() {
        liveCallIDs.removeAll()
        delegate?.providerWasReset()
    }
}

@MainActor
package final class FakeAudioSession: AudioSessionActivating {
    package init() {}
}
