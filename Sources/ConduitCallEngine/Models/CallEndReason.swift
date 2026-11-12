//
//  CallEndReason.swift
//  ConduitCallEngine
//
//  Why a call ended, reported to CallKit so the system call log reflects it.
//  Mapped to `CXCallEndedReason` in the real provider.
//

import Foundation

package enum CallEndReason: Equatable, Sendable {
    case remoteEnded
    case failed
    case unanswered
}
