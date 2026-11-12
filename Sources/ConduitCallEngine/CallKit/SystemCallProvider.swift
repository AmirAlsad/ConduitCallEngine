//
//  SystemCallProvider.swift
//  ConduitCallEngine
//
//  Real `CallProviding` over CallKit (`CXProvider` + `CXCallController`). Bridges
//  the `CXProviderDelegate` callbacks onto `CallProviderDelegate`. This is the
//  audio-session-ownership boundary: CallKit activates the session and this
//  forwards that via `providerDidActivate` — media must NOT start anywhere else.
//
//  Device-only (CallKit doesn't run in the simulator).
//

import AVFoundation
import CallKit
import Foundation

@MainActor
final class SystemCallProvider: NSObject, CallProviding, CXProviderDelegate {
    weak var delegate: CallProviderDelegate?
    var supportsHolding = true

    private let provider: CXProvider
    private let callController = CXCallController()
    private let audioSession = SystemAudioSession()

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportedHandleTypes = [.emailAddress]
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.includesCallsInRecents = true
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil) // nil → main queue
    }

    // MARK: - CallProviding (engine → system)

    func startOutgoingCall(handle: CallHandle, displayName: String) async throws -> UUID {
        // Pre-configure the session (no activation); CallKit activates it and the
        // engine attaches media in providerDidActivate.
        try? audioSession.prepareForVoIPCall()

        let uuid = UUID()
        let cxHandle = CXHandle(type: .emailAddress, value: handle.value)
        let action = CXStartCallAction(call: uuid, handle: cxHandle)
        try await callController.request(CXTransaction(action: action))

        // Show the target's display name on the call and lock screens instead of
        // the raw email-type handle.
        let update = makeCallUpdate()
        update.localizedCallerName = displayName
        provider.reportCall(with: uuid, updated: update)

        return uuid
    }

    func reportIncomingCall(
        id: UUID,
        handle: CallHandle,
        displayName: String,
        completion: @escaping @MainActor (IncomingCallReportError?) -> Void
    ) {
        // Pre-configure the session (no activation); CallKit activates on answer.
        try? audioSession.prepareForVoIPCall()

        let update = makeCallUpdate()
        update.localizedCallerName = displayName
        update.remoteHandle = CXHandle(type: .emailAddress, value: handle.value)
        // Issued synchronously: PushKit kills the host if a VoIP push's call isn't
        // reported before the push callback returns.
        provider.reportNewIncomingCall(with: id, update: update) { error in
            let result: IncomingCallReportError?
            if let cxError = error as? CXErrorCodeIncomingCallError,
               cxError.code == .filteredByDoNotDisturb {
                result = .filteredByFocus
            } else if let cxError = error as? CXErrorCodeIncomingCallError,
                      cxError.code == .callUUIDAlreadyExists {
                result = .duplicateCallID
            } else if let error {
                result = .failed(String(describing: error))
            } else {
                result = nil
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated { completion(result) }
            } else {
                Task { @MainActor in completion(result) }
            }
        }
    }

    func updateCall(_ id: UUID, handle: CallHandle, displayName: String) {
        let update = makeCallUpdate()
        update.localizedCallerName = displayName
        update.remoteHandle = CXHandle(type: .emailAddress, value: handle.value)
        provider.reportCall(with: id, updated: update)
    }

    func reportOutgoingCallConnecting(_ id: UUID) {
        provider.reportOutgoingCall(with: id, startedConnectingAt: nil)
    }

    func reportOutgoingCallConnected(_ id: UUID) {
        provider.reportOutgoingCall(with: id, connectedAt: nil)
    }

    func endCall(_ id: UUID) async {
        let action = CXEndCallAction(call: id)
        try? await callController.request(CXTransaction(action: action))
    }

    func reportCallEnded(_ id: UUID, reason: CallEndReason) {
        provider.reportCall(with: id, endedAt: nil, reason: reason.cxReason)
    }

    func setMuted(_ id: UUID, muted: Bool) async {
        let action = CXSetMutedCallAction(call: id, muted: muted)
        try? await callController.request(CXTransaction(action: action))
    }

    func setHeld(_ id: UUID, onHold: Bool) async {
        let action = CXSetHeldCallAction(call: id, onHold: onHold)
        do {
            try await callController.request(CXTransaction(action: action))
        } catch {
            Log.error(.callKit, "CXSetHeldCallAction(onHold: \(onHold)) refused: \(error)")
        }
    }

    /// Every report and update states the call's capabilities: an update that
    /// leaves one unset is not relied on to keep the earlier value.
    private func makeCallUpdate() -> CXCallUpdate {
        let update = CXCallUpdate()
        update.hasVideo = false
        update.supportsHolding = supportsHolding
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        return update
    }

    // MARK: - CXProviderDelegate (system → engine)
    //
    // CXProvider delivers on the main queue (delegate queue is nil), so these
    // nonisolated methods hop onto the main actor via assumeIsolated. They're
    // nonisolated (not @MainActor) so the conformance to Apple's nonisolated
    // CXProviderDelegate doesn't cross actor isolation.

    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated { delegate?.providerWasReset() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // The connection is kicked off by the engine; do NOT start audio here.
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Fulfilling marks the incoming call connected to CallKit (its timer starts);
        // media attaches on the subsequent didActivate, like an outgoing call.
        MainActor.assumeIsolated { delegate?.providerPerformAnswerCall(action.callUUID) }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated { delegate?.providerPerformEndCall(action.callUUID) }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated { delegate?.providerPerformSetMuted(action.callUUID, muted: action.isMuted) }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        let performed = MainActor.assumeIsolated {
            delegate?.providerPerformSetHeld(action.callUUID, onHold: action.isOnHold) ?? false
        }
        if performed { action.fulfill() } else { action.fail() }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            Log.info(.callKit, "CXProvider didActivate audio session")
            delegate?.providerDidActivate(SystemAudioSession(session: audioSession))
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            Log.info(.callKit, "CXProvider didDeactivate audio session")
            delegate?.providerDidDeactivate(SystemAudioSession(session: audioSession))
        }
    }
}

private extension CallEndReason {
    var cxReason: CXCallEndedReason {
        switch self {
        case .remoteEnded: return .remoteEnded
        case .failed: return .failed
        case .unanswered: return .unanswered
        }
    }
}
