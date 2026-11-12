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

    /// When true, every hold or resume request is refused before it is performed.
    package var refusesHeldRequests = false

    /// Like CallKit, performs the request through the delegate, and only for a
    /// call it holds that was reported as holdable (CallKit is assumed to refuse
    /// the others before they reach the provider). Returns whether it accepted the
    /// request, whatever the engine then made of it.
    @discardableResult
    package func setHeld(_ id: UUID, onHold: Bool) async -> Bool {
        onEvent?("held-request(\(onHold))")
        heldRequests.append((id, onHold))
        guard !refusesHeldRequests, liveCallIDs.contains(id), holdableCalls[id] == true else { return false }
        _ = delegate?.providerPerformSetHeld(id, onHold: onHold)
        return true
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
    // MARK: - Other calls on the device (CallKit's call observer)

    /// The calls other than the ones the engine reported, in the order they
    /// started; an ended one is removed.
    package private(set) var otherCalls: [ObservedCall] = []

    /// The engine's calls CallKit holds, then the other calls, as the observer lists them.
    package var observedCalls: [ObservedCall] {
        liveCallIDs.sorted { $0.uuidString < $1.uuidString }.map { ObservedCall(id: $0, hasEnded: false, isOnHold: false) }
            + otherCalls
    }

    /// Another call started (ringing, or placed) on the device.
    @discardableResult
    package func simulateOtherCallStarted(_ id: UUID = UUID()) -> UUID {
        let call = ObservedCall(id: id, hasEnded: false, isOnHold: false)
        otherCalls.removeAll { $0.id == id }
        otherCalls.append(call)
        delegate?.providerDidObserveCallChange(call)
        return id
    }

    /// Another call was held or resumed on the device.
    package func simulateOtherCallHeld(_ id: UUID, onHold: Bool) {
        guard let index = otherCalls.firstIndex(where: { $0.id == id }) else { return }
        otherCalls[index] = ObservedCall(id: id, hasEnded: false, isOnHold: onHold)
        delegate?.providerDidObserveCallChange(otherCalls[index])
    }

    /// Another call ended on the device, however it ended.
    package func simulateOtherCallEnded(_ id: UUID) {
        otherCalls.removeAll { $0.id == id }
        delegate?.providerDidObserveCallChange(ObservedCall(id: id, hasEnded: true, isOnHold: false))
    }

    /// Deliver an observer change as is, for any id (the engine's own included),
    /// without changing `observedCalls`.
    package func simulateObservedCallChange(_ call: ObservedCall) {
        delegate?.providerDidObserveCallChange(call)
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
