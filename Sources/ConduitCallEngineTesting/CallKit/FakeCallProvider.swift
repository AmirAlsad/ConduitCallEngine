//
//  FakeCallProvider.swift
//  ConduitCallEngine
//
//  Fake conforming to `CallProviding`, plus `FakeAudioSession` for driving
//  the activation handshake. A test drives the system → app direction
//  (`simulateActivate`, `simulateEndCall`, …) and asserts on what was reported.
//

import Foundation
import ConduitCallEngine

@MainActor
package final class FakeCallProvider: CallProviding {
    package init() {}

    package weak var delegate: CallProviderDelegate?

    package private(set) var startedCalls: [UUID] = []
    package private(set) var startedHandles: [CallHandle] = []
    package private(set) var reportedIncoming: [(id: UUID, handle: CallHandle, displayName: String)] = []
    package private(set) var updatedCalls: [(id: UUID, handle: CallHandle, displayName: String)] = []
    package private(set) var reportedConnecting: [UUID] = []
    package private(set) var reportedConnected: [UUID] = []
    package private(set) var endRequests: [UUID] = []
    package private(set) var reportedEnded: [(id: UUID, reason: CallEndReason)] = []
    package private(set) var muteStates: [UUID: Bool] = [:]

    /// When set, the next `startOutgoingCall` throws this.
    package var startError: Error?
    /// When set, `reportIncomingCall` completes with this error.
    package var reportIncomingError: IncomingCallReportError?
    /// When true, `reportIncomingCall` holds its completion until
    /// `completeIncomingReports()` (real CallKit completes later); when false it
    /// completes before returning.
    package var completesIncomingReportsLater = false
    private var pendingIncomingCompletions: [@MainActor () -> Void] = []
    /// Receives a label for each call into the provider, so a test can assert the
    /// order of provider calls against other events in one log.
    package var onEvent: ((String) -> Void)?
    /// The UUID handed back from the next `startOutgoingCall`.
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
        if suspendStart {
            pendingStartCount += 1
            await withCheckedContinuation { startContinuations.append($0) }
        }
        if let startError { throw startError }
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
        let error = reportIncomingError
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
    }

    package func reportCallEnded(_ id: UUID, reason: CallEndReason) {
        onEvent?("ended(\(reason))")
        reportedEnded.append((id, reason))
    }
    package func setMuted(_ id: UUID, muted: Bool) async { muteStates[id] = muted }

    // MARK: - System → app drivers (for tests / debug path)

    package func simulateActivate(_ session: AudioSessionActivating) {
        delegate?.providerDidActivate(session)
    }

    package func simulateDeactivate(_ session: AudioSessionActivating) {
        delegate?.providerDidDeactivate(session)
    }

    package func simulateAnswerCall(_ id: UUID) { delegate?.providerPerformAnswerCall(id) }
    package func simulateEndCall(_ id: UUID) { delegate?.providerPerformEndCall(id) }
    package func simulateSetMuted(_ id: UUID, muted: Bool) { delegate?.providerPerformSetMuted(id, muted: muted) }
    package func simulateReset() { delegate?.providerWasReset() }
}

@MainActor
package final class FakeAudioSession: AudioSessionActivating {
    package var hasExternalAudioRoute: Bool
    package private(set) var didOverrideToSpeaker = false
    package private(set) var didClearOverride = false

    package init(hasExternalAudioRoute: Bool = false) {
        self.hasExternalAudioRoute = hasExternalAudioRoute
    }

    package func overrideOutputToSpeaker() throws { didOverrideToSpeaker = true }
    package func clearOutputOverride() throws { didClearOverride = true }
}
