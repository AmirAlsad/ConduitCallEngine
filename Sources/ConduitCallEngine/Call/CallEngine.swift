//
//  CallEngine.swift
//  ConduitCallEngine
//
//  The call state machine: it orchestrates the CallKit
//  seam (`CallProviding`) and the transport seam (`CallTransport`), owns `CallState`,
//  and drives reconnection. It knows calls, not the host's models: the host hands
//  it a `CallTarget` and hears back through `CallEngineDelegate` (transitions, finished
//  calls, incoming-target resolution, receipt bearers). It depends only on
//  protocols, so the whole machine runs in the simulator against fakes.
//
//  AUDIO-SESSION OWNERSHIP INVARIANT: `transport.attachAudioSession()` is called
//  only once CallKit has activated the session — from `activate(_:)` (the
//  `providerDidActivate` callback), or when a transport is created after that
//  activation already happened — and the mic is never enabled before activation.
//  CallKit owns the session; the transport attaches to it.
//

import Foundation

@MainActor
@Observable
public final class CallEngine: CallProviderDelegate, AudioInterruptionObserverDelegate {

    // MARK: - Observed state (a host's in-call UI can be a pure projection of these)

    public private(set) var state: CallState = .idle
    public private(set) var activeCall: ActiveCall?
    public private(set) var isMuted = false
    public private(set) var isBotSpeaking = false
    package private(set) var remoteAudioLevel: Float = 0
    /// Whether CallKit has activated the audio session for the call in progress.
    /// Cleared when that call ends.
    public private(set) var isAudioActivated = false
    /// Whether another audio session (Siri, a phone call, navigation) is currently
    /// interrupting the call. Transient — the mic pauses while true.
    public private(set) var isInterrupted = false
    /// Available audio routes and the active one, for the in-call route picker.
    public private(set) var audioDevices: [AudioDeviceInfo] = []
    public private(set) var selectedAudioDeviceID: String?
    /// True once the host ends the call through `markEndedByUser()` or `endCall()`;
    /// false for a remote hangup, a failure, or an end from the system UI. Lets a
    /// host dismiss a call its user ended at once while still showing other
    /// endings. Cleared on reset.
    public private(set) var endedByUser = false
    /// The looping cue that should be playing now, if any: the last `CallCue.start`
    /// not yet followed by a `stop`. Lets a UI that attaches mid-call pick the loop
    /// up without having seen the cue. Updated before the cue is delivered.
    public private(set) var repeatingCue: RepeatingCue?

    // MARK: - Dependencies

    @ObservationIgnored public weak var delegate: CallEngineDelegate?

    private let configuration: CallEngineConfiguration
    private let callProvider: CallProviding
    private let interruptionObserver: AudioInterruptionObserving
    private let ringStatusReporter: RingStatusReporting
    private let pushRegistry: VoIPPushRegistering
    private let policy: ReconnectionPolicy
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void
    private let isSimulated: Bool
    private var isPushRegistrationStarted = false

    /// The caller name a ring shows until (unless) its target is resolved.
    private var unknownCallerName: String { configuration.unknownCallerName }
    private func isPushToTalkEnabled() -> Bool { configuration.isPushToTalkEnabled() }

    // MARK: - Live-call bookkeeping

    private var transport: CallTransport?
    /// The resolved target of the live call; its `connect` runs per attempt.
    private var currentTarget: CallTarget?
    /// Who this call's record is attributed to — set even when an incoming
    /// target is unknown, so the host can decide there is nothing to record.
    private var recordTargetID: UUID?
    private var activeCallID: UUID?
    private var callDirection: CallDirection = .outgoing
    /// Where to report this ring's terminal status, when the push asked for receipts.
    private var ringStatusURL: URL?
    private var callStartedAt: Date?
    private var firstConnectedAt: Date?
    private var reconnectAttempt = 0
    private var didApplyHandsFreeDefault = false
    /// Whether the push-to-talk button is held (push-to-talk mode only).
    private var isPushToTalkHeld = false
    private var eventTask: Task<Void, Never>?
    package private(set) var reconnectTask: Task<Void, Never>?
    /// Ends the wait for a transport that is healing itself; see `enterReconnectingDisplay`.
    private var selfHealDeadlineTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    /// Ends the ring if nobody answers it in time; see `startRingTimer`.
    private var ringTimerTask: Task<Void, Never>?
    /// Set the moment CallKit delivers the answer action for the ringing call, before
    /// `answer()` runs, so neither the ring timer nor a cancel ends an answered ring.
    private var isAnswerRequested = false
    /// Calls the sender cancelled, newest last, so a ring that arrives after its
    /// own cancel is ended at once. Survives across calls.
    private var canceledCallIDs: [(id: UUID, at: Date)] = []
    /// Identifies the outgoing call a suspended `placeCall` belongs to, so its
    /// continuation can tell it has been superseded (reset, or a newer call).
    private var dialToken = UUID()

    /// The real engine: CallKit, the system audio-interruption observer, PushKit,
    /// and HTTP ring-status receipts. Device-only (CallKit doesn't run in the simulator).
    public convenience init(configuration: CallEngineConfiguration = .init()) {
        self.init(
            configuration: configuration,
            callProvider: SystemCallProvider(),
            interruptionObserver: SystemAudioInterruptionObserver(),
            ringStatusReporter: RingStatusReporter(),
            pushRegistry: SystemVoIPPushRegistry(),
            now: { .now },
            sleep: { try await Task.sleep(for: $0) }
        )
    }

