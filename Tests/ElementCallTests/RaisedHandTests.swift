//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

// `@testable` for `MatrixRTCCall`'s internal initialiser.
@testable import ElementCallKit
import Foundation
import MatrixRtc
import Testing

/// The raised hand on our side of the core: requests go through, and a refusal reaches the caller
/// rather than being logged and swallowed, since the control has to show it (009 R22).
@Suite("Raised hand")
@MainActor
struct RaisedHandTests {
    @Test
    func raisingAndLoweringGoThroughToTheCore() async throws {
        let rtcCall = FakeRtcCall()
        let call = MatrixRTCCall(rtcCall: rtcCall)
        
        async let raised: Void = call.raiseHand()
        try await waitForPendingRequest(on: rtcCall)
        rtcCall.answer()
        try await raised
        
        async let lowered: Void = call.lowerHand()
        try await waitForPendingRequest(on: rtcCall)
        rtcCall.answer()
        try await lowered
        
        #expect(rtcCall.requests == [.raise, .lower])
    }
    
    @Test
    func aRefusalReachesTheCaller() async throws {
        let rtcCall = FakeRtcCall()
        let call = MatrixRTCCall(rtcCall: rtcCall)
        
        let raised = Task { try await call.raiseHand() }
        try await waitForPendingRequest(on: rtcCall)
        rtcCall.answer(failingWith: FakeRtcCall.RefusedError())
        
        await #expect(throws: MatrixRTCError.self) { try await raised.value }
    }
}

/// Until the fake holds a request. Bounded, so a request that never arrives fails rather than hangs.
@MainActor
func waitForPendingRequest(on rtcCall: FakeRtcCall) async throws {
    for _ in 0..<1000 where !rtcCall.hasPendingRequest {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(rtcCall.hasPendingRequest)
}
