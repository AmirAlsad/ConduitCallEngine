//
//  SimulatedCallSystem.swift
//  ConduitCallEngine
//
//  Stands in for CallKit, PushKit, the audio-interruption source, and ring-status
//  receipts, so a host can run a `CallEngine` in the simulator and in its own tests.
//  It drives what the system would do (deliver a push or a token, answer, end, or
//  mute a call from the system UI, activate and deactivate the audio session,
//  interrupt audio, reset the provider, deliver a transport event) and exposes what
//  the engine reported, in plain types.
//

import Foundation
import ConduitCallEngine

@MainActor
public final class SimulatedCallSystem {
    package let provider = FakeCallProvider()
    package let interruptionObserver = FakeAudioInterruptionObserver()
    package let pushRegistry = FakeVoIPPushRegistry()
    package let ringStatusReporter = FakeRingStatusReporter()
    /// The engine this system drives; set by `CallEngine.simulated(...)`.
    package weak var engine: CallEngine?

    public init() {}

    // MARK: - Incoming reports

    /// How CallKit answers an incoming-call report.
    public enum IncomingReportResult: Equatable, Sendable {
        /// The call rings.
        case rings
        /// Focus / Do Not Disturb suppressed the ring.
        case filteredByFocus
        /// The report failed for another reason.
        case fails(String)
    }

    public var incomingReportResult: IncomingReportResult {
        get {
            switch provider.reportIncomingError {
            case nil: .rings
            case .filteredByFocus: .filteredByFocus
            case .failed(let message): .fails(message)
            }
        }
        set {
            switch newValue {
            case .rings: provider.reportIncomingError = nil
            case .filteredByFocus: provider.reportIncomingError = .filteredByFocus
            case .fails(let message): provider.reportIncomingError = .failed(message)
            }
        }
    }

    /// When true, incoming reports complete only on `completeIncomingReports()`;
    /// when false (the default) they complete before the report returns. Real
    /// CallKit always completes later, after the push callback has returned, so the
    /// default trades realism for convenience: set this to exercise a host against
    /// the ordering a device produces (for example, an answer that arrives before
    /// CallKit has accepted the report).
    public var completesIncomingReportsLater: Bool {
        get { provider.completesIncomingReportsLater }
        set { provider.completesIncomingReportsLater = newValue }
    }

    /// Deliver every held incoming-report completion, in report order.
    public func completeIncomingReports() {
        provider.completeIncomingReports()
    }

    // MARK: - Outgoing starts

    /// When true, starting an outgoing call waits for `releaseOutgoingStarts()`.
    public var suspendsOutgoingStarts: Bool {
        get { provider.suspendStart }
        set { provider.suspendStart = newValue }
    }

    public var pendingOutgoingStartCount: Int { provider.pendingStartCount }

    public func releaseOutgoingStarts() {
        provider.releaseStart()
    }

    /// While set, every outgoing start throws this, as a rejected `CXStartCallAction`
    /// does; the engine then fails the call.
    public var outgoingStartError: (any Error)? {
        get { provider.startError }
        set { provider.startError = newValue }
    }

    // MARK: - System actions

    /// PushKit delivered a VoIP push. Requires `startPushRegistration()` on the engine.
    public func deliverPush(_ payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        pushRegistry.simulateIncomingPush(payload, completion: completion)
    }

    /// PushKit issued (or rotated) the VoIP token.
    public func deliverVoIPPushToken(_ token: Data) {
        pushRegistry.simulateTokenUpdate(token)
    }

    /// The VoIP token the system currently holds, without delivering an update.
    public var voipPushToken: Data? {
        get { pushRegistry.pushToken }
        set { pushRegistry.pushToken = newValue }
    }

    /// The user answered the ringing call; returns once the connect attempt has run.
    public func answerIncomingCall() async {
        await engine?.answer()
    }

    /// The user ended (or declined) the call from the system UI.
    public func endCallFromSystem(_ callID: UUID) {
        provider.simulateEndCall(callID)
    }