    /// Every service injected — for tests and the simulator's fakes.
    package init(
        configuration: CallEngineConfiguration = .init(),
        callProvider: CallProviding,
        interruptionObserver: AudioInterruptionObserving,
        ringStatusReporter: RingStatusReporting,
        pushRegistry: VoIPPushRegistering,
        policy: ReconnectionPolicy = .default,
        now: @escaping () -> Date,
        sleep: @escaping (Duration) async throws -> Void,
        isSimulated: Bool = false
    ) {
        self.configuration = configuration
        self.callProvider = callProvider
        self.interruptionObserver = interruptionObserver
        self.ringStatusReporter = ringStatusReporter
        self.pushRegistry = pushRegistry
        self.policy = policy
        self.now = now
        self.sleep = sleep
        self.isSimulated = isSimulated
        callProvider.delegate = self
        interruptionObserver.delegate = self
    }

    // MARK: - VoIP push registration

    /// Start receiving VoIP pushes and request the token. Call once, early in
    /// launch — before the first push can arrive; later calls do nothing.
    ///
    /// From here on the engine keeps itself alive for the rest of the process,
    /// even if the host releases it: iOS terminates an app that receives a VoIP
    /// push without reporting a call, and only the engine can report one.
    public func startPushRegistration() {
        guard !isPushRegistrationStarted else { return }
        isPushRegistrationStarted = true
        pushRegistry.start(
            onTokenUpdate: { [weak self] token in
                guard let self else { return }
                delegate?.callEngine(self, didUpdateVoIPPushToken: token)
            },
            // Strong on purpose: the registry this engine owns now holds the engine.
            onIncomingPush: { payload, completion in
                self.handleIncomingPush(payload, completion: completion)
            }
        )
    }

    /// The device's current VoIP push token, once PushKit has issued one.
    public var voipPushToken: Data? { pushRegistry.pushToken }

    // MARK: - Placing a call

    public func placeCall(_ target: CallTarget) async {
        // A finished call the host has not reset yet gives way to the new one.
        if state.isTerminal { resetState() }
        guard case .idle = state else {
            Log.warning(.call, "placeCall ignored; state is \(String(describing: state))")
            return
        }

        let token = UUID()
        dialToken = token
        currentTarget = target
        recordTargetID = target.id
        activeCall = ActiveCall(targetID: target.id, displayName: target.displayName, direction: .outgoing)
        callDirection = .outgoing
        callStartedAt = now()
        transition(to: .dialing)
        interruptionObserver.startObserving()

        let id: UUID
        do {
            id = try await callProvider.startOutgoingCall(handle: callHandle(for: target), displayName: target.displayName)
        } catch {
            Log.error(.callkit, "startOutgoingCall failed: \(error)")
            // Only this call can fail here — not one that was reset or replaced meanwhile.
            guard isStillDialing(token) else { return }
            fail(.unknown)
            return
        }
        // The user may have ended the call while CallKit was starting it (that end
        // already finished and recorded it), or it was reset or replaced. Don't
        // leave the system holding the call it just started, and don't join the room.
        guard isStillDialing(token) else {
            Log.info(.call, "Call ended while dialing; ending the started CallKit call")
            await callProvider.endCall(id)
            return
        }
        activeCallID = id
        callProvider.reportOutgoingCallConnecting(id)
        transition(to: .connecting)

        await connectTransport(for: target)
    }

    private func isStillDialing(_ token: UUID) -> Bool {
        guard case .dialing = state else { return false }
        return dialToken == token
    }

    private func callHandle(for target: CallTarget) -> CallHandle {
        CallHandle(value: target.handle ?? CallTarget.defaultHandle(for: target.id))
    }

    // MARK: - Receiving a call (via VoIP push)

    /// The PushKit entry point. iOS terminates the host if a VoIP push doesn't
    /// report an incoming call before the push callback returns, so every path
    /// reports FIRST — synchronously, under the identity the push itself carries —
    /// and only then touches state or the delegate. `completion` (PushKit's) runs
    /// exactly once, after the report's completion, on every path.
    package func handleIncomingPush(_ dictionary: [AnyHashable: Any], completion: @escaping () -> Void) {
        switch VoIPPushRequest(dictionary: dictionary) {
        case .ring(let payload): handleRingPush(payload, completion: completion)
        case .cancel(let cancel): handleCancelPush(cancel, completion: completion)
        case .malformed: handleMalformedPush(completion: completion)
        }
    }

    /// Report a call to CallKit, run `setUp` at once, and then — once both the
    /// report's completion has arrived and `setUp` has run, in that order whatever
    /// order CallKit completes in — run `verdict` and PushKit's `completion`.
    private func reportIncomingCall(
        id: UUID,
        handle: String,
        displayName: String,
        completion: @escaping () -> Void,
        setUp: () -> Void,
        verdict: @escaping (IncomingCallReportError?) -> Void
    ) {
        // The report's completion may arrive before this method finishes (a fake
        // completes synchronously); hold it until `setUp` has run.
        var isSetUp = false
        var earlyResult: IncomingCallReportError??
        let finish: (IncomingCallReportError?) -> Void = { result in
            verdict(result)
            completion()
        }
        callProvider.reportIncomingCall(
            id: id,
            handle: CallHandle(value: handle),
            displayName: displayName
        ) { result in
            if isSetUp { finish(result) } else { earlyResult = .some(result) }
        }
        setUp()
        isSetUp = true
        if let earlyResult { finish(earlyResult) }
    }

    private func handleMalformedPush(completion: @escaping () -> Void) {
        let id = UUID()
        Log.warning(.callkit, "Malformed VoIP push; reporting call \(id) and ending it")
        reportIncomingCall(
            id: id,
            handle: CallTarget.defaultHandle(for: id),
            displayName: unknownCallerName,
            completion: completion,
            setUp: {},
            verdict: { [self] _ in callProvider.reportCallEnded(id, reason: .failed) }
        )
    }

