//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

// `@testable` for `MatrixRTCCall`'s internal initialiser and the controller's `setPreviewState`.
@testable import ElementCallHost
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

/// The controller between a tap and the homeserver's answer: one request at a time, and the
/// control never shows the tap (009 R5, R22).
@Suite("Raised hand control")
@MainActor
struct RaisedHandControlTests {
    private func makeController() -> (ElementCallController, FakeRtcCall) {
        let rtcCall = FakeRtcCall()
        let controller = ElementCallController.fake(connection: .connected)
        controller.setPreviewState(callData: .init(isAudioCall: false, isStartingCall: true),
                                   room: ElementCallFakeRoom(),
                                   connection: .connected,
                                   rtcCall: MatrixRTCCall(rtcCall: rtcCall))
        return (controller, rtcCall)
    }
    
    @Test
    func aRequestIsPendingUntilTheHomeserverAnswers() async throws {
        let (controller, rtcCall) = makeController()
        
        controller.setHandRaised(true)
        #expect(controller.isHandPending)
        try await waitForPendingRequest(on: rtcCall)
        rtcCall.answer()
        
        try await waitUntilSettled(controller)
        #expect(controller.errorMessage == nil)
        #expect(rtcCall.requests == [.raise])
    }
    
    /// A second tap while the first is in flight would send twice, and the order the two land in
    /// is the homeserver's to pick.
    @Test
    func aTapWhilePendingIsIgnored() async throws {
        let (controller, rtcCall) = makeController()
        
        controller.setHandRaised(true)
        try await waitForPendingRequest(on: rtcCall)
        controller.setHandRaised(false)
        rtcCall.answer()
        try await waitUntilSettled(controller)
        
        #expect(rtcCall.requests == [.raise])
    }
    
    @Test
    func aRefusalIsToldAndClearsThePendingState() async throws {
        let (controller, rtcCall) = makeController()
        
        controller.setHandRaised(false)
        try await waitForPendingRequest(on: rtcCall)
        rtcCall.answer(failingWith: FakeRtcCall.RefusedError())
        
        try await waitUntilSettled(controller)
        #expect(controller.errorMessage == "Your hand could not be lowered.")
        #expect(rtcCall.requests == [.lower])
    }
    
    @Test
    func nothingIsSentBeforeTheJoin() {
        let controller = ElementCallController.fake(connection: .joining)
        
        controller.setHandRaised(true)
        
        #expect(!controller.isHandPending)
    }
    
    private func waitUntilSettled(_ controller: ElementCallController) async throws {
        for _ in 0..<1000 where controller.isHandPending {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(!controller.isHandPending)
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