    /// The user toggled mute for `callID` from the system UI.
    public func setMutedFromSystem(_ callID: UUID, muted: Bool) {
        provider.simulateSetMuted(callID, muted: muted)
    }

    /// The system reset the CallKit provider.
    public func resetProvider() {
        provider.simulateReset()
    }

    // MARK: - Audio session

    /// CallKit activated the call's audio session; returns once the engine has
    /// attached the live call's transport and applied its mic state. CallKit does
    /// this once a started call is accepted, or once an incoming call is answered.
    public func activateAudioSession() async {
        provider.simulateActivate(FakeAudioSession())
        await engine?.awaitPendingActivation()
    }

    /// CallKit deactivated the call's audio session. The engine detaches the live
    /// call's transport on its next main-actor turn.
    public func deactivateAudioSession() {
        provider.simulateDeactivate(FakeAudioSession())
    }

    /// Another audio session (Siri, a phone call, navigation) interrupted the call.
    /// The engine pauses the mic on its next main-actor turn.
    public func beginAudioInterruption() {
        interruptionObserver.simulateBegan()
    }

    /// The interruption ended. With `shouldResume`, the engine re-applies the mic
    /// state on its next main-actor turn; without it, the mic stays paused.
    public func endAudioInterruption(shouldResume: Bool) {
        interruptionObserver.simulateEnded(shouldResume: shouldResume)
    }

    // MARK: - Transport

    /// The live call's transport emitted `event`, delivered synchronously. Delivered
    /// only while a call has a transport, the only time a real transport's events
    /// reach the engine; returns whether it was delivered.
    @discardableResult
    public func deliverTransportEvent(_ event: TransportEvent) -> Bool {
        guard let engine, engine.hasTransport else { return false }
        engine.handle(event)
        return true
    }

    /// Wait for the reconnect attempt in flight, if any.
    public func awaitPendingReconnect() async {
        await engine?.awaitPendingReconnect()
    }

    // MARK: - Screenshots

    /// Show a connected call on the engine's observed state without CallKit, a
    /// transport, or any delegate callback, so an in-call screen can be captured.
    /// Returns false, and changes nothing, when no simulated engine is attached.
    @discardableResult
    public func presentConnectedCall(
        _ call: ActiveCall,
        secondsElapsed: TimeInterval = 154,
        botSpeaking: Bool = true
    ) -> Bool {
        engine?.presentConnectedProjection(call, secondsElapsed: secondsElapsed, botSpeaking: botSpeaking) ?? false
    }

    // MARK: - Observations

    /// A call as the engine reported it to CallKit.
    public struct ReportedCall: Equatable, Sendable {
        public let id: UUID
        public let handle: String
        public let displayName: String

        public init(id: UUID, handle: String, displayName: String) {
            self.id = id
            self.handle = handle
            self.displayName = displayName
        }
    }

    /// A ring-status receipt the engine sent.
    public struct RingReceipt: Equatable, Sendable {
        /// `answered`, `declined`, `busy`, or `suppressed_by_focus`.
        public let status: String
        public let callID: UUID
        public let endpoint: URL
        public let bearer: String

        public init(status: String, callID: UUID, endpoint: URL, bearer: String) {
            self.status = status
            self.callID = callID
            self.endpoint = endpoint
            self.bearer = bearer
        }
    }

    /// The CallKit ids of the outgoing calls the engine started, in order.
    public var startedCallIDs: [UUID] { provider.startedCalls }

    public var reportedIncomingCalls: [ReportedCall] {
        provider.reportedIncoming.map { ReportedCall(id: $0.id, handle: $0.handle.value, displayName: $0.displayName) }
    }

    public var updatedCalls: [ReportedCall] {
        provider.updatedCalls.map { ReportedCall(id: $0.id, handle: $0.handle.value, displayName: $0.displayName) }
    }

    public var ringReceipts: [RingReceipt] {
        ringStatusReporter.reports.map {
            RingReceipt(status: $0.status.rawValue, callID: $0.callID, endpoint: $0.endpoint, bearer: $0.apiKey)
        }
    }
}