    /// A ring. The target is resolved right after the report is issued; once
    /// CallKit accepts it, the ring is corrected if the target's name or handle differ.
    private func handleRingPush(_ payload: IncomingCallPayload, completion: @escaping () -> Void) {
        let incoming = IncomingCall(
            callID: payload.callID,
            targetID: payload.targetID,
            displayName: payload.displayName ?? unknownCallerName,
            handle: payload.handle ?? CallTarget.defaultHandle(for: payload.targetID),
            connection: payload.inlineConnection
        )
        // One call at a time: a push during a live (or ringing) call is reported,
        // then ended at once, without touching that call.
        let isBusy: Bool
        switch state {
        case .idle, .ended, .failed: isBusy = false
        default: isBusy = true
        }
        // A second delivery of the push for the call in progress is not another
        // ring. It is reported, because PushKit requires it, and nothing else: no
        // end (it would end the call in progress), no record, no receipt.
        let isDuplicate = isBusy && incoming.callID == activeCallID
        // The sender already withdrew this ring (APNs delivered the cancel first,
        // or delivered the ring again): end it at once, as nothing more than the
        // flash PushKit forces.
        let wasCanceled = !isDuplicate && isRememberedCancel(incoming.callID)

        var ringTarget: CallTarget?
        reportIncomingCall(
            id: incoming.callID,
            handle: incoming.handle,
            displayName: incoming.displayName,
            completion: completion,
            setUp: {
                if isDuplicate {
                    Log.warning(.call, "Duplicate VoIP push for the call in progress; reported call \(incoming.callID), ignoring it")
                } else if wasCanceled {
                    Log.info(.call, "VoIP push for cancelled call \(incoming.callID); reported it, ending it")
                } else if isBusy {
                    Log.warning(.call, "Busy on VoIP push; reported call \(incoming.callID), ending it")
                } else {
                    ringTarget = beginRing(incoming, payload: payload)
                }
            },
            verdict: { [self] result in
                if isDuplicate {
                    Log.info(.call, "Duplicate push for call \(incoming.callID); report result: \(String(describing: result))")
                } else if wasCanceled {
                    // Only a call CallKit created can be ended.
                    if result == nil { callProvider.reportCallEnded(incoming.callID, reason: .remoteEnded) }
                } else if isBusy {
                    completeBusyRing(incoming, payload: payload, result: result)
                } else {
                    completeRing(incoming, target: ringTarget, result: result)
                }
            }
        )
    }

    /// The sender withdraws a ring. Reported under its `call_id` first, like any
    /// push: CallKit refuses that as a duplicate when it still holds the call. A
    /// ring the user has not answered is then ended as the caller's hangup and
    /// recorded as missed; the call in progress is left alone; for an id the engine
    /// does not know, the report rang, so it is ended at once.
    private func handleCancelPush(_ cancel: CancelCallPayload, completion: @escaping () -> Void) {
        let id = cancel.callID
        let isCallInProgress = activeCallID == id
        let isUnansweredRing = isCallInProgress && state == .incomingRinging && !isAnswerRequested

        reportIncomingCall(
            id: id,
            handle: CallTarget.defaultHandle(for: id),
            displayName: cancel.displayName ?? (isCallInProgress ? activeCall?.displayName : nil) ?? unknownCallerName,
            completion: completion,
            setUp: { [self] in
                rememberCancel(id)
                if isUnansweredRing {
                    Log.info(.call, "Caller cancelled ringing call \(id)")
                    endMissedRing(.canceledByCaller, callKitReason: .remoteEnded, receipt: .canceled)
                } else if isCallInProgress {
                    Log.info(.call, "Cancel for call \(id), which is past ringing; ignored")
                } else {
                    Log.info(.call, "Cancel for unknown call \(id); reported it, ending it")
                }
            },
            verdict: { [self] result in
                // CallKit did not hold the id, so the report started a new call
                // (the flash Apple warns about): end it.
                if result == nil { callProvider.reportCallEnded(id, reason: .remoteEnded) }
            }
        )
    }

    /// Remember `id` as cancelled, keeping only the newest within the lifetime.
    private func rememberCancel(_ id: UUID) {
        pruneRememberedCancels()
        canceledCallIDs.removeAll { $0.id == id }
        canceledCallIDs.append((id, now()))
        if canceledCallIDs.count > Self.rememberedCancelLimit {
            canceledCallIDs.removeFirst(canceledCallIDs.count - Self.rememberedCancelLimit)
        }
    }

    private func isRememberedCancel(_ id: UUID) -> Bool {
        pruneRememberedCancels()
        return canceledCallIDs.contains { $0.id == id }
    }

    private func pruneRememberedCancels() {
        let cutoff = now().addingTimeInterval(-Self.rememberedCancelLifetime)
        canceledCallIDs.removeAll { $0.at < cutoff }
    }

    /// Set up the ring once its report is issued. The target is resolved here,
    /// not when CallKit completes the report, because the user can answer before
    /// that completion reaches the main actor.
    private func beginRing(_ incoming: IncomingCall, payload: IncomingCallPayload) -> CallTarget? {
        // A finished call the host has not reset yet gives way to the ring.
        if state.isTerminal { resetState() }
        let target = delegate?.callEngine(self, targetForIncomingCall: incoming)
        currentTarget = target
        activeCallID = incoming.callID
        recordTargetID = incoming.targetID
        activeCall = ActiveCall(
            targetID: incoming.targetID,
            displayName: target?.displayName ?? incoming.displayName,
            direction: .incoming
        )
        callDirection = .incoming
        callStartedAt = now()
        // Receipts go only to a server ringing a target the host knows: for any
        // other, the push-supplied URL is untrusted and has no bearer.
        ringStatusURL = target == nil ? nil : payload.statusURL
        transition(to: .incomingRinging)
        interruptionObserver.startObserving()
        if let timeout = ringTimeout(requestedSeconds: payload.ringTimeoutSeconds) {
            startRingTimer(for: incoming.callID, after: timeout)
        }
        return target
    }

