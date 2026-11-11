//
//  SimulatedCallSystem.swift
//  ConduitCallEngine
//
//  Stands in for CallKit, PushKit, the audio-interruption source, and ring-status
//  receipts, so a host can run a `CallEngine` in the simulator and in its own tests.
//  It drives what the system would do (deliver a push or a token, answer or end a
//  call from the system UI, reset the provider, deliver a transport event) and
//  exposes what the engine reported, in plain types.
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

    /// When true, incoming reports complete only on `completeIncomingReports()`
    /// (real CallKit completes later); when false they complete at once.
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

    /// The system reset the CallKit provider.
    public func resetProvider() {
        provider.simulateReset()
    }

    /// The live call's transport emitted `event`, delivered synchronously.
    public func deliverTransportEvent(_ event: TransportEvent) {
        engine?.handle(event)
    }

    /// Wait for the reconnect attempt in flight, if any.
    public func awaitPendingReconnect() async {
        await engine?.awaitPendingReconnect()
    }

    // MARK: - Observations

    /// A call as the engine reported it to CallKit.
    public struct ReportedCall: Equatable, Sendable {
        public let id: UUID
        public let handle: String
        public let displayName: String
    }

    /// A ring-status receipt the engine sent.
    public struct RingReceipt: Equatable, Sendable {
        /// `answered`, `declined`, `busy`, or `suppressed_by_focus`.
        public let status: String
        public let callID: UUID
        public let endpoint: URL
        public let bearer: String
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
