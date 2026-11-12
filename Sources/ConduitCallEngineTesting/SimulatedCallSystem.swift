//
//  SimulatedCallSystem.swift
//  ConduitCallEngine
//
//  Stands in for CallKit, PushKit, the audio-interruption source, and ring-status
//  receipts, so a host can run a `CallEngine` in the simulator and in its own tests.
//  It drives what the system would do (deliver a push or a token, answer, end,
//  mute, or hold a call from the system UI, activate and deactivate the audio session,
//  interrupt audio, reset the provider, deliver a transport event) and exposes what
//  the engine reported, in plain types.
//

import Foundation
import ConduitCallEngine

/// The system side of a simulated `CallEngine` (`CallEngine.simulated(system:)`):
/// CallKit, PushKit, audio interruptions and ring-status receipts. A test or a
/// simulator build drives it and reads what the engine reported. Main-actor
/// isolated, like the engine it drives.
@MainActor
public final class SimulatedCallSystem {
    package let provider = FakeCallProvider()
    package let interruptionObserver = FakeAudioInterruptionObserver()
    package let pushRegistry = FakeVoIPPushRegistry()
    package let ringStatusReporter = FakeRingStatusReporter()
    /// The engine this system drives; set by `CallEngine.simulated(...)`.
    package weak var engine: CallEngine?

    /// A system with no engine yet; `CallEngine.simulated(system:)` attaches one.
    public init() {}

    // MARK: - Incoming reports

    /// How CallKit answers an incoming-call report.
    public enum IncomingReportResult: Equatable, Sendable {
        /// The call rings.
        case rings
        /// Focus / Do Not Disturb suppressed the ring.
        case filteredByFocus
        /// CallKit already has a call with this id. The simulated system also
        /// answers this on its own, whatever this property says, for an id it
        /// holds: a call started or reported and not yet ended.
        case duplicateCallID
        /// The report failed for another reason.
        case fails(String)
    }