    /// The host's timeout, shortened (never lengthened) by the push's request,
    /// which is raised to the minimum first. nil when neither sets one.
    private func ringTimeout(requestedSeconds: Int?) -> Duration? {
        let requested = requestedSeconds.map { max(Duration.seconds($0), Self.minimumPushedRingTimeout) }
        switch (configuration.ringTimeout, requested) {
        case let (configured?, requested?): return min(configured, requested)
        case let (configured, requested): return configured ?? requested
        }
    }

    private func startRingTimer(for id: UUID, after timeout: Duration) {
        cancelRingTimer()
        let sleep = self.sleep
        ringTimerTask = Task { [weak self] in
            try? await sleep(timeout)
            guard let self, !Task.isCancelled else { return }
            self.ringTimedOut(id)
        }
    }

    private func cancelRingTimer() {
        ringTimerTask?.cancel()
        ringTimerTask = nil
    }

    /// Only the same ring, still ringing, with no answer action delivered, times out.
    private func ringTimedOut(_ id: UUID) {
        guard activeCallID == id, state == .incomingRinging, !isAnswerRequested else { return }
        Log.info(.call, "Ring \(id) timed out unanswered")
        endMissedRing(.ringTimedOut, callKitReason: .unanswered, receipt: .unanswered)
    }

    /// End a ring that reached the user but was never answered (it timed out, or the
    /// caller withdrew it): ended in CallKit, recorded as missed, receipted, and
    /// back to idle without an active state, like a ring Focus filtered.
    private func endMissedRing(_ reason: MissedCallReason, callKitReason: CallEndReason, receipt: RingStatus) {
        guard let id = activeCallID else { return }
        cancelRingTimer()
        callProvider.reportCallEnded(id, reason: callKitReason)
        interruptionObserver.stopObserving()
        finish(outcome: .noAnswer, missedReason: reason)
        if let url = ringStatusURL {
            reportRingStatus(receipt, callID: id, endpoint: url, targetID: recordTargetID)
        }
        resetState()
    }

    /// CallKit's verdict on the report. By now the call may already be answered;
    /// only what depends on the verdict happens here.
    private func completeRing(_ incoming: IncomingCall, target: CallTarget?, result: IncomingCallReportError?) {
        // The ring may already be over (declined, the provider reset) or replaced.
        guard activeCallID == incoming.callID else { return }

        if result != nil {
            // A ring that was filtered or rejected never reached the user, so it
            // can't have been answered — but never let a late verdict touch a call
            // that is past ringing.
            guard case .incomingRinging = state else { return }
        }
        switch result {
        case .filteredByFocus:
            // The system suppressed the ring (Focus/DND) — a missed call, not a
            // failure. Record it and return to idle so the next push rings normally.
            Log.info(.call, "Incoming call filtered by Focus; recording as missed")
            interruptionObserver.stopObserving()
            finish(outcome: .noAnswer, missedReason: .filteredByFocus)
            if let url = ringStatusURL {
                reportRingStatus(.suppressedByFocus, callID: incoming.callID, endpoint: url, targetID: incoming.targetID)
            }
            resetState()

        case .failed(let message):
            Log.error(.callkit, "reportIncomingCall failed: \(message)")
            endRingThatCannotProceed()

        case .duplicateCallID:
            // CallKit holds a call under this id that is not this ring, so the
            // report created nothing to end, and ending the id would end that call.
            Log.error(.callkit, "reportIncomingCall refused: call id \(incoming.callID) already exists")
            endRingThatCannotProceed(reportToCallKit: false)

        case nil:
            guard let target else {
                Log.error(.call, "Incoming call for unknown target \(incoming.targetID)")
                endRingThatCannotProceed()
                return
            }
            correctRingIfNeeded(incoming, to: target)
        }
    }

    /// A ring that cannot become a call (its target is unknown, CallKit refused the
    /// report, or the provider reset) is over before the user could take it. Like a
    /// ring Focus filtered, it is recorded and the engine returns to idle, never
    /// entering an active state.
    private func endRingThatCannotProceed(reportToCallKit: Bool = true) {
        if reportToCallKit, let id = activeCallID { callProvider.reportCallEnded(id, reason: .failed) }
        interruptionObserver.stopObserving()
        finish(outcome: .failed, failureReason: .unknown)
        resetState()
    }

    private func completeBusyRing(_ incoming: IncomingCall, payload: IncomingCallPayload, result: IncomingCallReportError?) {
        let target = delegate?.callEngine(self, targetForIncomingCall: incoming)
        if result == nil {
            if let target { correctRingIfNeeded(incoming, to: target) }
            // Only a call CallKit created can be ended; a failed report created nothing.
            callProvider.reportCallEnded(incoming.callID, reason: .unanswered)
        }
        delegate?.callEngine(self, didFinish: CallRecord(
            targetID: incoming.targetID,
            direction: .incoming,
            startedAt: now(),
            duration: 0,
            outcome: .noAnswer,
            missedReason: .busy
        ))
        if target != nil, let url = payload.statusURL {
            reportRingStatus(.busy, callID: incoming.callID, endpoint: url, targetID: incoming.targetID)
        }
    }

    /// Local truth wins: show the resolved target's name and handle when the push
    /// rang under different ones.
    private func correctRingIfNeeded(_ incoming: IncomingCall, to target: CallTarget) {
        let handle = callHandle(for: target)
        guard target.displayName != incoming.displayName || handle.value != incoming.handle else { return }
        callProvider.updateCall(incoming.callID, handle: handle, displayName: target.displayName)
    }

    /// The user answered (from the system UI). Connect the transport with the
    /// resolved target's credentials (the push's inline room, or the host's own).
    package func answer() async {
        guard case .incomingRinging = state, let target = currentTarget else { return }
        cancelRingTimer()
        // Answering is the ring's terminal status — the receipt fires here whether
        // or not the transport subsequently connects, and before the ringback starts.
        if let url = ringStatusURL, let id = activeCallID {
            reportRingStatus(.answered, callID: id, endpoint: url, targetID: target.id)
            ringStatusURL = nil
        }
        transition(to: .connecting)
        await connectTransport(for: target)
    }

