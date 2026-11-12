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
    /// Whether CallKit has activated the audio session for the live call.
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
    private var eventTask: Task<Void, Never>?
    package private(set) var reconnectTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
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
    public func startPushRegistration() {
        guard !isPushRegistrationStarted else { return }
        isPushRegistrationStarted = true
        pushRegistry.start(
            onTokenUpdate: { [weak self] token in
                guard let self else { return }
                delegate?.callEngine(self, didUpdateVoIPPushToken: token)
            },
            onIncomingPush: { [weak self] payload, completion in
                guard let self else { return completion() }
                handleIncomingPush(payload, completion: completion)
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
    /// report an incoming call before the push callback returns, so this reports
    /// FIRST — synchronously, under the identity the push itself carries — and only
    /// then touches state or the delegate. The target is resolved right after the
    /// report is issued; once CallKit accepts it, the ring is corrected if the
    /// target's name or handle differ. `completion` (PushKit's) runs after the report's completion, on
    /// every path.
    package func handleIncomingPush(_ dictionary: [AnyHashable: Any], completion: @escaping () -> Void) {
        guard let payload = IncomingCallPayload(dictionary: dictionary) else {
            let id = UUID()
            Log.warning(.callkit, "Malformed VoIP push; reporting call \(id) and ending it")
            callProvider.reportIncomingCall(
                id: id,
                handle: CallHandle(value: CallTarget.defaultHandle(for: id)),
                displayName: unknownCallerName
            ) { [self] _ in
                callProvider.reportCallEnded(id, reason: .failed)
                completion()
            }
            return
        }

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

        // The report's completion may arrive before this method finishes (a fake
        // completes synchronously); hold it until the ring is set up.
        var ringIsSetUp = false
        var earlyResult: IncomingCallReportError??
        var ringTarget: CallTarget?
        let finishRing: (IncomingCallReportError?) -> Void = { [self] result in
            if isBusy {
                completeBusyRing(incoming, payload: payload, result: result)
            } else {
                completeRing(incoming, target: ringTarget, result: result)
            }
            completion()
        }
        callProvider.reportIncomingCall(
            id: incoming.callID,
            handle: CallHandle(value: incoming.handle),
            displayName: incoming.displayName
        ) { result in
            if ringIsSetUp { finishRing(result) } else { earlyResult = .some(result) }
        }

        if isBusy {
            Log.warning(.call, "Busy on VoIP push; reported call \(incoming.callID), ending it")
        } else {
            ringTarget = beginRing(incoming, payload: payload)
        }
        ringIsSetUp = true
        if let earlyResult { finishRing(earlyResult) }
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
        ringStatusURL = payload.statusURL
        transition(to: .incomingRinging)
        interruptionObserver.startObserving()
        return target
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
        if result == nil {
            if let target = delegate?.callEngine(self, targetForIncomingCall: incoming) {
                correctRingIfNeeded(incoming, to: target)
            }
            // Only a call CallKit created can be ended. A failed report created
            // nothing, and its id may even be the live call's (a duplicate push).
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
        if let url = payload.statusURL {
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
            Task { [weak self] in await self?.updateAudioDevices() }

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
            Task { [weak self] in await self?.updateAudioDevices() }
            Log.info(.call, "Connected")

        case .reconnecting:
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
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
        guard isAudioActivated else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.transport?.setMicEnabled(self.micShouldBeOn)
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
        default:
            Log.error(.transport, "Transport error during call: \(error)")
        }
    }

    // MARK: - Reconnection (event-driven; each drop is one attempt)

    /// Display-only response to a transport that is self-healing. It does NOT count
    /// against the reconnection budget or schedule our own retry — the budget is
    /// owned solely by `scheduleReconnect` (driven by `.disconnected`). The transport
    /// must follow a `.reconnecting` with a `.connected` or `.disconnected`.
    private func enterReconnectingDisplay() {
        transition(to: .reconnecting(attempt: reconnectAttempt))
    }

    private func scheduleReconnect() {
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
            scheduleReconnect()
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
        isAudioActivated = true
        await transport?.attachAudioSession()
        // Enabling the mic only takes effect once the transport is connected. If
        // CallKit activates BEFORE connect (e.g. slow credential resolution delays the
        // join), this is a no-op and the mic is (re)enabled in `handleConnected`.
        await transport?.setMicEnabled(micShouldBeOn)
        await refreshAudioDevices()
    }

    /// Hands-free default: prefer the loudspeaker when nothing external (car /
    /// Bluetooth / wired) is connected, so call audio isn't stuck on the quiet
    /// earpiece. Driven through the transport, because an SDK that manages the
    /// session itself reverts a direct AVAudioSession override. Runs once per call,
    /// on connect or a device change, once the device list is populated.
    private func applyHandsFreeDefaultIfNeeded() async {
        // Caller refreshes the device list first; bail until it's populated so a
        // later trigger (connect / devices-changed) can apply the default instead.
        guard !didApplyHandsFreeDefault, !audioDevices.isEmpty else { return }
        didApplyHandsFreeDefault = true

        let hasExternalRoute = audioDevices.contains {
            let kind = AudioRouteKind(deviceID: $0.id)
            return kind == .bluetooth || kind == .wired
        }
        guard !hasExternalRoute,
              let speaker = audioDevices.first(where: { AudioRouteKind(deviceID: $0.id) == .speaker })
        else { return }
        await transport?.setAudioDevice(speaker.id)
        await refreshAudioDevices()
    }

    package func providerDidDeactivate(_ audioSession: AudioSessionActivating) {
        Log.info(.callkit, "Audio session deactivated")
        isAudioActivated = false
        Task { [weak self] in await self?.transport?.detachAudioSession() }
    }

    package func providerPerformAnswerCall(_ id: UUID) {
        Log.info(.callkit, "System requested answer")
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
        isMuted = muted
        Task { [weak self] in await self?.transport?.setMicEnabled(self?.micShouldBeOn ?? false) }
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
        Task { [weak self] in await self?.transport?.setMicEnabled(false) }
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

    public func setMuted(_ muted: Bool) async {
        isMuted = muted
        await transport?.setMicEnabled(micShouldBeOn)
        if let id = activeCallID { await callProvider.setMuted(id, muted: muted) }
    }

    /// Push-to-talk: open the mic only while the button is held (PTT mode only).
    public func setPushToTalkActive(_ active: Bool) async {
        guard isPushToTalkEnabled() else { return }
        await transport?.setMicEnabled(active)
    }

    // MARK: - Audio route (driven through the transport so the SDK honors it)

    public func selectAudioDevice(_ id: String) async {
        await transport?.setAudioDevice(id)
        await refreshAudioDevices()
    }

    private func refreshAudioDevices() async {
        audioDevices = await transport?.availableAudioDevices() ?? []
        selectedAudioDeviceID = await transport?.selectedAudioDevice()?.id
    }

    /// Refresh the route list (keeps the picker live) and apply the hands-free
    /// default once it's available. Called on connect and on device changes.
    private func updateAudioDevices() async {
        await refreshAudioDevices()
        await applyHandsFreeDefaultIfNeeded()
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

    private var micShouldBeOn: Bool {
        !isMuted && !isPushToTalkEnabled()
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
        interruptionObserver.stopObserving()
        isInterrupted = false
        reconnectTask?.cancel()
        reconnectTask = nil
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
        endedByUser = false
        transition(to: .idle)
    }

    /// Assign the state and tell the delegate. Callers set the transition's other
    /// fields first, so the delegate sees a consistent snapshot.
    private func transition(to new: CallState) {
        let old = state
        state = new
        guard old != new else { return }
        delegate?.callEngine(self, didChangeStateFrom: old, to: new)
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
