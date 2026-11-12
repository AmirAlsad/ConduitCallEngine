//
//  FakeTransport.swift
//  ConduitCallEngine
//
//  Fake conforming to `CallTransport`, for the simulator and tests. A test pushes
//  events with `emit(_:)` and asserts the engine reacts, and reads what the engine
//  did to it (connects, mic, attach, signals).
//

import Foundation
import ConduitCallEngine

public final class FakeTransport: CallTransport, @unchecked Sendable {
    public let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    public private(set) var connectCount = 0
    public private(set) var disconnectCount = 0
    public private(set) var lastConnection: CallConnection?
    public private(set) var isMicEnabled = false
    public private(set) var setMicEnabledCallCount = 0
    public private(set) var isAudioAttached = false
    /// How many `connect(_:)` calls found their task cancelled when they finished.
    /// An SDK whose join is cancellation-aware (LiveKit's `Room.connect`, for one)
    /// abandons the join then, so a test can check the engine never cancels one it
    /// still needs.
    public private(set) var cancelledConnectCount = 0

    /// When set, the next `connect(_:)` throws this instead of succeeding.
    public var connectError: TransportError?

    /// When true, `connect(_:)` suspends until `releaseConnect()` — lets a test fail
    /// and reset the call before `connect` resolves, exercising late-resolution races.
    public var suspendConnect = false
    private var connectContinuation: CheckedContinuation<Void, Never>?
    private var connectReleased = false

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.events = stream
        self.continuation = continuation
    }

    public func connect(_ connection: CallConnection) async throws {
        connectCount += 1
        lastConnection = connection
        if suspendConnect {
            await withCheckedContinuation { cont in
                if connectReleased { cont.resume() } else { connectContinuation = cont }
            }
        }
        if Task.isCancelled { cancelledConnectCount += 1 }
        if let connectError { throw connectError }
    }

    /// Resume a `connect(_:)` suspended by `suspendConnect` (resolves on the next call
    /// if it hasn't suspended yet).
    public func releaseConnect() {
        if let cont = connectContinuation {
            connectContinuation = nil
            cont.resume()
        } else {
            connectReleased = true
        }
    }

    public func disconnect() async {
        disconnectCount += 1
    }

    public func setMicEnabled(_ enabled: Bool) async {
        isMicEnabled = enabled
        setMicEnabledCallCount += 1
    }

    public var fakeAudioDevices: [AudioDeviceInfo] = [
        AudioDeviceInfo(id: "speaker", name: "Speaker"),
        AudioDeviceInfo(id: "receiver", name: "iPhone"),
    ]
    public private(set) var selectedAudioDeviceID = "speaker"

    public func availableAudioDevices() async -> [AudioDeviceInfo] { fakeAudioDevices }
    public func selectedAudioDevice() async -> AudioDeviceInfo? {
        fakeAudioDevices.first { $0.id == selectedAudioDeviceID }
    }
    public func setAudioDevice(_ id: String) async { selectedAudioDeviceID = id }

    /// When true, `attachAudioSession()` suspends until `releaseAttach()` — stands in
    /// for a transport whose attach does real async work.
    public var suspendAttach = false
    public private(set) var pendingAttachCount = 0
    private var attachContinuations: [CheckedContinuation<Void, Never>] = []

    public func releaseAttach() {
        let waiting = attachContinuations
        attachContinuations = []
        pendingAttachCount = 0
        waiting.forEach { $0.resume() }
    }

    public func attachAudioSession() async {
        if suspendAttach {
            pendingAttachCount += 1
            await withCheckedContinuation { attachContinuations.append($0) }
        }
        isAudioAttached = true
    }

    public func detachAudioSession() async {
        isAudioAttached = false
    }

    /// Every call-control signal the engine sent, in order.
    public private(set) var sentSignals: [CallSignal] = []

    public func send(_ signal: CallSignal) async {
        sentSignals.append(signal)
    }

    /// Drive an event onto the stream from a test or a simulator build.
    public func emit(_ event: TransportEvent) {
        continuation.yield(event)
    }

    /// Close the event stream (mirrors a fully torn-down transport).
    public func finish() {
        continuation.finish()
    }
}