    /// How CallKit answers the next incoming reports. Default `.rings`.
    public var incomingReportResult: IncomingReportResult {
        get {
            switch provider.reportIncomingError {
            case nil: .rings
            case .filteredByFocus: .filteredByFocus
            case .duplicateCallID: .duplicateCallID
            case .failed(let message): .fails(message)
            }
        }
        set {
            switch newValue {
            case .rings: provider.reportIncomingError = nil
            case .filteredByFocus: provider.reportIncomingError = .filteredByFocus
            case .duplicateCallID: provider.reportIncomingError = .duplicateCallID
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

    /// How many outgoing starts `suspendsOutgoingStarts` is holding.
    public var pendingOutgoingStartCount: Int { provider.pendingStartCount }

    /// Let every held outgoing start finish.
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

    /// PushKit invalidated the token: `voipPushToken` becomes nil and the engine tells
    /// its delegate (`callEngineDidInvalidateVoIPPushToken(_:)`).
    public func invalidateVoIPPushToken() {
        pushRegistry.simulateTokenInvalidation()
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

    /// The user or the system held or resumed `callID` from the system UI (for
    /// example, iOS holds it so the user can take a phone call). Returns whether the
    /// engine performed the action; CallKit fails one it refuses. Returns once the
    /// engine has applied the change to the call's transport (mic, attach and the
    /// agent's signal).
    @discardableResult
    public func setHeldFromSystem(_ callID: UUID, onHold: Bool) async -> Bool {
        let performed = provider.simulateSetHeld(callID, onHold: onHold)
        await engine?.awaitPendingMediaWork()
        await engine?.awaitPendingSignals()
        return performed
    }

    /// The system reset the CallKit provider.
    public func resetProvider() {
        provider.simulateReset()
    }

    // MARK: - Audio session

    /// CallKit activated the call's audio session; returns once the engine has
    /// attached the live call's transport and applied its mic state. CallKit does
    /// this once a started call is accepted, or once an incoming call is answered;
    /// the engine ignores an activation during a ring that has not been answered
    /// (`answerIncomingCall()`), as one left over from an earlier call.
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
    /// state on its next main-actor turn; without it, the mic stays paused until
    /// the session is activated again (or the user unmutes), unless it already was
    /// during the interruption.
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

    /// Wait for the reconnect attempt in flight, if any: the target's `connect` and
    /// the transport's `connect(_:)`, and its backoff unless the attempt is still
    /// waiting it out (run that out with `fireTimer(.reconnectBackoff)` first, or
    /// give `CallEngine.simulated` a `sleep` that returns at once).
    public func awaitPendingReconnect() async {
        await engine?.awaitPendingReconnect()
    }

    /// Wait until the engine has finished the work it started by itself, and the
    /// work that work started: CallKit's audio activation, every attach, detach and
    /// mic command, every call-control signal, route refreshes and the hands-free
    /// default, a call's transport teardown (`detachAudioSession()` and
    /// `disconnect()`), a ring transport's disconnect, and the unprepared connect
    /// after a failed preparation. Call it after any action whose effects reach the
    /// transport on a later main-actor turn: `endCallFromSystem(_:)`,
    /// `setMutedFromSystem(_:muted:)`, `deactivateAudioSession()`, the interruption
    /// methods, `resetProvider()`, `CallEngine.setOnHold(_:)`, `fireTimer(_:)`,
    /// `deliverTransportEvent(_:)`.
    ///
    /// It does not wait for the reconnect attempt (`awaitPendingReconnect()`), the
    /// ring's preparation (`awaitRingPreparation()`), anything waiting on a timer
    /// (`fireTimer(_:)`), or events emitted with `FakeTransport.emit(_:)`. A
    /// `connect` or attach the test holds open (`FakeTransport.suspendConnect`,
    /// `suspendAttach`) keeps it waiting until released.
    public func awaitPendingWork() async {
        await engine?.awaitPendingWork()
    }

    // MARK: - Timers

    /// The engine's timers. Each waits on the `sleep` given to `CallEngine.simulated`,
    /// real time by default, so a test can leave them running and end the one it
    /// wants with `fireTimer(_:)`.
    ///
    /// Open: later versions may add cases.
    public enum EngineTimer: CaseIterable, Sendable {
        /// The ring timeout: `CallEngineConfiguration.ringTimeout`, or the push's
        /// shorter `ring_timeout`.
        case ringTimeout
        /// `CallEngineConfiguration.joinTimeout`: the wait for the agent once a
        /// transport's `connect(_:)` has returned, on a call's first connect, a
        /// reconnect attempt, or a ring's join.
        case joinTimeout
        /// The 30 seconds a transport that reported `.reconnecting` is given before
        /// the engine reconnects by itself.
        case transportHealTimeout
        /// The backoff before the next reconnect attempt.
        case reconnectBackoff
        /// The wait before the engine sends the call's state again after a signal
        /// did not leave the device (`CallSignalDelivery.failed`).
        case signalRetry
        /// `CallEngineConfiguration.micWithholdTimeout`: the bound on the host's
        /// `CallEngine.setMicWithheld(true)`, running once the call is connected
        /// with its audio activated. Firing it releases the withhold, as the engine
        /// does when the bound runs out.
        case micWithholdTimeout
        /// The rest of `CallEngineConfiguration.minimumConnectingDuration`, running
        /// while the transport has reported `.connected` and the engine holds the
        /// call in `.connecting`. Firing it reports the call connected now.
        case minimumConnectingDuration
    }

    /// Run `timer` out now, as if its wait were over, if it is running: the engine
    /// does exactly what it does when that wait ends, at this moment. Returns whether
    /// the timer was running. Its effects that reach the transport come on later
    /// main-actor turns; wait for them with `awaitPendingWork()`, or, for
    /// `.reconnectBackoff`, `awaitPendingReconnect()`.
    @discardableResult
    public func fireTimer(_ timer: EngineTimer) -> Bool {
        guard let engine else { return false }
        switch timer {
        case .ringTimeout: return engine.fireTimer(.ringTimeout)
        case .joinTimeout: return engine.fireTimer(.joinTimeout)
        case .transportHealTimeout: return engine.fireTimer(.selfHealTimeout)
        case .reconnectBackoff: return engine.fireTimer(.reconnectBackoff)
        case .signalRetry: return engine.fireTimer(.signalRetry)
        case .micWithholdTimeout: return engine.fireTimer(.micWithholdTimeout)
        case .minimumConnectingDuration: return engine.fireTimer(.minimumConnecting)
        }
    }

    /// Wait until the ringing call's preparation (pre-connect, `RingPreparation`) has
    /// done what it does by itself, and return `CallEngine.ringPreparationPhase` then:
    /// the target's `connect` for the ring has returned and, at the `.media` tier,
    /// the ring transport's `connect(_:)` has returned too. The phase is then
    /// `.credentialsReady`, `.connecting` (joined and waiting for the agent: deliver
    /// `.connected` with `deliverTransportEvent(_:)` to make it `.ready`), `.ready`,
    /// `.failed` or `.idle`. Returns at once when nothing is being prepared,
    /// including before CallKit has accepted the ring's report (see
    /// `completesIncomingReportsLater`); a `connect` your test holds open keeps it
    /// waiting. Events a `FakeTransport` emits with `emit(_:)` arrive asynchronously,
    /// so they may not be reflected yet.
    @discardableResult
    public func awaitRingPreparation() async -> RingPreparationPhase {
        await engine?.awaitPendingRingPreparation()
        return engine?.ringPreparationPhase ?? .idle
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
        /// `answered`, `declined`, `busy`, `suppressed_by_focus`, `unanswered` or `canceled`.
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

    /// A hold or resume the engine requested from CallKit (`CallEngine.setOnHold(_:)`).
    public struct HoldRequest: Equatable, Sendable {
        public let callID: UUID
        public let onHold: Bool

        public init(callID: UUID, onHold: Bool) {
            self.callID = callID
            self.onHold = onHold
        }
    }

    /// Every hold or resume the engine requested, in order. The simulated system
    /// performs each one through the engine, as CallKit does, for a call it holds
    /// that was reported as holdable.
    public var holdRequests: [HoldRequest] {
        provider.heldRequests.map { HoldRequest(callID: $0.id, onHold: $0.onHold) }
    }

    /// Whether the engine last reported `callID` to CallKit as holdable; nil for a
    /// call it never reported.
    public func reportedSupportsHolding(_ callID: UUID) -> Bool? {
        provider.holdableCalls[callID]
    }

    /// The CallKit ids of the outgoing calls the engine started, in order.
    public var startedCallIDs: [UUID] { provider.startedCalls }

    /// The incoming calls the engine reported to CallKit, in order, as each push asked.
    public var reportedIncomingCalls: [ReportedCall] {
        provider.reportedIncoming.map { ReportedCall(id: $0.id, handle: $0.handle.value, displayName: $0.displayName) }
    }

    /// The rings the engine corrected to its resolved target's name or handle, in order.
    public var updatedCalls: [ReportedCall] {
        provider.updatedCalls.map { ReportedCall(id: $0.id, handle: $0.handle.value, displayName: $0.displayName) }
    }

    /// The ring-status receipts the engine sent, in order.
    public var ringReceipts: [RingReceipt] {
        ringStatusReporter.reports.map {
            RingReceipt(status: $0.status.rawValue, callID: $0.callID, endpoint: $0.endpoint, bearer: $0.apiKey)
        }
    }
}
