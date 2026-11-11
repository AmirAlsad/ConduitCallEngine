//
//  CallHandle.swift
//  ConduitCallEngine
//
//  The handle a call is placed against: the target's handle, or
//  `CallTarget.defaultHandle(for:)`. The real CallKit provider maps it to a
//  `CXHandle` of type `.emailAddress` — email type is deliberate, so Siri/CallKit
//  read the display name rather than the raw handle. Kept CallKit-agnostic so the
//  seam stays testable.
//

import Foundation

package struct CallHandle: Equatable, Sendable {
    package let value: String

    package init(value: String) {
        self.value = value
    }
}