    /// Fire-and-forget receipt to the server that sent the push, authenticated with the
    /// bearer the host supplies for the target (omitted when it has none).
    private func reportRingStatus(_ status: RingStatus, callID: UUID, endpoint: URL, targetID: UUID?) {
        let apiKey = targetID.flatMap { delegate?.callEngine(self, ringStatusBearerForTarget: $0) }
        ringStatusReporter.report(status, callID: callID, endpoint: endpoint, apiKey: apiKey ?? "")
    }

    /// Create and subscribe the transport, then resolve credentials and connect.
    /// Shared by `placeCall` and `answer`. The transport exists before the
    /// credential fetch so a CallKit activation landing mid-fetch still reaches
    /// `attachAudioSession()`.
    private func connectTransport(for target: CallTarget) async {
        let transport = target.makeTransport()
        self.transport = transport
        subscribe(to: transport)
        // CallKit can activate before the transport exists (while dialing, or
        // before `answer()` runs); that activation found no transport to attach.
        if isAudioActivated {
            await transport.attachAudioSession()
            guard self.transport === transport else { return }
        }

        do {
            let connection = try await target.connect()
            // The call may have ended while credentials were in flight.
            guard self.transport === transport else { return }
            try await transport.connect(connection)
        } catch {
            Log.error(.transport, "connect failed: \(error)")
            // `connect` can resolve LATE — after an event already failed this call and
            // the user reset to idle (or started another call). Failing again would
            // re-enter `.failed` and replace the newer state. Ignore unless this is
            // still the live transport.
            guard self.transport === transport else { return }
            fail((error as? TransportError) == .authenticationFailed ? .badToken : .transportError)
        }
    }

    private func subscribe(to transport: CallTransport) {
        eventTask?.cancel()
        let events = transport.events
        eventTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    // MARK: - Transport events (the transition table)

    package func handle(_ event: TransportEvent) {
        switch event {
        case .connecting:
            break // already reflected by `.connecting` / `.reconnecting`

        case .connected:
            handleConnected()

        case .reconnecting:
            // The transport is self-healing; reflect it without driving our own loop.
            if case .connected = state { enterReconnectingDisplay() }

        case .disconnected(let reason):
            handleDisconnect(reason)

        case .botStartedSpeaking:
            isBotSpeaking = true

        case .botStoppedSpeaking:
            isBotSpeaking = false

        case .userStartedSpeaking, .userStoppedSpeaking:
            break

        case .remoteAudioLevel(let level):
            remoteAudioLevel = level

        case .audioDevicesChanged:
            scheduleAudioDeviceUpdate()

        case .error(let error):
            handleError(error)
        }
    }

    private func handleConnected() {
        switch state {
        case .connecting:
            let start = now()
            firstConnectedAt = start
            // Incoming calls are marked connected to CallKit by fulfilling the answer
            // action; only outgoing calls report connected here — before the host's
            // "Connected" cue, as it always has.
            if callDirection == .outgoing, let id = activeCallID {
                callProvider.reportOutgoingCallConnected(id)
            }
            transition(to: .connected(since: start))
            applyMicIfActivated()
            scheduleAudioDeviceUpdate()
            Log.info(.call, "Connected")

        case .reconnecting:
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            cancelSelfHealDeadline()
            transition(to: .connected(since: firstConnectedAt ?? now()))
            applyMicIfActivated()
            Log.info(.call, "Reconnected")

        default:
            break
        }
    }

    /// Re-apply the mic state once connected — covers the case where CallKit
    /// activated the audio session before the transport finished connecting (so
    /// the `activate(_:)` call to `setMicEnabled` no-op'd on a not-yet-joined client).
    private func applyMicIfActivated() {
        guard isAudioActivated, let transport else { return }
        Task { [weak self] in
            guard let self, self.transport === transport else { return }
            await transport.setMicEnabled(self.micShouldBeOn)
        }
    }

    private func handleDisconnect(_ reason: TransportDisconnectReason) {
        switch reason {
        case .requestedByUser:
            break // our own teardown drives the terminal state

        case .authFailed:
            fail(.badToken)

        case .botLeft:
            endRemote()

        case .networkDropped, .unknown:
            guard state.isActive, !state.isTerminal else { return }
            // A call that never connected has nothing to reconnect to; fail rather
            // than loop. Reconnection is for mid-call drops (the driving case).
            if firstConnectedAt == nil {
                fail(.transportError)
            } else {
                scheduleReconnect()
            }
        }
    }

    private func handleError(_ error: TransportError) {
        switch state {
        case .connecting:
            fail(error == .authenticationFailed ? .badToken : .transportError)
        case .reconnecting where error == .authenticationFailed:
            fail(.badToken)
        default:
            Log.error(.transport, "Transport error during call: \(error)")
        }
    }

    // MARK: - Reconnection (event-driven; each drop is one attempt)

    /// Display-only response to a transport that is self-healing. It does NOT count
    /// against the reconnection budget or schedule our own retry — the budget is
    /// owned solely by `scheduleReconnect` (driven by `.disconnected`). The transport
    /// must follow a `.reconnecting` with a `.connected` or `.disconnected`; if it
    /// says neither within `policy.selfHealTimeout`, the engine treats it as dropped
    /// and reconnects itself, with fresh credentials from the target's `connect`.
    private func enterReconnectingDisplay() {
        transition(to: .reconnecting(attempt: reconnectAttempt))
        startSelfHealDeadline()
    }

    private func startSelfHealDeadline() {
        cancelSelfHealDeadline()
        guard let transport else { return }
        let timeout = policy.selfHealTimeout
        selfHealDeadlineTask = Task { [weak self] in
            try? await self?.sleep(timeout)
            guard let self, !Task.isCancelled, self.transport === transport,
                  self.state == .reconnecting(attempt: 0), self.reconnectTask == nil
            else { return }
            Log.warning(.call, "Transport still healing after \(timeout); reconnecting")
            self.selfHealDeadlineTask = nil
            self.scheduleReconnect()
        }
    }

    private func cancelSelfHealDeadline() {
        selfHealDeadlineTask?.cancel()
        selfHealDeadlineTask = nil
    }

    private func scheduleReconnect() {
        cancelSelfHealDeadline()
        let next = reconnectAttempt + 1
        guard policy.canAttempt(next) else {
            Log.warning(.call, "Reconnection budget exhausted after \(reconnectAttempt) attempts")
            fail(.lostConnection)
            return
        }
        reconnectAttempt = next

        transition(to: .reconnecting(attempt: reconnectAttempt))

        let delay = policy.delay(forAttempt: reconnectAttempt)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await self?.sleep(delay)
            guard let self, !Task.isCancelled else { return }
            await self.retryConnect()
        }
    }

