import XCTest
@testable import SessionManager

final class SessionStateTests: XCTestCase {
    func testConnectedStateReportsRadioNameAndConnection() {
        let state = SessionState.connected(radioName: "IC-705")

        XCTAssertTrue(state.isConnected)
        XCTAssertEqual(state.radioName, "IC-705")
        XCTAssertEqual(state.description, "connected(IC-705)")
    }

    func testDisconnectingTransitionIsAllowedFromOperationalStates() {
        XCTAssertTrue(SessionState.connected(radioName: "IC-705").canTransition(to: .disconnecting))
        XCTAssertTrue(SessionState.queryingStatus.canTransition(to: .disconnecting))
        XCTAssertTrue(SessionState.sendingCW.canTransition(to: .disconnecting))
    }

    func testDisconnectingMustEndInDisconnected() {
        XCTAssertTrue(SessionState.disconnecting.canTransition(to: .disconnected))
        XCTAssertFalse(SessionState.disconnecting.canTransition(to: .connected(radioName: "IC-705")))
    }
}
