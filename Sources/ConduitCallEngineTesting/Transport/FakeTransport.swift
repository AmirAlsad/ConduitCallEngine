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

    /// What the transport declares to the engine; false (the protocol's default)
    /// unless a test sets it. Set it before the engine creates the transport for a
    /// ring: the engine reads it once, right after creating it.
    public var canConnectWhileRinging = false

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

    /// How many times the engine read the routes (`availableAudioDevices()` or
    /// `selectedAudioDevice()`).
    public private(set) var audioDeviceReadCount = 0
    /// Every route the engine selected with `setAudioDevice(_:)`, in order.
    public private(set) var audioDeviceSelections: [String] = []

    public func availableAudioDevices() async -> [AudioDeviceInfo] {
        audioDeviceReadCount += 1
        return fakeAudioDevices
    }
    public func selectedAudioDevice() async -> AudioDeviceInfo? {
        audioDeviceReadCount += 1
        return fakeAudioDevices.first { $0.id == selectedAudioDeviceID }
    }
    public func setAudioDevice(_ id: String) async {
        audioDeviceSelections.append(id)
        selectedAudioDeviceID = id
    }

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