    private func retryConnect() async {
        guard let transport, let target = currentTarget else { return }
        // Success surfaces as a `.connected` event; a transport that reports the
        // failed attempt as a `.disconnected` event schedules the next attempt there.
        // A transport that instead throws is chained here, so the loop never stalls.
        // Both awaits can outlive the call: once it has ended, this attempt is inert.
        do {
            let connection = try await target.connect()
            guard self.transport === transport, !Task.isCancelled else { return }
            try await transport.connect(connection)
        } catch {
            Log.error(.transport, "Reconnect attempt failed: \(error)")
            guard self.transport === transport, !Task.isCancelled else { return }
            // Rejected credentials will be rejected again; only other failures retry.
            if (error as? TransportError) == .authenticationFailed {
                fail(.badToken)
            } else {
                scheduleReconnect()
            }
        }
    }

    /// Test hook: await the in-flight reconnection attempt.
    package func awaitPendingReconnect() async {
        await reconnectTask?.value
    }

    // MARK: - CallKit audio-session handshake (CallProviderDelegate)

    package func providerDidActivate(_ audioSession: AudioSessionActivating) {
        Log.info(.callkit, "Audio session activated")
        activationTask = Task { [weak self] in await self?.activate(audioSession) }
    }

    /// Test hook: await the in-flight audio-session activation.
    package func awaitPendingActivation() async {
        await activationTask?.value
    }

    /// Attach media to the CallKit-activated session. THE ONLY place media attaches.
    package func activate(_ audioSession: AudioSessionActivating) async {
        // CallKit's activation names no call. With no call in progress it belongs to
        // one that has already ended, and must not be replayed onto the next call
        // before CallKit activates that one.
        guard state != .idle, !state.isTerminal else {
            Log.warning(.callkit, "Audio session activated with no call in progress; ignored")
            return
        }
        isAudioActivated = true
        // A transport created later attaches as soon as it exists.
        guard let transport else { return }
        await transport.attachAudioSession()
        guard self.transport === transport else { return }
        // Enabling the mic only takes effect once the transport is connected. If
        // CallKit activates BEFORE connect (e.g. slow credential resolution delays the
        // join), this is a no-op and the mic is (re)enabled in `handleConnected`.
        await transport.setMicEnabled(micShouldBeOn)
        guard self.transport === transport else { return }
        await refreshAudioDevices(of: transport)
    }

    /// Hands-free default: prefer the loudspeaker when nothing external (car /
    /// Bluetooth / wired) is connected, so call audio isn't stuck on the quiet
    /// earpiece. Driven through the transport, because an SDK that manages the
    /// session itself reverts a direct AVAudioSession override. Runs once per call,
    /// on connect or a device change, once the device list is populated.
    private func applyHandsFreeDefaultIfNeeded(on transport: CallTransport) async {
        // Caller refreshes the device list first; bail until it's populated so a
        // later trigger (connect / devices-changed) can apply the default instead.
        guard self.transport === transport, !didApplyHandsFreeDefault, !audioDevices.isEmpty else { return }
        didApplyHandsFreeDefault = true

        let hasExternalRoute = audioDevices.contains {
            let kind = AudioRouteKind(deviceID: $0.id)
            return kind == .bluetooth || kind == .wired
        }
        guard !hasExternalRoute,
              let speaker = audioDevices.first(where: { AudioRouteKind(deviceID: $0.id) == .speaker })
        else { return }
        await transport.setAudioDevice(speaker.id)
        await refreshAudioDevices(of: transport)
    }

    package func providerDidDeactivate(_ audioSession: AudioSessionActivating) {
        Log.info(.callkit, "Audio session deactivated")
        isAudioActivated = false
        let transport = transport
        Task { await transport?.detachAudioSession() }
    }

    package func providerPerformAnswerCall(_ id: UUID) {
        Log.info(.callkit, "System requested answer")
        // Only the ringing call can be answered, not a busy ring CallKit still shows.
        guard activeCallID == id else {
            Log.warning(.callkit, "Answer for call \(id), which is not the ringing call; ignored")
            return
        }
        // Before the hop to `answer()`: from here on the ring is the user's, and
        // neither its timer nor a cancel push may end it.
        isAnswerRequested = true
        cancelRingTimer()
        Task { [weak self] in await self?.answer() }
    }

    package func providerPerformEndCall(_ id: UUID) {
        Log.info(.callkit, "System requested end call")
        // Idempotent against our own End path, which already finished and reset (so
        // `activeCallID` is nil): only act while this id is still the live call.
        guard activeCallID == id else { return }
        finishEnded()
    }

    package func providerPerformSetMuted(_ id: UUID, muted: Bool) {
        guard activeCallID == id else {
            Log.warning(.callkit, "Mute for call \(id), which is not the live call; ignored")
            return
        }
        isMuted = muted
        guard let transport else { return }
        Task { [weak self] in
            guard let self, self.transport === transport else { return }
            await transport.setMicEnabled(self.micShouldBeOn)
        }
    }

