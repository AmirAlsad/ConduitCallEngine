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
//  only once CallKit has activated the session and only while the call is not on
//  hold — from `activate(_:)` (the `providerDidActivate` callback), when a
//  transport is created after that activation already happened, or on resume —
//  the mic is never enabled before activation (see `micShouldBeOn`), and no route
//  is read or changed while the session is not activated (`scheduleAudioDeviceUpdate`).
//  CallKit owns the session; the transport attaches to it.
//
//  PRE-CONNECT: a ring may join its transport before the answer (`ringTransport`).
//  That transport is kept apart from `transport`, so no attach, mic, route or
//  signal path reaches it, and its events steer only the ring's preparation,
//  never the ring, except that the agent leaving a ready ring is the caller
//  cancelling it. The answer adopts it; its route work waits for CallKit's
//  activation, as every call's does, though it can be connected first. A preparation never
//  makes the answered call worse than none: a ring's join is bounded by the join
//  deadline, and whatever the ring prepared failing after the answer, before the
//  agent was there, sends the call down the unprepared path once
//  (`fallBackFromPreparation`).
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
    /// Whether an interruption by another audio session (Siri, a phone call,
    /// navigation) is keeping the mic closed. True from the interruption's start
    /// until it ends with permission to resume, or, when it ends without that
    /// permission, until CallKit activates the session again or the user unmutes
    /// or presses push-to-talk. If CallKit activated the session during the
    /// interruption, its end clears this either way.
    public var isInterrupted: Bool { interruption != .none }
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
    /// Whether the call is on hold: iOS held it (typically so the user can take
    /// or place a phone call) or the host did with `setOnHold(_:)`. The state does
    /// not change on hold. While held the mic is closed, media is stopped, the
    /// agent has been sent `CallSignal.held`, no cues are delivered, and a dropped
    /// connection waits for the resume before reconnecting. Cleared when the call ends.
    public private(set) var isOnHold = false
    /// Where the preparation of the ringing call stands (pre-connect; see
    /// `RingPreparation`), for diagnostics. `.idle` whenever no ring is being
    /// prepared, including once a ring is answered or ends. Changing it never
    /// changes `state`; each change is reported to
    /// `CallEngineDelegate.callEngine(_:didChangeRingPreparationPhaseFrom:to:)`.
    public private(set) var ringPreparationPhase: RingPreparationPhase = .idle

    // MARK: - Dependencies

    @ObservationIgnored public weak var delegate: CallEngineDelegate?

    private let configuration: CallEngineConfiguration
    private let callProvider: CallProviding
    private let interruptionObserver: AudioInterruptionObserving
    private let ringStatusReporter: RingStatusReporting
    private let pushRegistry: VoIPPushRegistering
    private let policy: ReconnectionPolicy
    private let now: @MainActor () -> Date
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
    /// Where an interruption stands; see `isInterrupted`.
    private var interruption: InterruptionPhase = .none
    /// The tail of the media commands (attach, detach, mic) sent to the live
    /// transport, which run one after another in the order the engine issued them.
    private var mediaTask: Task<Void, Never>?
    /// The tail of the call-control signals sent to the live transport, in order.
    /// Kept apart from media so a slow delivery never delays the mic.
    private var signalTask: Task<Void, Never>?
    /// Whether the agent may believe the call is held: it was sent `held`, and no
    /// `resumed` is known to have left the device since.
    private var isAgentToldHeld = false
    /// Counts the hold signals queued; only the latest one's delivery result counts.
    private var holdSignalGeneration = 0
    /// Counts the transport's connections, so a delivery result from an earlier one
    /// changes nothing.
    private var connectionGeneration = 0
    /// Sends the call's state again after a signal failed to leave the device.
    private var signalRetryTask: Task<Void, Never>?
    /// Retries spent since the last signal that left the device, a hold or resume,
    /// or a new connection.
    private var signalRetryCount = 0
    /// A drop while held: the reconnection waits for the resume, then starts at
    /// attempt 1 at once.
    private var isReconnectionPaused = false
    /// Whether this outage's `connectionLost` cue has been delivered (it is not
    /// while held, so the resume delivers it).
    private var isOutageMarked = false
    /// Whether `.moment(.connected)` has been delivered for this call. It waits until
    /// the call is connected, CallKit has activated its audio and it is not held,
    /// whichever comes last (`markConnectedIfDue`).
    private var isConnectionMarked = false
    package private(set) var reconnectTask: Task<Void, Never>?
    /// Identifies the engine's reconnect attempt in progress. An attempt whose id
    /// is no longer this one was superseded (the call recovered, was held, or a
    /// newer attempt started) and changes nothing when its awaits return.
    private var reconnectAttemptID: UUID?
    /// The attempt whose `transport.connect` is under way, if any.
    private var joiningAttemptID: UUID?
    /// Ends the wait for `.connected` after a connect returned; see `startJoinDeadline`.
    private var joinDeadlineTask: Task<Void, Never>?
    /// The call's first connect has returned and the call is waiting for its agent.
    /// The join deadline bounds that wait, except while the call is held: the user
    /// is not waiting then, and an agent may be unable to get ready (Daily's is,
    /// with its audio unsubscribed). The resume starts the deadline again.
    private var isAwaitingAgent = false
    /// Ends the wait for a transport that is healing itself; see `enterReconnectingDisplay`.
    private var selfHealDeadlineTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    /// Ends the ring if nobody answers it in time; see `startRingTimer`.
    private var ringTimerTask: Task<Void, Never>?
    /// What each running timer does when its wait is over, so a simulated system
    /// can run one out early (`fireTimer(_:)`).
    private var timerExpiries: [EngineTimer: @MainActor () -> Void] = [:]
    /// Work the engine starts and does not await (a call's transport teardown, a ring
    /// transport's disconnect, a route refresh, the connect after a failed
    /// preparation), so a simulated system can wait for it (`awaitPendingWork()`).
    private var detachedWork: [UUID: Task<Void, Never>] = [:]
    /// Counts the work started, media and signal commands included, so
    /// `awaitPendingWork()` can tell when none was added while it waited.
    private var workCount = 0
    /// Set the moment CallKit delivers the answer action for the ringing call, before
    /// `answer()` runs, so neither the ring timer nor a cancel ends an answered ring.
    private var isAnswerRequested = false
    /// Calls the sender cancelled, newest last, so a ring that arrives after its
    /// own cancel is ended at once. Survives across calls.
    private var canceledCallIDs: [(id: UUID, at: Date)] = []
    /// Identifies the outgoing call a suspended `placeCall` belongs to, so its
    /// continuation can tell it has been superseded (reset, or a newer call).
    private var dialToken = UUID()

    // MARK: - Ring preparation (pre-connect)

    /// Identifies the ring's preparation; work an older one started changes nothing.
    private var preparationID: UUID?
    /// The ring's credential fetch. An answer while it runs awaits it rather than
    /// fetching again.
    private var preparationFetch: Task<CallConnection, any Error>?
    /// The credentials a `.credentials` ring keeps for the answer.
    private var preparedConnection: CallConnection?
    /// The preparation's own work, for `awaitPendingRingPreparation`: the credential
    /// fetch and what follows it, then the ring transport's connect.
    private var preparationWork: Task<Void, Never>?
    private var ringJoinWork: Task<Void, Never>?
    /// The transport a `.media` ring joins before the answer. Not `transport`, so
    /// nothing that attaches audio, sets the mic, routes or sends a signal reaches
    /// it until the answer adopts it.
    private var ringTransport: CallTransport?
    /// Whether `ringTransport`'s connect has returned without throwing.
    private var isRingTransportJoined = false
    /// A transport made for a `.media` ring that cannot connect while ringing. It
    /// is neither connected nor subscribed during the ring; the answer uses it.
    private var transportForAnswer: CallTransport?
    /// Whether the ring's push carried `preconnect`: its agent may be waiting for
    /// `CallSignal.answered` before it speaks.
    private var signalsAnswer = false
    /// Whether `CallSignal.answered` has been sent on the current connection.
    private var isAnswerSignalSent = false
    /// The answered call's first connect is using what the ring prepared (its
    /// credentials, or its transport's join) and has not reached `.connected`. If
    /// that fails, the call connects as it would have without pre-connect, once.
    private var isPreparedConnect = false
    /// Identifies the unprepared connect a failed preparation started, while its
    /// credential fetch or its transport's connect is under way.
    private var freshConnectID: UUID?

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
        now: @escaping @MainActor () -> Date,
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
        callProvider.supportsHolding = configuration.supportsHolding
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
            onTokenInvalidated: { [weak self] in
                guard let self else { return }
                delegate?.callEngineDidInvalidateVoIPPushToken(self)
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
            Log.error(.callKit, "startOutgoingCall failed: \(error)")
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

        await connectTransport(for: target) { [self] in try await target.connect(connectRequest(.outgoing)) }
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
        Log.warning(.callKit, "Malformed VoIP push; reporting call \(id) and ending it")
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
            connection: payload.inlineConnection,
            requestedPreparation: payload.preparation
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
        signalsAnswer = payload.preparation != .none
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
        ringTimerTask = startTimer(.ringTimeout, after: timeout) { [weak self] in
            self?.ringTimedOut(id)
        }
    }

    private func cancelRingTimer() {
        ringTimerTask?.cancel()
        ringTimerTask = nil
        timerExpiries[.ringTimeout] = nil
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
            Log.error(.callKit, "reportIncomingCall failed: \(message)")
            endRingThatCannotProceed()

        case .duplicateCallID:
            // CallKit holds a call under this id that is not this ring, so the
            // report created nothing to end, and ending the id would end that call.
            Log.error(.callKit, "reportIncomingCall refused: call id \(incoming.callID) already exists")
            endRingThatCannotProceed(reportToCallKit: false)

        case nil:
            guard let target else {
                Log.error(.call, "Incoming call for unknown target \(incoming.targetID)")
                endRingThatCannotProceed()
                return
            }
            correctRingIfNeeded(incoming, to: target)
            startRingPreparation(incoming, target: target)
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
        isAnswerRequested = true
        cancelRingTimer()
        // Answering is the ring's terminal status — the receipt fires here whether
        // or not the transport subsequently connects, and before the ringback starts.
        if let url = ringStatusURL, let id = activeCallID {
            reportRingStatus(.answered, callID: id, endpoint: url, targetID: target.id)
            ringStatusURL = nil
        }
        let preparation = takeRingPreparation()
        switch preparation {
        case .none:
            transition(to: .connecting)
            await connectTransport(for: target) { [self] in try await target.connect(connectRequest(.answered)) }

        case .ready(let transport):
            // The agent is already there: no `.connecting`, so no ringback.
            adopt(transport, isSubscribed: true)
            let start = now()
            firstConnectedAt = start
            transition(to: .connected(since: start))
            applyMic()
            startSignalConnection()
            sendAnswerSignalIfDue()
            syncHoldSignal()
            scheduleAudioDeviceUpdate()
            Log.info(.call, "Connected (prepared during the ring)")

        case .joining(let transport, let hasJoined):
            // Its connect may still be under way; `ringTransportConnectReturned`
            // treats what it returns as the call's first connect. A joined one's
            // deadline has been running since the join and keeps running.
            adopt(transport, isSubscribed: true)
            isPreparedConnect = true
            transition(to: .connecting)
            if hasJoined { isAwaitingAgent = true }

        case .fetching(let fetch, let transport, let isSubscribed):
            isPreparedConnect = true
            transition(to: .connecting)
            await connectTransport(for: target, using: transport, isSubscribed: isSubscribed) { try await fetch.value }

        case .credentials(let connection, let transport):
            isPreparedConnect = true
            transition(to: .connecting)
            await connectTransport(for: target, using: transport) { connection }
        }
    }

    /// For an incoming call every request carries the ring's id; an outgoing call's
    /// CallKit id is the engine's own, which no server knows.
    private func connectRequest(_ purpose: ConnectRequest.Purpose) -> ConnectRequest {
        ConnectRequest(purpose: purpose, callID: callDirection == .incoming ? activeCallID : nil)
    }

    // MARK: - Ring preparation (pre-connect)

    /// Start preparing a ring CallKit accepted, at the lowest tier of the push's
    /// request, the target's allowance and, for `.media`, the transport's ability
    /// to join while ringing. Only once CallKit accepted the report, so a ring it
    /// filtered or refused never fetches credentials.
    private func startRingPreparation(_ incoming: IncomingCall, target: CallTarget) {
        guard state == .incomingRinging, !isAnswerRequested, activeCallID == incoming.callID,
              preparationID == nil
        else { return }
        var tier = min(incoming.requestedPreparation, target.ringPreparation)
        guard tier != .none else { return }
        let id = UUID()
        preparationID = id
        if tier == .media {
            // Made before the fetch, as for any call, so the request can say
            // whether the transport will join before the answer.
            let transport = target.makeTransport()
            if transport.canConnectWhileRinging {
                ringTransport = transport
                subscribe(to: transport)
            } else {
                Log.info(.call, "Ring preparation: the transport cannot connect while ringing; credentials only")
                transportForAnswer = transport
                tier = .credentials
            }
        }
        Log.info(.call, "Ring preparation: \(tier)")
        let request = ConnectRequest(purpose: .ringing(joinsBeforeAnswer: tier == .media), callID: incoming.callID)
        setRingPreparationPhase(.fetchingCredentials)
        let fetch = Task { try await target.connect(request) }
        preparationFetch = fetch
        preparationWork = Task { [weak self] in
            let result = await fetch.result
            self?.ringCredentialsArrived(result, preparation: id)
        }
    }

    /// Test hook: await the ringing call's preparation, its credential fetch and, at
    /// the media tier, its transport's connect; returns at once if none is under way.
    package func awaitPendingRingPreparation() async {
        await preparationWork?.value
        await ringJoinWork?.value
    }

    private func ringCredentialsArrived(_ result: Result<CallConnection, any Error>, preparation id: UUID) {
        // An answer awaits the fetch itself, and an ended ring has no preparation.
        guard preparationID == id, state == .incomingRinging else { return }
        preparationFetch = nil
        let connection: CallConnection
        switch result {
        case .success(let fetched):
            connection = fetched
        case .failure(let error):
            Log.warning(.call, "Ring preparation: credentials failed: \(error)")
            ringPreparationFailed()
            return
        }
        guard let transport = ringTransport else {
            preparedConnection = connection
            setRingPreparationPhase(.credentialsReady)
            return
        }
        setRingPreparationPhase(.connecting)
        ringJoinWork = Task { [weak self] in
            do {
                try await transport.connect(connection)
                self?.ringTransportConnectReturned(transport, error: nil)
            } catch {
                self?.ringTransportConnectReturned(transport, error: error)
            }
        }
    }

    /// The ring transport's connect returned. While it still rings that is the
    /// preparation's; once the answer adopted the transport, it is the call's first
    /// connect, handled as `connectTransport` handles one.
    private func ringTransportConnectReturned(_ transport: CallTransport, error: (any Error)?) {
        if transport === ringTransport {
            if let error {
                Log.warning(.call, "Ring preparation: connect failed: \(error)")
                ringPreparationFailed()
            } else {
                isRingTransportJoined = true
                if ringPreparationPhase == .connecting { startRingJoinDeadline(for: transport) }
            }
        } else if transport === self.transport {
            if let error {
                Log.error(.transport, "connect failed: \(error)")
                failFirstConnect(error)
            } else if state == .connecting {
                awaitAgent(on: transport)
            }
        }
    }

    /// The ring transport's events steer only the preparation. The one exception is
    /// the agent leaving once it was there, before CallKit delivered an answer: the
    /// caller withdrew the ring. A mid-ring `.error` is as for a live call: it
    /// fails a join, and is only logged once the agent is there.
    private func handleRingEvent(_ event: TransportEvent) {
        switch event {
        case .connected:
            if ringPreparationPhase == .connecting {
                setRingPreparationPhase(.ready)
                cancelJoinDeadline()
            }
        case .reconnecting:
            // Healing itself: the agent is there again once it reports `.connected`,
            // within the same bound as a join.
            if ringPreparationPhase == .ready {
                setRingPreparationPhase(.connecting)
                if let ringTransport { startRingJoinDeadline(for: ringTransport) }
            }
        case .disconnected(reason: .botLeft) where ringPreparationPhase == .ready && !isAnswerRequested:
            Log.info(.call, "The agent left the prepared ring; the caller cancelled it")
            endMissedRing(.canceledByCaller, callKitReason: .remoteEnded, receipt: .canceled)
        case .disconnected(reason: .requestedByUser):
            break
        case .disconnected:
            Log.warning(.call, "Ring preparation: transport \(event)")
            ringPreparationFailed()
        case .error(let error):
            if ringPreparationPhase == .connecting {
                Log.warning(.call, "Ring preparation: transport error \(error)")
                ringPreparationFailed()
            } else {
                Log.error(.transport, "Transport error during a prepared ring: \(error)")
            }
        case .connecting, .botStartedSpeaking, .botStoppedSpeaking, .userStartedSpeaking,
             .userStoppedSpeaking, .remoteAudioLevel, .audioDevicesChanged:
            break
        }
    }

    /// Give up the preparation but not the ring, which an answer then connects as
    /// it would without one.
    private func ringPreparationFailed() {
        cancelJoinDeadline()
        preparationID = nil
        preparationFetch?.cancel()
        preparationFetch = nil
        preparedConnection = nil
        discardRingTransports()
        setRingPreparationPhase(.failed)
    }

    /// Undo a ring's preparation: the ring ended, or the call is torn down.
    private func cancelRingPreparation() {
        if ringTransport != nil { cancelJoinDeadline() }
        preparationID = nil
        preparationFetch?.cancel()
        preparationFetch = nil
        preparedConnection = nil
        discardRingTransports()
        if ringPreparationPhase != .idle { setRingPreparationPhase(.idle) }
    }

    /// Disconnect the ring's transports (a joined one sends the end-call signal)
    /// and stop consuming the ring transport's events.
    private func discardRingTransports() {
        if ringTransport != nil {
            eventTask?.cancel()
            eventTask = nil
        }
        let transports = [ringTransport, transportForAnswer].compactMap { $0 }
        ringTransport = nil
        transportForAnswer = nil
        isRingTransportJoined = false
        guard !transports.isEmpty else { return }
        startDetachedWork {
            for transport in transports { await transport.disconnect() }
        }
    }

    /// What a ring's preparation leaves for its answer.
    private enum AnsweredPreparation {
        /// Nothing (none was made, or it failed): connect as without pre-connect.
        case none
        /// The ring transport, with the agent there.
        case ready(CallTransport)
        /// The ring transport, joining or joined and waiting for the agent.
        case joining(CallTransport, hasJoined: Bool)
        /// The credential fetch in flight, and the transport made for the ring, if any.
        case fetching(Task<CallConnection, any Error>, transport: CallTransport?, isSubscribed: Bool)
        /// The credentials, and the transport made for the ring, if any.
        case credentials(CallConnection, transport: CallTransport?)
    }

    /// Set the ring's preparation phase and tell the delegate when it changed.
    private func setRingPreparationPhase(_ phase: RingPreparationPhase) {
        let old = ringPreparationPhase
        ringPreparationPhase = phase
        guard old != phase else { return }
        delegate?.callEngine(self, didChangeRingPreparationPhaseFrom: old, to: phase)
    }

    /// Hand the ring's preparation to the answer, leaving none behind.
    private func takeRingPreparation() -> AnsweredPreparation {
        let preparation: AnsweredPreparation
        switch (ringPreparationPhase, ringTransport, preparationFetch, preparedConnection) {
        case (.ready, let transport?, _, _):
            preparation = .ready(transport)
        case (.connecting, let transport?, _, _):
            preparation = .joining(transport, hasJoined: isRingTransportJoined)
        case (.fetchingCredentials, let transport, let fetch?, _):
            preparation = .fetching(fetch, transport: transport ?? transportForAnswer, isSubscribed: transport != nil)
        case (.credentialsReady, _, _, let connection?):
            preparation = .credentials(connection, transport: transportForAnswer)
        default:
            cancelRingPreparation()
            return .none
        }
        preparationID = nil
        preparationFetch = nil
        preparedConnection = nil
        ringTransport = nil
        transportForAnswer = nil
        isRingTransportJoined = false
        setRingPreparationPhase(.idle)
        return preparation
    }

    /// Fire-and-forget receipt to the server that sent the push, authenticated with the
    /// bearer the host supplies for the target (omitted when it has none).
    private func reportRingStatus(_ status: RingStatus, callID: UUID, endpoint: URL, targetID: UUID?) {
        let apiKey = targetID.flatMap { delegate?.callEngine(self, ringStatusBearerForTarget: $0) }
        ringStatusReporter.report(status, callID: callID, endpoint: endpoint, apiKey: apiKey ?? "")
    }

    /// Adopt the transport (a new one, or one a ring prepared), then resolve
    /// credentials and connect. Shared by `placeCall` and `answer`. The transport
    /// is the call's before the credential fetch so a CallKit activation landing
    /// mid-fetch still reaches `attachAudioSession()`.
    private func connectTransport(
        for target: CallTarget,
        using prepared: CallTransport? = nil,
        isSubscribed: Bool = false,
        credentials: () async throws -> CallConnection
    ) async {
        let transport = prepared ?? target.makeTransport()
        if let attach = adopt(transport, isSubscribed: isSubscribed) {
            await attach.value
            guard self.transport === transport else { return }
        }

        do {
            let connection = try await credentials()
            // The call may have ended while credentials were in flight.
            guard self.transport === transport else { return }
            try await transport.connect(connection)
            guard self.transport === transport, state == .connecting else { return }
            awaitAgent(on: transport)
        } catch {
            Log.error(.transport, "connect failed: \(error)")
            // `connect` can resolve LATE — after an event already failed this call and
            // the user reset to idle (or started another call). Failing again would
            // re-enter `.failed` and replace the newer state. Ignore unless this is
            // still the live transport.
            guard self.transport === transport else { return }
            failFirstConnect(error)
        }
    }

    /// The call's first connect threw: the call fails, unless it was connecting with
    /// what the ring prepared, which then gives way to an unprepared connect.
    private func failFirstConnect(_ error: any Error) {
        if canFallBackFromPreparation {
            fallBackFromPreparation("its connect failed: \(error)")
        } else {
            fail((error as? TransportError) == .authenticationFailed ? .badToken : .transportError)
        }
    }

    /// The answered call is still connecting with what its ring prepared.
    private var canFallBackFromPreparation: Bool {
        guard isPreparedConnect, case .connecting = state else { return false }
        return true
    }

    /// The unprepared connect a failed preparation started is under way; the
    /// abandoned preparation's failures no longer decide anything.
    private var isConnectingAfresh: Bool {
        guard freshConnectID != nil, case .connecting = state else { return false }
        return true
    }

    /// What the ring prepared failed after the answer, before the agent was there:
    /// connect as the answer would have without pre-connect, with fresh `.answered`
    /// credentials, on the same transport. Not a new one, and no `disconnect()` of
    /// this one: that would send the end-call signal, and the fresh credentials may
    /// name the same room. The transport's `connect(_:)` takes its session over, as
    /// on a reconnect attempt. Only once; that connect's own failure fails the call.
    private func fallBackFromPreparation(_ reason: String) {
        guard canFallBackFromPreparation, let transport, let target = currentTarget else { return }
        Log.warning(.call, "The ring's preparation failed after the answer (\(reason)); connecting as without pre-connect")
        isPreparedConnect = false
        isAwaitingAgent = false
        cancelJoinDeadline()
        let id = UUID()
        freshConnectID = id
        startDetachedWork { [weak self] in await self?.connectAfresh(on: transport, target: target, id: id) }
    }

    private func connectAfresh(on transport: CallTransport, target: CallTarget, id: UUID) async {
        do {
            let connection = try await target.connect(connectRequest(.answered))
            guard isCurrentFreshConnect(id, on: transport) else { return }
            try await transport.connect(connection)
            guard isCurrentFreshConnect(id, on: transport) else { return }
            freshConnectID = nil
            awaitAgent(on: transport)
        } catch {
            Log.error(.transport, "connect failed: \(error)")
            guard isCurrentFreshConnect(id, on: transport) else { return }
            freshConnectID = nil
            fail((error as? TransportError) == .authenticationFailed ? .badToken : .transportError)
        }
    }

    private func isCurrentFreshConnect(_ id: UUID, on transport: CallTransport) -> Bool {
        guard freshConnectID == id, self.transport === transport, case .connecting = state else { return false }
        return true
    }

    /// Make `transport` the call's: media commands and signals from here on go to
    /// it. CallKit can activate before the transport exists (while dialing, or
    /// before `answer()` runs); that activation found no transport to attach, so
    /// this attaches it, and returns that command.
    @discardableResult
    private func adopt(_ transport: CallTransport, isSubscribed: Bool) -> Task<Void, Never>? {
        self.transport = transport
        mediaTask = nil
        signalTask = nil
        if !isSubscribed { subscribe(to: transport) }
        guard isAudioActivated, !isOnHold else { return nil }
        return enqueueMedia { await $0.attachAudioSession() }
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

    /// An event from the call's transport: the ring's while a ring is preparing
    /// one, the live call's otherwise.
    package func handle(_ event: TransportEvent) {
        if ringTransport != nil {
            handleRingEvent(event)
            return
        }
        // A ring has no live transport; nothing may end or change it from here.
        guard state != .incomingRinging else { return }
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
            isAwaitingAgent = false
            isPreparedConnect = false
            freshConnectID = nil
            cancelJoinDeadline()
            let start = now()
            firstConnectedAt = start
            // Incoming calls are marked connected to CallKit by fulfilling the answer
            // action; only outgoing calls report connected here — before the host's
            // "Connected" cue, as it always has.
            if callDirection == .outgoing, let id = activeCallID {
                callProvider.reportOutgoingCallConnected(id)
            }
            transition(to: .connected(since: start))
            // The transport may have ignored a mic set before it joined.
            applyMic()
            startSignalConnection()
            sendAnswerSignalIfDue()
            syncHoldSignal()
            scheduleAudioDeviceUpdate()
            Log.info(.call, "Connected")

        case .reconnecting:
            reconnectAttempt = 0
            stopReconnectAttempt()
            isReconnectionPaused = false
            cancelSelfHealDeadline()
            transition(to: .connected(since: firstConnectedAt ?? now()))
            applyMic()
            // A new connection may be a new agent session: tell it again.
            startSignalConnection()
            isAnswerSignalSent = false
            sendAnswerSignalIfDue()
            syncHoldSignal()
            Log.info(.call, "Reconnected")

        default:
            break
        }
    }

    private func handleDisconnect(_ reason: TransportDisconnectReason) {
        switch reason {
        case .requestedByUser:
            break // our own teardown drives the terminal state

        case .authFailed:
            if canFallBackFromPreparation {
                fallBackFromPreparation("the prepared credentials were rejected")
            } else if isConnectingAfresh {
                Log.warning(.call, "The abandoned preparation reported rejected credentials; ignored")
            } else {
                fail(.badToken)
            }

        case .botLeft:
            // An agent the device never saw ready leaving a prepared join is a lost
            // preparation, as during the ring.
            if canFallBackFromPreparation {
                fallBackFromPreparation("the agent left before it was ready")
            } else if isConnectingAfresh {
                Log.info(.call, "The abandoned preparation's agent left; ignored")
            } else {
                endRemote()
            }

        case .networkDropped, .unknown:
            guard state.isActive, !state.isTerminal else { return }
            // A call that never connected has nothing to reconnect to; fail rather
            // than loop. Reconnection is for mid-call drops (the driving case).
            if firstConnectedAt == nil {
                if canFallBackFromPreparation {
                    fallBackFromPreparation("its connection dropped")
                } else if isConnectingAfresh {
                    Log.info(.call, "The abandoned preparation's connection dropped; ignored")
                } else {
                    fail(.transportError)
                }
            } else {
                scheduleReconnect()
            }
        }
    }

    private func handleError(_ error: TransportError) {
        switch state {
        case .connecting where canFallBackFromPreparation:
            fallBackFromPreparation("a transport error: \(error)")
        case .connecting where isConnectingAfresh:
            Log.warning(.transport, "Transport error from the abandoned preparation: \(error)")
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
        selfHealDeadlineTask = startTimer(.selfHealTimeout, after: timeout) { [weak self] in
            guard let self, self.transport === transport,
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
        timerExpiries[.selfHealTimeout] = nil
    }

    /// Schedule the next attempt after its backoff, or `immediately`; while the
    /// call is held, pause reconnection instead until the resume.
    private func scheduleReconnect(immediately: Bool = false) {
        cancelSelfHealDeadline()
        cancelJoinDeadline()
        if isOnHold {
            pauseReconnection()
            return
        }
        let next = reconnectAttempt + 1
        guard policy.canAttempt(next) else {
            Log.warning(.call, "Reconnection budget exhausted after \(reconnectAttempt) attempts")
            fail(.lostConnection)
            return
        }
        reconnectAttempt = next

        transition(to: .reconnecting(attempt: reconnectAttempt))

        let attempt = reconnectAttempt
        let delay = immediately ? nil : policy.delay(forAttempt: attempt)
        let id = UUID()
        reconnectAttemptID = id
        reconnectTask?.cancel()
        timerExpiries[.reconnectBackoff] = nil
        let sleep = self.sleep
        let run: @MainActor () async -> Void = { [weak self] in
            guard let self, !Task.isCancelled, self.reconnectAttemptID == id else { return }
            await self.retryConnect(id, attempt: attempt)
        }
        if delay != nil {
            // Run out early, the attempt starts at once, in a task of its own.
            timerExpiries[.reconnectBackoff] = { [weak self] in
                guard let self else { return }
                self.reconnectTask?.cancel()
                self.reconnectTask = Task { await run() }
            }
        }
        reconnectTask = Task { [weak self] in
            if let delay { try? await sleep(delay) }
            if !Task.isCancelled { self?.timerExpiries[.reconnectBackoff] = nil }
            await run()
        }
    }

    /// A held call spends no attempts: any pending one is cancelled, the count
    /// starts over, and the call shows `reconnecting(attempt: 0)` until the resume.
    private func pauseReconnection() {
        stopReconnectAttempt()
        reconnectAttempt = 0
        isReconnectionPaused = true
        Log.info(.call, "Connection lost while held; reconnecting after the resume")
        transition(to: .reconnecting(attempt: 0))
    }

    private func retryConnect(_ id: UUID, attempt: Int) async {
        guard let transport, let target = currentTarget else { return }
        // Success surfaces as a `.connected` event; a transport that reports the
        // failed attempt as a `.disconnected` event schedules the next attempt there.
        // A transport that instead throws is chained here, and one that joins but
        // never reports is bounded by the join deadline, so the loop never stalls.
        // Both awaits can outlive the call or the attempt: once either is over, this
        // attempt is inert.
        do {
            let connection = try await target.connect(connectRequest(.reconnect(attempt: attempt)))
            guard isCurrentAttempt(id, on: transport) else { return }
            joiningAttemptID = id
            defer { if joiningAttemptID == id { joiningAttemptID = nil } }
            try await transport.connect(connection)
            guard isCurrentAttempt(id, on: transport), state == .reconnecting(attempt: attempt) else { return }
            startJoinDeadline(for: transport)
        } catch {
            Log.error(.transport, "Reconnect attempt failed: \(error)")
            guard isCurrentAttempt(id, on: transport) else { return }
            // Rejected credentials will be rejected again; only other failures retry.
            if (error as? TransportError) == .authenticationFailed {
                fail(.badToken)
            } else {
                scheduleReconnect()
            }
        }
    }

    /// Stop the attempt in progress because the call recovered or was held. Its
    /// backoff and its credential fetch are cancelled, but a `transport.connect`
    /// it has started runs to its end, with its outcome ignored: the transport may
    /// be taking its session over there, and an SDK whose join honours task
    /// cancellation would abandon the very session the call now counts on.
    private func stopReconnectAttempt() {
        if joiningAttemptID == nil || joiningAttemptID != reconnectAttemptID {
            reconnectTask?.cancel()
        }
        reconnectAttemptID = nil
        reconnectTask = nil
        timerExpiries[.reconnectBackoff] = nil
        cancelJoinDeadline()
    }

    private func isCurrentAttempt(_ id: UUID, on transport: CallTransport) -> Bool {
        self.transport === transport && reconnectAttemptID == id && !Task.isCancelled
    }

    /// The call's first connect returned: wait for the agent, bounded unless held.
    private func awaitAgent(on transport: CallTransport) {
        isAwaitingAgent = true
        guard !isOnHold else { return }
        startJoinDeadline(for: transport)
    }

    /// Bound the wait for `.connected` after `transport`'s connect returned without
    /// throwing, on the first connect and on every reconnect attempt: a transport
    /// can join and then never report the agent ready. When
    /// `CallEngineConfiguration.joinTimeout` runs out with the call still waiting in
    /// the same state, the wait is over (`joinTimedOut`).
    private func startJoinDeadline(for transport: CallTransport) {
        cancelJoinDeadline()
        guard let timeout = configuration.joinTimeout else { return }
        let waitingIn = state
        let attemptID = reconnectAttemptID
        joinDeadlineTask = startTimer(.joinTimeout, after: timeout) { [weak self] in
            guard let self, self.transport === transport,
                  self.state == waitingIn, self.reconnectAttemptID == attemptID
            else { return }
            self.joinDeadlineTask = nil
            self.joinTimedOut(after: timeout)
        }
    }

    /// Bound a ring's joined transport's wait for its agent, as `startJoinDeadline`
    /// bounds a call's. During the ring, running out is a failed preparation; once
    /// the answer adopted the transport, the same bound keeps counting, and running
    /// out sends the call down the unprepared path (`joinTimedOut`).
    private func startRingJoinDeadline(for transport: CallTransport) {
        cancelJoinDeadline()
        guard let timeout = configuration.joinTimeout else { return }
        joinDeadlineTask = startTimer(.joinTimeout, after: timeout) { [weak self] in
            guard let self else { return }
            self.joinDeadlineTask = nil
            if transport === self.ringTransport {
                guard self.state == .incomingRinging, self.ringPreparationPhase == .connecting else { return }
                Log.warning(.call, "Ring preparation: the agent was not there within \(timeout) of the join")
                self.ringPreparationFailed()
            } else if transport === self.transport, case .connecting = self.state {
                self.joinTimedOut(after: timeout)
            }
        }
    }

    private func cancelJoinDeadline() {
        joinDeadlineTask?.cancel()
        joinDeadlineTask = nil
        timerExpiries[.joinTimeout] = nil
    }

    /// Run `expire` once `duration` has passed on the injected sleep, unless the
    /// returned task is cancelled first; until then `fireTimer(timer)` can run it out.
    private func startTimer(
        _ timer: EngineTimer,
        after duration: Duration,
        expire: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        timerExpiries[timer] = expire
        let sleep = self.sleep
        return Task { [weak self] in
            try? await sleep(duration)
            guard let self, !Task.isCancelled else { return }
            self.timerExpiries[timer] = nil
            expire()
        }
    }

    /// Test hook: run `timer` out now, as if its wait were over, when it is running.
    /// Returns whether it was.
    package func fireTimer(_ timer: EngineTimer) -> Bool {
        guard let expire = timerExpiries.removeValue(forKey: timer) else { return false }
        switch timer {
        case .ringTimeout:
            ringTimerTask?.cancel()
            ringTimerTask = nil
        case .joinTimeout:
            joinDeadlineTask?.cancel()
            joinDeadlineTask = nil
        case .selfHealTimeout:
            selfHealDeadlineTask?.cancel()
            selfHealDeadlineTask = nil
        case .signalRetry:
            signalRetryTask?.cancel()
            signalRetryTask = nil
        case .reconnectBackoff:
            break // its expiry replaces the waiting task itself
        }
        expire()
        return true
    }

    /// A call that never connected has nothing to retry: the agent never became
    /// ready. A reconnect attempt counts as failed.
    private func joinTimedOut(after timeout: Duration) {
        switch state {
        case .connecting where canFallBackFromPreparation:
            fallBackFromPreparation("the agent was not ready within \(timeout) of the join")
        case .connecting:
            Log.warning(.call, "Transport joined but the agent was not ready within \(timeout)")
            fail(.agentUnreachable)
        case .reconnecting(let attempt) where attempt >= 1:
            Log.warning(.call, "Reconnect attempt \(attempt) joined but reported no connection within \(timeout)")
            scheduleReconnect()
        default:
            break
        }
    }

    /// Test hook: await the in-flight reconnection attempt.
    package func awaitPendingReconnect() async {
        await reconnectTask?.value
    }

    // MARK: - CallKit audio-session handshake (CallProviderDelegate)

    package func providerDidActivate(_ audioSession: AudioSessionActivating) {
        Log.info(.callKit, "Audio session activated")
        workCount += 1
        activationTask = Task { [weak self] in await self?.activate(audioSession) }
    }

    /// Test hook: await every media command (attach, detach, mic) issued so far.
    package func awaitPendingMediaWork() async {
        await mediaTask?.value
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
            Log.warning(.callKit, "Audio session activated with no call in progress; ignored")
            return
        }
        // CallKit activates an incoming call's session only once its answer action
        // is fulfilled, so during a ring nobody answered it belongs to an earlier call.
        guard state != .incomingRinging || isAnswerRequested else {
            Log.warning(.callKit, "Audio session activated during an unanswered ring; ignored")
            return
        }
        isAudioActivated = true
        switch interruption {
        case .interrupted: interruption = .interrupted(reactivated: true)
        case .endedAwaitingActivation: interruption = .none
        case .none: break
        }
        // A call that connected before this activation is marked connected now.
        markConnectedIfDue()
        // A transport created later attaches as soon as it exists; a held call's
        // attaches on the resume.
        guard let transport else { return }
        if !isOnHold { enqueueMedia { await $0.attachAudioSession() } }
        // Enabling the mic only takes effect once the transport is connected. If
        // CallKit activates BEFORE connect (e.g. slow credential resolution delays the
        // join), this is a no-op and the mic is (re)enabled in `handleConnected`.
        await applyMic()?.value
        guard self.transport === transport else { return }
        // After the attach and the mic, so an agent waiting for the answer starts
        // speaking into a running audio engine.
        sendAnswerSignalIfDue()
        // Route work waited for this activation; a call already connected gets the
        // hands-free default now, one still connecting gets it when it connects.
        if case .connected = state {
            scheduleAudioDeviceUpdate()
        } else {
            await refreshAudioDevices(of: transport)
        }
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
        Log.info(.callKit, "Audio session deactivated")
        isAudioActivated = false
        applyMic()
        enqueueMedia { await $0.detachAudioSession() }
    }

    package func providerPerformAnswerCall(_ id: UUID) {
        Log.info(.callKit, "System requested answer")
        // Only the ringing call can be answered, not a busy ring CallKit still shows.
        guard activeCallID == id else {
            Log.warning(.callKit, "Answer for call \(id), which is not the ringing call; ignored")
            return
        }
        // Before the hop to `answer()`: from here on the ring is the user's, and
        // neither its timer nor a cancel push may end it.
        isAnswerRequested = true
        cancelRingTimer()
        Task { [weak self] in await self?.answer() }
    }

    package func providerPerformEndCall(_ id: UUID) {
        Log.info(.callKit, "System requested end call")
        // Idempotent against our own End path, which already finished and reset (so
        // `activeCallID` is nil): only act while this id is still the live call.
        guard activeCallID == id else { return }
        finishEnded()
    }

    package func providerPerformSetMuted(_ id: UUID, muted: Bool) {
        guard activeCallID == id else {
            Log.warning(.callKit, "Mute for call \(id), which is not the live call; ignored")
            return
        }
        isMuted = muted
        if !muted { endInterruptionAwaitingActivation() }
        applyMic()
    }

    // MARK: - Hold (CallProviderDelegate)

    package func providerPerformSetHeld(_ id: UUID, onHold: Bool) -> Bool {
        guard activeCallID == id else {
            Log.warning(.callKit, "Hold for call \(id), which is not the live call; refused")
            return false
        }
        guard configuration.supportsHolding, canBeHeld else {
            Log.warning(.callKit, "Hold for call \(id) refused in state \(String(describing: state))")
            return false
        }
        guard onHold != isOnHold else { return true }
        if onHold { hold() } else { resume() }
        return true
    }

    /// Placed or answered and not over: a ring or a call still dialing cannot be held.
    private var canBeHeld: Bool {
        switch state {
        case .connecting, .connected, .reconnecting: true
        default: false
        }
    }

    private func hold() {
        Log.info(.call, "Call held")
        isOnHold = true
        signalRetryCount = 0
        applyMic()
        enqueueMedia { await $0.detachAudioSession() }
        syncHoldSignal()
        if repeatingCue != nil {
            repeatingCue = nil
            delegate?.callEngine(self, cue: .stop)
        }
        delegate?.callEngine(self, cue: .moment(.held))
        // The wait for a first connection's agent is not bounded while held.
        if case .connecting = state { cancelJoinDeadline() }
        // A retry already scheduled would spend the budget during the hold.
        if reconnectTask != nil { pauseReconnection() }
    }

    private func resume() {
        Log.info(.call, "Call resumed")
        isOnHold = false
        signalRetryCount = 0
        if isAudioActivated { enqueueMedia { await $0.attachAudioSession() } }
        applyMic()
        syncHoldSignal()
        sendAnswerSignalIfDue()
        delegate?.callEngine(self, cue: .moment(.resumed))
        markConnectedIfDue()
        if case .reconnecting = state, !isOutageMarked {
            isOutageMarked = true
            delegate?.callEngine(self, cue: .moment(.connectionLost))
        }
        if let loop = wantedLoop(for: state) {
            repeatingCue = loop
            delegate?.callEngine(self, cue: .start(loop))
        }
        if isReconnectionPaused {
            isReconnectionPaused = false
            scheduleReconnect(immediately: true)
        }
        if case .connecting = state, isAwaitingAgent, let transport {
            startJoinDeadline(for: transport)
        }
    }

    /// Tell the agent whether the call is held, whenever it can be told: on hold
    /// and resume while connected, on every connection (a reconnect may reach a new
    /// agent session, or the same one, which may have missed a resume), and on a
    /// retry after a signal failed to leave the device.
    private func syncHoldSignal() {
        guard case .connected = state else { return }
        if isOnHold {
            isAgentToldHeld = true
            sendHoldSignal(.held)
        } else if isAgentToldHeld {
            sendHoldSignal(.resumed)
        }
    }

    /// `resumed` says the user can hear the agent again, so it follows the attach
    /// and mic commands issued so far; `held` goes at once.
    private func sendHoldSignal(_ signal: CallSignal) {
        holdSignalGeneration += 1
        let generation = holdSignalGeneration
        send(signal, after: signal == .resumed ? mediaTask : nil) { [weak self] delivery in
            guard let self, generation == self.holdSignalGeneration else { return }
            switch delivery {
            case .sent, .unsupported:
                // Only now can the agent be taken to have heard the resume.
                if signal == .resumed { self.isAgentToldHeld = false }
                if delivery == .sent { self.signalRetryCount = 0 }
            case .failed:
                Log.warning(.call, "Signal \(signal.rawValue) did not leave the device; sending the call's state again")
                self.scheduleSignalRetry()
            }
        }
    }

    /// A new connection: delivery results from the old one change nothing, and the
    /// retries start over.
    private func startSignalConnection() {
        connectionGeneration += 1
        signalRetryCount = 0
    }

    /// Send the call's state again after a short wait that grows with each retry. A
    /// retry sends the state as it is when it runs, not the signal that failed. After
    /// the last one the engine waits for the next connection, which is told again.
    private func scheduleSignalRetry() {
        guard signalRetryTask == nil else { return }
        guard signalRetryCount < Self.signalRetryDelays.count else {
            Log.warning(.call, "Signals still not leaving the device after \(signalRetryCount) retries; waiting for the next connection")
            return
        }
        let delay = Self.signalRetryDelays[signalRetryCount]
        signalRetryCount += 1
        signalRetryTask = startTimer(.signalRetry, after: delay) { [weak self] in
            guard let self else { return }
            self.signalRetryTask = nil
            guard case .connected = self.state else { return }
            self.syncHoldSignal()
            self.sendAnswerSignalIfDue()
        }
    }

    private func cancelSignalRetry() {
        signalRetryTask?.cancel()
        signalRetryTask = nil
        timerExpiries[.signalRetry] = nil
        signalRetryCount = 0
    }

    /// Queue `signal` after the signals already queued and, when given, after the
    /// media command `barrier`; a signal never holds up a media command. `delivered`
    /// gets the transport's result, unless the call's transport changed meanwhile.
    private func send(
        _ signal: CallSignal,
        after barrier: Task<Void, Never>? = nil,
        delivered: (@MainActor (CallSignalDelivery) -> Void)? = nil
    ) {
        guard let transport else { return }
        workCount += 1
        let previous = signalTask
        signalTask = Task { [weak self] in
            await previous?.value
            await barrier?.value
            guard let self, self.transport === transport else { return }
            let delivery = await transport.send(signal)
            guard self.transport === transport else { return }
            delivered?(delivery)
        }
    }

    /// Tell an agent that may be waiting for the answer (the push carried
    /// `preconnect`) that it can speak, once the user has answered, CallKit has
    /// activated the audio and the transport is connected, whichever comes last;
    /// again on every new connection; and not while held (the resume sends it). It
    /// follows the attach and mic commands issued so far.
    private func sendAnswerSignalIfDue() {
        guard signalsAnswer, callDirection == .incoming, !isAnswerSignalSent,
              case .connected = state, isAudioActivated, !isOnHold
        else { return }
        isAnswerSignalSent = true
        let connection = connectionGeneration
        send(.answered, after: mediaTask) { [weak self] delivery in
            guard let self, connection == self.connectionGeneration, self.isAnswerSignalSent else { return }
            switch delivery {
            case .sent: self.signalRetryCount = 0
            case .unsupported: break
            case .failed:
                Log.warning(.call, "Signal \(CallSignal.answered.rawValue) did not leave the device; sending it again")
                self.isAnswerSignalSent = false
                self.scheduleSignalRetry()
            }
        }
    }

    /// Test hook: await every call-control signal sent so far.
    package func awaitPendingSignals() async {
        await signalTask?.value
    }

    /// Start `operation` in a task of its own and keep it until it is done, so
    /// `awaitPendingWork()` can wait for it.
    private func startDetachedWork(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        workCount += 1
        detachedWork[id] = Task { [weak self] in
            await operation()
            self?.detachedWork[id] = nil
        }
    }

    /// Test hook: await the work the engine has started by itself (the activation,
    /// media and signal commands, route refreshes, teardowns, the connect after a
    /// failed preparation) and whatever that work starts in turn, until none is left.
    /// Not the reconnect attempt or the ring's preparation, nor anything waiting on
    /// a timer.
    package func awaitPendingWork() async {
        var seen = -1
        while seen != workCount {
            seen = workCount
            await activationTask?.value
            await mediaTask?.value
            await signalTask?.value
            for task in Array(detachedWork.values) { await task.value }
        }
    }

    /// The reset already ended every call in CallKit, so nothing is reported back
    /// to it; the host still hears the call end and gets its record.
    package func providerWasReset() {
        Log.warning(.callKit, "Provider reset; tearing down call")
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
    // touch the audio session — CallKit owns it and may activate it again around
    // the interruption's end, in either order; each edge re-derives the mic.

    package func audioInterruptionBegan() {
        guard state.isActive, !state.isTerminal else { return }
        Log.info(.call, "Call interrupted; pausing mic")
        interruption = .interrupted(reactivated: false)
        applyMic()
    }

    package func audioInterruptionEnded(shouldResume: Bool) {
        Log.info(.call, "Interruption ended; resume=\(shouldResume)")
        switch interruption {
        case .none:
            return
        case .interrupted(reactivated: true):
            // CallKit already handed the session back during the interruption.
            interruption = .none
        case .interrupted, .endedAwaitingActivation:
            interruption = shouldResume ? .none : .endedAwaitingActivation
        }
        applyMic()
    }

    /// The user asking for the mic (unmuting, pressing push-to-talk) ends an
    /// interruption that ended without permission to resume.
    private func endInterruptionAwaitingActivation() {
        if interruption == .endedAwaitingActivation { interruption = .none }
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
        if !muted { endInterruptionAwaitingActivation() }
        // Captured first: after the await below this may be a newer call.
        let id = activeCallID
        await applyMic()?.value
        if let id { await callProvider.setMuted(id, muted: muted) }
    }

    /// Push-to-talk: open the mic only while the button is held (PTT mode only),
    /// and only once CallKit has activated the session and nothing interrupts it.
    public func setPushToTalkActive(_ active: Bool) async {
        guard isPushToTalkEnabled() else { return }
        isPushToTalkHeld = active
        if active { endInterruptionAwaitingActivation() }
        await applyMic()?.value
    }

    /// Ask CallKit to hold or resume the call, as the system UI would. CallKit
    /// performs the hold through the engine, which then updates `isOnHold`; on a
    /// device that can land just after this returns. Does nothing without a call
    /// that can be held (connecting, connected or reconnecting), or when
    /// `CallEngineConfiguration.supportsHolding` is false. While held, the user's
    /// mute and push-to-talk changes are recorded and apply on resume.
    public func setOnHold(_ onHold: Bool) async {
        guard configuration.supportsHolding, canBeHeld, let id = activeCallID else {
            Log.warning(.call, "setOnHold(\(onHold)) ignored; state is \(String(describing: state))")
            return
        }
        await callProvider.setHeld(id, onHold: onHold)
        await mediaTask?.value
    }

    // MARK: - Audio route (driven through the transport so the SDK honors it)

    /// Route audio to one of `audioDevices`. Ignored until CallKit has activated
    /// the call's session (`isAudioActivated`): `audioDevices` is empty until then.
    public func selectAudioDevice(_ id: String) async {
        guard let transport else { return }
        guard isAudioActivated else {
            Log.warning(.audio, "selectAudioDevice(\(id)) ignored: CallKit has not activated the session")
            return
        }
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
    /// default once it's available. Runs on connect, on device changes, and on
    /// CallKit's activation, for the transport live when it was scheduled; never
    /// while the session is not activated, when a route read is meaningless and an
    /// output-port override is lost (and the default would count as applied).
    private func scheduleAudioDeviceUpdate() {
        guard let transport, isAudioActivated else { return }
        startDetachedWork { [weak self] in
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
    package var hasTransport: Bool { transport != nil || ringTransport != nil }

    // MARK: - The mic rule and media commands

    /// Where an interruption stands, as far as the mic is concerned.
    private enum InterruptionPhase: Equatable {
        case none
        /// Another audio session took over. `reactivated` once CallKit has
        /// activated the session again since the interruption began.
        case interrupted(reactivated: Bool)
        /// It ended without permission to resume before CallKit activated the
        /// session again: the mic waits for that activation, or for the user.
        case endedAwaitingActivation
    }

    /// The one mic rule: on only on a session CallKit has activated, while the
    /// call is not on hold and no other audio holds the session, then following
    /// mute, or in push-to-talk mode the button.
    private var micShouldBeOn: Bool {
        guard isAudioActivated, !isOnHold, !isInterrupted else { return false }
        return isPushToTalkEnabled() ? isPushToTalkHeld : !isMuted
    }

    /// Re-derive the mic from `micShouldBeOn` and send it to the live transport.
    /// Every change to an input of the rule calls this. The rule is read when the
    /// command runs, after the commands before it, so the transport always ends
    /// up with the current rule whatever order the inputs arrived in.
    @discardableResult
    private func applyMic() -> Task<Void, Never>? {
        enqueueMedia { [weak self] transport in
            guard let self else { return }
            await transport.setMicEnabled(self.micShouldBeOn)
        }
    }

    /// Queue a media command for the live transport, after the ones already
    /// queued. It is skipped if that transport is no longer the call's when its
    /// turn comes.
    @discardableResult
    private func enqueueMedia(_ command: @escaping @MainActor (CallTransport) async -> Void) -> Task<Void, Never>? {
        guard let transport else { return nil }
        workCount += 1
        let previous = mediaTask
        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.transport === transport else { return }
            await command(transport)
        }
        mediaTask = task
        return task
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
        interruption = .none
        // The session CallKit activated belonged to this call.
        isAudioActivated = false
        reconnectAttemptID = nil
        joiningAttemptID = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        timerExpiries[.reconnectBackoff] = nil
        cancelSelfHealDeadline()
        cancelJoinDeadline()
        eventTask?.cancel()
        eventTask = nil
        mediaTask = nil
        signalTask = nil
        cancelSignalRetry()
        isOnHold = false
        isAgentToldHeld = false
        isReconnectionPaused = false
        isAnswerSignalSent = false
        isAwaitingAgent = false
        isPreparedConnect = false
        freshConnectID = nil
        cancelRingPreparation()
        activeCallID = nil
        let outgoing = transport
        transport = nil
        startDetachedWork {
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
        interruption = .none
        isOnHold = false
        isAgentToldHeld = false
        isReconnectionPaused = false
        isAwaitingAgent = false
        isPreparedConnect = false
        freshConnectID = nil
        isOutageMarked = false
        isConnectionMarked = false
        audioDevices = []
        selectedAudioDeviceID = nil
        didApplyHandsFreeDefault = false
        isPushToTalkHeld = false
        endedByUser = false
        isAnswerRequested = false
        signalsAnswer = false
        isAnswerSignalSent = false
        cancelRingPreparation()
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
    /// moment outside a loop and at most one loop running. A held call gets no
    /// cues; `resume()` delivers what its state wants then.
    private func deliverCues(from old: CallState, to new: CallState) {
        if case .connected = new { isOutageMarked = false }
        let loop = isOnHold ? nil : wantedLoop(for: new)
        var moment: CallMoment?
        if !isOnHold {
            switch (old, new) {
            case (.connecting, .connected), (.incomingRinging, .connected):
                moment = isAudioActivated ? .connected : nil
            case (.reconnecting, .connected):
                // A call the user never heard connect is marked connected, not back.
                moment = isConnectionMarked ? .reconnected : (isAudioActivated ? .connected : nil)
            case (.connected, .reconnecting): moment = .connectionLost
            default: moment = nil
            }
        }
        if moment == .connectionLost { isOutageMarked = true }
        if moment == .connected { isConnectionMarked = true }

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

    /// Deliver `.moment(.connected)` once the call is connected, CallKit has
    /// activated its audio and it is not held, whichever comes last, so a host that
    /// plays a sound on it plays into a live session. When the activation or the
    /// resume is last, the moment comes with no state change.
    private func markConnectedIfDue() {
        guard case .connected = state, !isConnectionMarked, isAudioActivated, !isOnHold else { return }
        isConnectionMarked = true
        delegate?.callEngine(self, cue: .moment(.connected))
    }

    private func wantedLoop(for state: CallState) -> RepeatingCue? {
        switch state {
        case .connecting: .connecting
        case .reconnecting: .retrying
        default: nil
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
    /// `ring_timeout`), `"cancel"` (the server may send a cancel push,
    /// `{"action": "cancel", "call_id": ...}` with no `target_id`, to withdraw a
    /// ring) and `"preconnect"` (a ring push may carry `preconnect`, and the engine
    /// sends `CallSignal.answered`; see `RingPreparation`). An engine that lacks a feature ignores its key, or, for a cancel,
    /// shows it as a brief incoming call that ends at once. Later versions add
    /// features to this set; servers must ignore names they do not know.
    nonisolated public static let supportedPushFeatures: Set<String> = ["cancel", "ring_timeout", "preconnect"]
}

extension CallEngine {
    /// How many cancelled call ids are remembered, newest first, so a ring that
    /// APNs delivers after its own cancel is ended at once.
    package nonisolated static let rememberedCancelLimit = 32
    /// How long a cancelled call id is remembered.
    package nonisolated static let rememberedCancelLifetime: TimeInterval = 10 * 60
    /// The shortest ring a push's `ring_timeout` can ask for.
    package nonisolated static let minimumPushedRingTimeout: Duration = .seconds(10)
    /// The waits before each retry of a signal that did not leave the device.
    package nonisolated static let signalRetryDelays: [Duration] = [1, 2, 4, 8, 16, 30].map { .seconds($0) }
}
