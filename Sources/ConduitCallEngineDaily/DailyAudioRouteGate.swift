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
//  A join that starts before the first attach (a ring's, or an outgoing call whose
//  credentials came before CallKit's activation) would otherwise let Daily's default
//  decide: by the attach the session is already on the loudspeaker. Such a join takes
//  a provisional route from what the session reports just before it: a connected
//  Bluetooth or wired device, or else the earpiece; a loudspeaker reading then is not
//  anyone's choice. It is given to Daily as its preferred device only, which Daily
//  keeps without touching the session until it starts managing it at the join, and
//  the join's microphone input names it; Daily configures the session at the join
//  either way, so this adds no audio activity, only which route it configures. The
//  first attach reads the route again: a headset is followed, the earpiece is kept,
//  and a loudspeaker reading is again not a choice and gives the earpiece.
//
//  The wanted route is given to every Daily session before its join, so a reconnect
//  or a session taken over keeps it. A join made while the call rings is given only
//  its provisional route before the attach: the engine's request waits for the first
//  attach, and nothing is asked of Daily between that join and the first attach.
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

    /// The provisional route of a join that starts before the first attach, from
    /// what the session reports then: the output, or else a Bluetooth or wired input
    /// that is available, or else the earpiece. A loudspeaker output is no choice
    /// before CallKit's activation and gives the earpiece too. Nil (Daily's own
    /// choice) for no output, or for a car, AirPlay or USB route Daily cannot be
    /// asked for.
    static func beforeActivation(outputPort: AVAudioSession.Port?, availableInputs: [AVAudioSession.Port]) -> DailyAudioRoute? {
        guard let outputPort else { return nil }
        let output = DailyAudioRoute(outputPort: outputPort)
        switch output {
        case .bluetooth, .wired: return output
        case nil: return nil
        case .earpiece, .speaker: break
        }
        guard !availableInputs.contains(where: [.carAudio, .usbAudio].contains) else { return nil }
        let headsets = availableInputs.compactMap(DailyAudioRoute.init(outputPort:))
        return [DailyAudioRoute.bluetooth, .wired].first(where: headsets.contains) ?? .earpiece
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
        /// Before the session's join and the first attach: give Daily the preferred
        /// device only, which the join's microphone input names, so nothing changes
        /// Daily's inputs before CallKit's activation.
        let isForTheJoin: Bool
    }

    /// What the engine asked for (`setAudioDevice`); wins over the followed route.
    private(set) var requested: DailyAudioRoute?
    /// The route the adapter keeps the call on while the engine has asked for none.
    private(set) var followed: DailyAudioRoute?
    private(set) var hasAttached = false
    /// A join while the call rings: only its provisional route is given to Daily
    /// before the first attach, and only before the join.
    private(set) var holdsBackUntilFirstAttach = false
    /// A join started before the first attach, so the route read then may be Daily's.
    private(set) var joinedBeforeFirstAttach = false
    /// `followed` was chosen at a join before the first attach.
    private(set) var isFollowedRouteProvisional = false
    /// The current session's join completed, so Daily manages the audio session.
    private(set) var isSessionJoined = false
    /// The routes in Daily's last non-empty device list; empty until one arrives.
    private(set) var knownDevices: Set<DailyAudioRoute> = []
    /// What Daily has been given in this session; `nil` if nothing yet.
    private(set) var applied: DailyAudioRoute?
    private(set) var isApplying = false
    private(set) var session = 0
    private var refused: DailyAudioRoute?

    /// The route Daily should prefer now; `nil` leaves Daily's own choice.
    var wanted: DailyAudioRoute? { honoredRequest ?? followed }

    /// The engine's request, unless a ring's join holds it until the first attach.
    private var honoredRequest: DailyAudioRoute? {
        hasAttached || !holdsBackUntilFirstAttach ? requested : nil
    }

    /// Why `wanted` is what it is, for logs.
    var wantedReason: String {
        if honoredRequest != nil { return "engine request" }
        return isFollowedRouteProvisional ? "the call's route before activation" : "the call's route"
    }

    /// A join while the call rings: give Daily only the provisional route, before
    /// the join, until the first attach. Does nothing once the gate has been attached.
    mutating func holdUntilFirstAttach() {
        guard !hasAttached else { return }
        holdsBackUntilFirstAttach = true
    }

    /// A join is about to start. Before the first attach, the first such join takes
    /// `provisionalRoute` (see `DailyAudioRoute.beforeActivation`) as the route to
    /// keep until the attach, and `devices` as the baseline if none came before.
    mutating func joinWillStart(provisionalRoute: DailyAudioRoute?, devices: Set<DailyAudioRoute>) {
        isSessionJoined = false
        guard !hasAttached, !joinedBeforeFirstAttach else { return }
        joinedBeforeFirstAttach = true
        if knownDevices.isEmpty { knownDevices = devices }
        guard let provisionalRoute else { return }
        followed = provisionalRoute
        isFollowedRouteProvisional = true
    }

    /// CallKit activated the session (or a hold ended). The first attach takes
    /// `activeRoute`, the route the session is on now, as the route to keep, and
    /// `devices` as the baseline if no device list came before. After a join that
    /// started before it, the session may be on Daily's own route: a loudspeaker
    /// reading is then no choice and gives the earpiece, and an earpiece reading
    /// keeps a headset the provisional route followed. Returns whether it was the
    /// first attach.
    @discardableResult
    mutating func attach(activeRoute: DailyAudioRoute?, devices: Set<DailyAudioRoute>) -> Bool {
        refused = nil
        guard !hasAttached else { return false }
        hasAttached = true
        if knownDevices.isEmpty { knownDevices = devices }
        followed = joinedBeforeFirstAttach ? routeAfterAnEarlyJoin(reading: activeRoute) : activeRoute
        isFollowedRouteProvisional = false
        return true
    }

    private func routeAfterAnEarlyJoin(reading: DailyAudioRoute?) -> DailyAudioRoute? {
        switch reading {
        case .bluetooth, .wired, nil:
            return reading
        case .earpiece, .speaker:
            if let followed, [.bluetooth, .wired].contains(followed), knownDevices.contains(followed) {
                return followed
            }
            return .earpiece
        }
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
        guard !previous.isEmpty, requested == nil, hasAttached || isFollowedRouteProvisional,
              let current = followed else { return }
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
        isSessionJoined = false
    }

    /// The join completed and Daily now reports `reported` as its preferred device.
    mutating func joinDidComplete(reported: DailyAudioRoute?) {
        refused = nil
        isSessionJoined = true
        guard !isApplying else { return }
        applied = reported
    }

    /// The adapter changed Daily's preferred device itself (a recovery after an
    /// interruption), and Daily now reports `reported`: that counts as applied,
    /// unless an application is still in flight, so a wanted route Daily does not
    /// have is asked for again.
    mutating func preferenceChangedOutsideTheGate(reported: DailyAudioRoute?) {
        refused = nil
        guard !isApplying else { return }
        applied = reported
    }

    /// The next change to apply, or `nil` if there is none or one is in flight. A
    /// ring's join asks nothing of Daily, which manages the session from the join,
    /// between the join and the first attach.
    mutating func beginApplying() -> Application? {
        guard !isApplying, let wanted, wanted != applied, wanted != refused else { return nil }
        guard hasAttached || !holdsBackUntilFirstAttach || !isSessionJoined else { return nil }
        isApplying = true
        return Application(route: wanted, session: session, isForTheJoin: !hasAttached && !isSessionJoined)
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
