//
//  DailyAudioRouteGate.swift
//  ConduitCallEngine
//
//  Decides which audio route a Daily call asks Daily to prefer, and when, kept pure
//  and SDK-free so every rule is unit-testable.
//
//  Daily manages the audio session itself. With no preferred device it configures
//  the session for video chat, which iOS plays on the loudspeaker, and it applies
//  that whenever it configures the session: when it starts managing it at the join,
//  and after every change to its inputs (the join's, and each mic enable), which
//  resets its preferred device to that default unless the microphone input names a
//  device. Left alone, a call CallKit started on the earpiece therefore moves to the
//  loudspeaker while it connects. So once CallKit has activated the session the
//  adapter asks Daily to prefer the route the call is on (the first attach reads
//  it), and the engine's own request (the speaker default, the user's pick) wins
//  over it. A route the adapter cannot name to Daily (car audio, AirPlay, USB) is
//  left to Daily, as before.
//
//  The wanted route is given to every Daily session before its join, so a reconnect
//  or a session taken over keeps it, and is never given before the first attach of
//  a join made while the call rings, which must leave audio alone until then.
//
//  While the adapter follows the call's route (no engine request), a Bluetooth or
//  wired device that appears in Daily's device list is followed, as a phone call
//  moves to a headset connected during it; when the followed device disappears, the
//  call follows a remaining Bluetooth or wired device, or else the earpiece. The
//  first device list is the baseline, so devices already there move nothing.
//
//  Changes are applied one at a time, always toward the latest wanted route. A new
//  session forgets what was applied to the old one. After the join, what Daily then
//  reports as its preferred device counts as applied, so a preference Daily dropped
//  meanwhile is asked for again. A change Daily refused is not retried until
//  something changes (an attach, a request, a device change, a new session, the
//  join completing).
//

import AVFoundation
import ConduitCallEngine

/// An audio route Daily can be asked to prefer.
enum DailyAudioRoute: String, CaseIterable, Sendable {
    case earpiece
    case speaker
    case bluetooth
    case wired
}

extension DailyAudioRoute {
    /// The route of a CallKit-activated session's output port; nil for one the
    /// adapter leaves to Daily (car audio, AirPlay, USB, HDMI and the like).
    init?(outputPort: AVAudioSession.Port) {
        switch outputPort {
        case .builtInReceiver: self = .earpiece
        case .builtInSpeaker: self = .speaker
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: self = .bluetooth
        case .headphones, .headsetMic: self = .wired
        default: return nil
        }
    }

    /// The route of a device id Daily lists (`earpiece`, `speakerphone`,
    /// `bluetooth`, `wired`), classified as the engine classifies ids.
    init?(deviceID: String) {
        switch AudioRouteKind(deviceID: deviceID) {
        case .receiver: self = .earpiece
        case .speaker: self = .speaker
        case .bluetooth: self = .bluetooth
        case .wired: self = .wired
        case .other: return nil
        }
    }
}

struct DailyAudioRouteGate {
    /// One change to apply, tagged with the session it was decided for.
    struct Application: Equatable {
        let route: DailyAudioRoute
        let session: Int
    }

    /// What the engine asked for (`setAudioDevice`); wins over the followed route.
    private(set) var requested: DailyAudioRoute?
    /// The route the adapter keeps the call on while the engine has asked for none.
    private(set) var followed: DailyAudioRoute?
    private(set) var hasAttached = false
    /// A join while the call rings: nothing is asked of Daily before the first attach.
    private(set) var holdsBackUntilFirstAttach = false
    /// The routes in Daily's last non-empty device list; empty until one arrives.
    private(set) var knownDevices: Set<DailyAudioRoute> = []
    /// What Daily has been given in this session; `nil` if nothing yet.
    private(set) var applied: DailyAudioRoute?
    private(set) var isApplying = false
    private(set) var session = 0
    private var refused: DailyAudioRoute?

    /// The route Daily should prefer now; `nil` leaves Daily's own choice.
    var wanted: DailyAudioRoute? {
        guard hasAttached || (requested != nil && !holdsBackUntilFirstAttach) else { return nil }
        return requested ?? followed
    }

    /// Why `wanted` is what it is, for logs.
    var wantedReason: String {
        requested != nil ? "engine request" : "the call's route"
    }

    /// A join while the call rings: ask Daily for nothing until the first attach.
    /// Does nothing once the gate has been attached.
    mutating func holdUntilFirstAttach() {
        guard !hasAttached else { return }
        holdsBackUntilFirstAttach = true
    }

    /// CallKit activated the session (or a hold ended). The first attach takes
    /// `activeRoute`, the route the session is on now, as the route to keep, and
    /// `devices` as the baseline if no device list came before. Returns whether it
    /// was the first attach.
    @discardableResult
    mutating func attach(activeRoute: DailyAudioRoute?, devices: Set<DailyAudioRoute>) -> Bool {
        refused = nil
        guard !hasAttached else { return false }
        hasAttached = true
        followed = activeRoute
        if knownDevices.isEmpty { knownDevices = devices }
        return true
    }

    /// The engine asked for `route`, the speaker default or the user's pick.
    mutating func engineDidRequest(_ route: DailyAudioRoute) {
        requested = route
        refused = nil
    }

    /// Daily reported its device list. An empty list says nothing and is ignored.
    mutating func devicesDidChange(_ devices: Set<DailyAudioRoute>) {
        guard !devices.isEmpty else { return }
        let previous = knownDevices
        knownDevices = devices
        guard !previous.isEmpty, requested == nil, hasAttached, let current = followed else { return }
        let externals: [DailyAudioRoute] = [.bluetooth, .wired]
        let appeared = devices.subtracting(previous)
        if let external = externals.first(where: appeared.contains) {
            followed = external
        } else if previous.contains(current), !devices.contains(current) {
            followed = externals.first(where: devices.contains)
                ?? (devices.contains(.earpiece) ? .earpiece : .speaker)
        }
        if followed != current { refused = nil }
    }

    /// A connect is about to join, or a disconnect released the session.
    mutating func sessionDidReset() {
        session += 1
        applied = nil
        isApplying = false
        refused = nil
    }

    /// The join completed and Daily now reports `reported` as its preferred device.
    mutating func joinDidComplete(reported: DailyAudioRoute?) {
        refused = nil
        guard !isApplying else { return }
        applied = reported
    }

    /// The next change to apply, or `nil` if there is none or one is in flight.
    mutating func beginApplying() -> Application? {
        guard !isApplying, let wanted, wanted != applied, wanted != refused else { return nil }
        isApplying = true
        return Application(route: wanted, session: session)
    }

    mutating func applyDidSucceed(_ application: Application) {
        guard application.session == session else { return }
        isApplying = false
        applied = application.route
    }

    mutating func applyDidFail(_ application: Application) {
        guard application.session == session else { return }
        isApplying = false
        refused = application.route
    }
}
