//
//  LiveKitConnectFailureTests.swift
//  ConduitCallEngineLiveKitTests
//
//  Which LiveKit connect errors count as rejected credentials. A false positive ends
//  a reconnecting call as a bad token, so only the validation endpoint's 401 or 403
//  and LiveKit's insufficient-permissions error count.
//

import Testing
@testable import ConduitCallEngineLiveKit

struct LiveKitConnectFailureTests {
    @Test(arguments: [
        "HTTP 401: invalid token: token is expired (exp)",
        "HTTP 403: no permissions to access the room",
    ])
    func theValidationEndpointRejectingTheTokenIsRejectedCredentials(message: String) {
        #expect(LiveKitConnectFailure.isRejectedCredentials(.validation(message: message)))
    }

    @Test func insufficientPermissionsAreRejectedCredentials() {
        #expect(LiveKitConnectFailure.isRejectedCredentials(.insufficientPermissions))
    }

    @Test(arguments: [
        "HTTP 400: missing room",
        "HTTP 410: gone",
        "Region settings error: HTTP 401: unauthorized",
        "validation failed: HTTP 401:",
        "token",
    ])
    func otherValidationErrorsAreNot(message: String) {
        #expect(!LiveKitConnectFailure.isRejectedCredentials(.validation(message: message)))
    }

    @Test func aValidationErrorWithoutAMessageIsNot() {
        #expect(!LiveKitConnectFailure.isRejectedCredentials(.validation(message: nil)))
    }

    /// The old rule searched the whole error description, which includes nested
    /// errors' user info such as the failing URL; none of that is read now.
    @Test func aNetworkErrorIsNotRejectedCredentialsWhateverItsDescriptionSays() {
        #expect(!LiveKitConnectFailure.isRejectedCredentials(.other))
    }
}