    /// The reset already ended every call in CallKit, so nothing is reported back
    /// to it; the host still hears the call end and gets its record.
    package func providerWasReset() {
        Log.warning(.callkit, "Provider reset; tearing down call")
        switch state {
        case .incomingRinging:
            endRingThatCannotProceed(reportToCallKit: false)
        case .dialing, .connecting, .connected, .reconnecting:
            fail(.unknown, reportToCallKit: false)
        case .idle, .ended, .failed:
            teardownTransport()
            resetState()
        }
    }

    // MARK: - Audio interruptions (AudioInterruptionObserverDelegate)
    //
    // A transient takeover (Siri, a navigation prompt that can't mix, a real phone
    // call): pause the mic while interrupted and re-apply it on resume. We never
    // touch the audio session — CallKit owns it and re-fires `providerDidActivate`
    // when the interruption ends, so this and that activation are two unordered
    // edges; both re-apply mic state idempotently.

    package func audioInterruptionBegan() {
        guard state.isActive, !state.isTerminal else { return }
        Log.info(.call, "Call interrupted; pausing mic")
        isInterrupted = true
        let transport = transport
        Task { await transport?.setMicEnabled(false) }
    }

    package func audioInterruptionEnded(shouldResume: Bool) {
        guard isInterrupted else { return }
        Log.info(.call, "Interruption ended; resume=\(shouldResume)")
        isInterrupted = false
        guard shouldResume else { return }
        applyMicIfActivated()
    }

    // MARK: - User-initiated controls

    /// Set `endedByUser` synchronously, so a host can dismiss its in-call UI in the
    /// same transaction as the user's tap; `endCall()` then does the teardown
    /// asynchronously.
    public func markEndedByUser() {
        guard state.isActive, !state.isTerminal else { return }
        endedByUser = true
    }

    public func endCall() async {
        guard state.isActive, !state.isTerminal else { return }
        // Mark this as a local user-end, so a host can skip its ended view, while
        // the state still goes `.ended` and the call is recorded. Going terminal
        // BEFORE the system round-trip also avoids the mid-`.connecting` race where a
        // teardown disconnect would be misread as `.failed`. `finishEnded` nils
        // `activeCallID`, so capture it first; the round-trip then no-ops on the
        // stale id (see `providerPerformEndCall`).
        endedByUser = true
        let id = activeCallID
        finishEnded()
        if let id { await callProvider.endCall(id) }
    }

    /// Mute or unmute, mirrored to CallKit. Unmuting opens the mic only once CallKit
    /// has activated the session and while nothing interrupts it.
    public func setMuted(_ muted: Bool) async {
        isMuted = muted
        // Captured first: after the await below this may be a newer call.
        let id = activeCallID
        await transport?.setMicEnabled(micShouldBeOn)
        if let id { await callProvider.setMuted(id, muted: muted) }
    }

    /// Push-to-talk: open the mic only while the button is held (PTT mode only),
    /// and only once CallKit has activated the session and nothing interrupts it.
    public func setPushToTalkActive(_ active: Bool) async {
        guard isPushToTalkEnabled() else { return }
        isPushToTalkHeld = active
        await transport?.setMicEnabled(micShouldBeOn)
    }

    // MARK: - Audio route (driven through the transport so the SDK honors it)

    public func selectAudioDevice(_ id: String) async {
        guard let transport else { return }
        await transport.setAudioDevice(id)
        await refreshAudioDevices(of: transport)
    }

    /// Reads `transport`'s routes, and publishes them only if it is still the live
    /// call's transport once the reads return.
    private func refreshAudioDevices(of transport: CallTransport) async {
        let devices = await transport.availableAudioDevices()
        let selected = await transport.selectedAudioDevice()
        guard self.transport === transport else { return }
        audioDevices = devices
        selectedAudioDeviceID = selected?.id
    }

    /// Refresh the route list (keeps the picker live) and apply the hands-free
    /// default once it's available. Runs on connect and on device changes, for the
    /// transport live when it was scheduled.
    private func scheduleAudioDeviceUpdate() {
        guard let transport else { return }
        Task { [weak self] in
            await self?.refreshAudioDevices(of: transport)
            await self?.applyHandsFreeDefaultIfNeeded(on: transport)
        }
    }

    /// Return to idle after a terminal state, once the host has shown the outcome.
    /// Placing a call or a new ring also resets a terminal state.
    public func reset() {
        guard state.isTerminal else { return }
        resetState()
    }

    /// Project a connected call onto the in-call surface without a real transport,
    /// so its look can be screenshotted in the simulator. Drives only the observed
    /// state the view reads — no CallKit, no media, and no delegate callbacks.
    /// Refuses (returns false) on an engine that is not simulated, where the
    /// unannounced state change would corrupt a real call.
    @discardableResult
    package func presentConnectedProjection(_ call: ActiveCall, secondsElapsed: TimeInterval, botSpeaking: Bool) -> Bool {
        guard isSimulated else {
            Log.warning(.call, "Connected projection refused on a non-simulated engine")
            return false
        }
        activeCall = call
        callDirection = call.direction
        state = .connected(since: now().addingTimeInterval(-secondsElapsed))
        isBotSpeaking = botSpeaking
        return true
    }

    /// Whether a call currently has a transport whose events the engine consumes.
    package var hasTransport: Bool { transport != nil }

    /// Every path that sets the mic goes through this: it opens only on a session
    /// CallKit has activated and no other audio has taken over, then follows mute,
    /// or in push-to-talk mode the button.
    private var micShouldBeOn: Bool {
        guard isAudioActivated, !isInterrupted else { return false }
        return isPushToTalkEnabled() ? isPushToTalkHeld : !isMuted
    }

