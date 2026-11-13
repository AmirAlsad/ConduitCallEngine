//
//  CallMessage.swift
//  ConduitCallEngine
//
//  The host's own messages to and from its agent, carried by the call's transport
//  next to the engine's call-control signals: a message the host sends
//  (`CallMessage`, through `CallEngine.send(_:)`), and what the agent says back,
//  as `TransportEvent`s the engine passes to the host's delegate (an RTVI server
//  message, the agent's output text, the user's transcript). The payloads are JSON
//  `Data` and the engine's own structs, so no transport SDK type reaches the core.
//

import Foundation

/// A message from the host to its agent: an RTVI client message, sent with
/// `CallEngine.send(_:)` on the call in progress.
///
/// The bundled adapters carry it in the envelope of the call-control signals, with
/// `type` as `t` and `data` as `d`: `{"id": "<8 characters>", "label": "rtvi-ai",
/// "type": "client-message", "data": {"t": "<type>", "d": <data>}}`. A Pipecat bot
/// sees it as a client message of type `type` with `data` as its data.
public struct CallMessage: Equatable, Sendable {
    /// The message's name on the wire (`t`). The engine refuses the names it uses
    /// itself (`reservedTypes`) and an empty one.
    public let type: String
    /// The message's payload (`d`), as UTF-8 JSON: any JSON value, an object, an
    /// array, a string, a number, a boolean or null. nil sends no payload.
    public let data: Data?

    /// A message with no payload.
    public init(type: String) {
        self.type = type
        self.data = nil
    }

    /// A message whose payload is `data`, UTF-8 JSON. nil when `data` is not JSON.
    public init?(type: String, data: Data) {
        guard (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil else { return nil }
        self.type = type
        self.data = data
    }

    /// A message whose payload is `payload` encoded with `JSONEncoder`; throws what
    /// the encoder throws.
    public init(type: String, payload: some Encodable) throws {
        self.type = type
        self.data = try JSONEncoder().encode(payload)
    }

    /// The names the engine sends itself, which a host message may not use: the
    /// end-call signal (`end-call`) and every `CallSignal`'s raw value.
    public static var reservedTypes: Set<String> {
        Set(["end-call"] + CallSignal.allCases.map(\.rawValue))
    }

    /// Whether the engine and the bundled adapters refuse to send it: its type is
    /// reserved or empty.
    package var isRefused: Bool {
        type.isEmpty || Self.reservedTypes.contains(type)
    }
}

/// Text the agent produced, as the agent's RTVI `bot-output` message reports it: what
/// it said or is about to say, for captions. Pipecat sends one per aggregation (a
/// word or a sentence) of the agent's output.
public struct BotOutput: Equatable, Sendable {
    /// Where the agent is in speaking a segment: the RTVI `spoken_progress` fields.
    public struct SpokenProgress: Equatable, Sendable {
        /// The part of the segment spoken so far.
        public let accumulatedText: String
        /// The part of the segment not spoken yet.
        public let remainingText: String

        public init(accumulatedText: String, remainingText: String) {
            self.accumulatedText = accumulatedText
            self.remainingText = remainingText
        }
    }

    /// The text.
    public let text: String
    /// Whether the text is (or will be) spoken, rather than only written: RTVI's
    /// `will_be_spoken`, or `spoken` from an agent on RTVI 1.x. nil when the agent
    /// said neither.
    public let isSpoken: Bool?
    /// How the text was aggregated (`aggregated_by`): `"word"` or `"sentence"` from a
    /// Pipecat agent; an agent may send other values.
    public let aggregatedBy: String
    /// Where the segment's speech stands (`spoken_status`): `"new"`, `"in-progress"` or
    /// `"completed"` from a Pipecat agent on RTVI 2.x; nil when the agent did not say.
    public let spokenStatus: String?
    /// Word-by-word progress through the spoken segment (`spoken_progress`), when the
    /// agent reports it.
    public let spokenProgress: SpokenProgress?
    /// Ties together the messages about one spoken segment (`segment_id`), when the
    /// agent sends it.
    public let segmentID: Int?

    public init(
        text: String,
        isSpoken: Bool? = nil,
        aggregatedBy: String,
        spokenStatus: String? = nil,
        spokenProgress: SpokenProgress? = nil,
        segmentID: Int? = nil
    ) {
        self.text = text
        self.isSpoken = isSpoken
        self.aggregatedBy = aggregatedBy
        self.spokenStatus = spokenStatus
        self.spokenProgress = spokenProgress
        self.segmentID = segmentID
    }
}

/// What the agent's speech recognition heard the user say, as the agent's RTVI
/// `user-transcription` message reports it.
public struct UserTranscript: Equatable, Sendable {
    /// The text.
    public let text: String
    /// Whether the agent's recognizer considers it final; an interim transcript is
    /// replaced by later ones.
    public let isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

// MARK: - The RTVI shapes, for the bundled adapters

extension BotOutput {
    /// Decodes the `data` of an RTVI `bot-output` message (`text` and `aggregated_by`
    /// required); throws for any other shape.
    package init(rtviData data: Data) throws {
        let wire = try JSONDecoder().decode(BotOutputWire.self, from: data)
        self.init(
            text: wire.text,
            isSpoken: wire.willBeSpoken ?? wire.spoken,
            aggregatedBy: wire.aggregatedBy,
            spokenStatus: wire.spokenStatus,
            spokenProgress: wire.spokenProgress.map {
                SpokenProgress(accumulatedText: $0.accumulatedText, remainingText: $0.remainingText)
            },
            segmentID: wire.segmentID
        )
    }
}

extension UserTranscript {
    /// Decodes the `data` of an RTVI `user-transcription` message (`text` required,
    /// `final` false when absent); throws for any other shape.
    package init(rtviData data: Data) throws {
        let wire = try JSONDecoder().decode(UserTranscriptWire.self, from: data)
        self.init(text: wire.text, isFinal: wire.final ?? false)
    }
}

private struct BotOutputWire: Decodable {
    struct Progress: Decodable {
        let accumulatedText: String
        let remainingText: String

        enum CodingKeys: String, CodingKey {
            case accumulatedText = "accumulated_text"
            case remainingText = "remaining_text"
        }
    }

    let text: String
    let spoken: Bool?
    let willBeSpoken: Bool?
    let aggregatedBy: String
    let spokenStatus: String?
    let spokenProgress: Progress?
    let segmentID: Int?

    enum CodingKeys: String, CodingKey {
        case text
        case spoken
        case willBeSpoken = "will_be_spoken"
        case aggregatedBy = "aggregated_by"
        case spokenStatus = "spoken_status"
        case spokenProgress = "spoken_progress"
        case segmentID = "segment_id"
    }
}

private struct UserTranscriptWire: Decodable {
    let text: String
    let final: Bool?
}