    // MARK: - Terminal transitions

    private func fail(_ reason: CallFailureReason, reportToCallKit: Bool = true) {
        guard !state.isTerminal else { return }
        transition(to: .failed(reason))
        if reportToCallKit, let id = activeCallID { callProvider.reportCallEnded(id, reason: .failed) }
        finish(outcome: .failed, failureReason: reason)
        teardownTransport()
    }

    private func endRemote() {
        guard !state.isTerminal else { return }
        let outcome: CallOutcome = firstConnectedAt != nil ? .completed : .noAnswer
        transition(to: .ended(outcome))
        if let id = activeCallID { callProvider.reportCallEnded(id, reason: .remoteEnded) }
        finish(outcome: outcome)
        teardownTransport()
    }

    /// The system already knows the call is ending (we requested it, or it told us),
    /// so this does not report back to CallKit. The terminal guard makes the real
    /// CallKit end → providerPerformEndCall round-trip idempotent (no double record).
    private func finishEnded() {
        guard !state.isTerminal else { return }
        // Only a ring can be declined; a call placed or answered that ends before it
        // connects was canceled.
        let outcome: CallOutcome
        if firstConnectedAt != nil {
            outcome = .completed
        } else if case .incomingRinging = state {
            outcome = .declined
        } else {
            outcome = .canceled
        }
        if outcome == .declined, let url = ringStatusURL, let id = activeCallID {
            reportRingStatus(.declined, callID: id, endpoint: url, targetID: recordTargetID)
            ringStatusURL = nil
        }
        transition(to: .ended(outcome))
        finish(outcome: outcome)
        teardownTransport()
    }

    private func teardownTransport() {
        cancelRingTimer()
        interruptionObserver.stopObserving()
        isInterrupted = false
        // The session CallKit activated belonged to this call.
        isAudioActivated = false
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelSelfHealDeadline()
        eventTask?.cancel()
        eventTask = nil
        activeCallID = nil
        let outgoing = transport
        transport = nil
        Task {
            await outgoing?.detachAudioSession()
            await outgoing?.disconnect()
        }
    }

    private func resetState() {
        activeCall = nil
        currentTarget = nil
        recordTargetID = nil
        activeCallID = nil
        callDirection = .outgoing
        ringStatusURL = nil
        callStartedAt = nil
        firstConnectedAt = nil
        reconnectAttempt = 0
        isMuted = false
        isBotSpeaking = false
        remoteAudioLevel = 0
        isAudioActivated = false
        isInterrupted = false
        audioDevices = []
        selectedAudioDeviceID = nil
        didApplyHandsFreeDefault = false
        isPushToTalkHeld = false
        endedByUser = false
        isAnswerRequested = false
        cancelRingTimer()
        transition(to: .idle)
    }

    /// Assign the state and tell the delegate. Callers set the transition's other
    /// fields first, so the delegate sees a consistent snapshot.
    private func transition(to new: CallState) {
        let old = state
        state = new
        guard old != new else { return }
        delegate?.callEngine(self, didChangeStateFrom: old, to: new)
        deliverCues(from: old, to: new)
    }

    /// Cues are a function of the transition: the loop each state wants, and the
    /// moments its edges mark. Stopping first and starting last keeps every
    /// moment outside a loop and at most one loop running.
    private func deliverCues(from old: CallState, to new: CallState) {
        let loop: RepeatingCue?
        switch new {
        case .connecting: loop = .connecting
        case .reconnecting: loop = .retrying
        default: loop = nil
        }
        let moment: CallMoment?
        switch (old, new) {
        case (.connecting, .connected): moment = .connected
        case (.reconnecting, .connected): moment = .reconnected
        case (.connected, .reconnecting): moment = .connectionLost
        default: moment = nil
        }

        if repeatingCue != nil, repeatingCue != loop {
            repeatingCue = nil
            delegate?.callEngine(self, cue: .stop)
        }
        if let moment { delegate?.callEngine(self, cue: .moment(moment)) }
        if let loop, repeatingCue != loop {
            repeatingCue = loop
            delegate?.callEngine(self, cue: .start(loop))
        }
    }

    private func finish(
        outcome: CallOutcome,
        failureReason: CallFailureReason? = nil,
        missedReason: MissedCallReason? = nil
    ) {
        guard let targetID = recordTargetID else { return }
        let started = callStartedAt ?? now()
        let duration = firstConnectedAt.map { max(0, now().timeIntervalSince($0)) } ?? 0
        delegate?.callEngine(self, didFinish: CallRecord(
            targetID: targetID,
            direction: callDirection,
            startedAt: started,
            duration: duration,
            outcome: outcome,
            failureReason: failureReason,
            missedReason: missedReason
        ))
    }
}

extension CallEngine {
    /// The optional push features this engine understands, for a host to send to
    /// its server with the VoIP token, so the server uses a feature only with
    /// devices that list it: `"ring_timeout"` (a ring push may carry
    /// `ring_timeout`) and `"cancel"` (the server may send a cancel push,
    /// `{"action": "cancel", "call_id": ...}` with no `target_id`, to withdraw a
    /// ring). An engine that lacks a feature ignores its key, or, for a cancel,
    /// shows it as a brief incoming call that ends at once. Later versions add
    /// features to this set; servers must ignore names they do not know.
    nonisolated public static let supportedPushFeatures: Set<String> = ["cancel", "ring_timeout"]
}

extension CallEngine {
    /// How many cancelled call ids are remembered, newest first, so a ring that
    /// APNs delivers after its own cancel is ended at once.
    package nonisolated static let rememberedCancelLimit = 32
    /// How long a cancelled call id is remembered.
    package nonisolated static let rememberedCancelLifetime: TimeInterval = 10 * 60
    /// The shortest ring a push's `ring_timeout` can ask for.
    package nonisolated static let minimumPushedRingTimeout: Duration = .seconds(10)
}
