import XCTest
@testable import PoloRig

final class CIVControllerTests: XCTestCase {

    private var controller: CIVController!

    override func setUp() {
        super.setUp()
        controller = CIVController()
    }

    override func tearDown() {
        controller = nil
        super.tearDown()
    }

    private func drainMainQueue() {
        let exp = expectation(description: "main queue drain")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - Frequency Response

    func testHandleCIVData_frequencyResponse() {
        let data = Data([0xFE, 0xFE, 0xE0, 0xA4, 0x03,
                         0x00, 0x00, 0x06, 0x14, 0x00, 0xFD])
        controller.handleCIVData(data)
        drainMainQueue()
        XCTAssertEqual(controller.frequencyHz, 14_060_000)
    }

    // MARK: - Mode Response

    func testHandleCIVData_modeResponse_CW() {
        let data = Data([0xFE, 0xFE, 0xE0, 0xA4, 0x04, 0x03, 0x01, 0xFD])
        controller.handleCIVData(data)
        drainMainQueue()
        XCTAssertEqual(controller.operatingMode, .cw)
    }

    func testHandleCIVData_modeResponse_USB() {
        let data = Data([0xFE, 0xFE, 0xE0, 0xA4, 0x04, 0x01, 0x01, 0xFD])
        controller.handleCIVData(data)
        drainMainQueue()
        XCTAssertEqual(controller.operatingMode, .usb)
    }

    // MARK: - Frequency Echo (VFO Change)

    func testHandleCIVData_frequencyEcho() {
        let data = Data([0xFE, 0xFE, 0xE0, 0xA4, 0x05,
                         0x00, 0x00, 0x03, 0x07, 0x00, 0xFD])
        controller.handleCIVData(data)
        drainMainQueue()
        XCTAssertEqual(controller.frequencyHz, 7_030_000)
    }

    // MARK: - Error Cases

    func testHandleCIVData_tooShort() {
        let data = Data([0xFE, 0xFE, 0xE0, 0xA4, 0x03])
        controller.handleCIVData(data)
        XCTAssertEqual(controller.frequencyHz, 0)
    }

    func testHandleCIVData_missingPreamble() {
        let data = Data([0x00, 0x00, 0xE0, 0xA4, 0x03,
                         0x00, 0x00, 0x06, 0x14, 0x00, 0xFD])
        controller.handleCIVData(data)
        XCTAssertEqual(controller.frequencyHz, 0)
    }

    func testHandleCIVData_missingTerminator() {
        let data = Data([0xFE, 0xFE, 0xE0, 0xA4, 0x03,
                         0x00, 0x00, 0x06, 0x14, 0x00, 0x00])
        controller.handleCIVData(data)
        XCTAssertEqual(controller.frequencyHz, 0)
    }

    func testHandleCIVData_unknownCommand() {
        let data = Data([0xFE, 0xFE, 0xE0, 0xA4, 0x99, 0x00, 0xFD])
        controller.handleCIVData(data)
        XCTAssertEqual(controller.frequencyHz, 0)
        XCTAssertNil(controller.operatingMode)
    }

    func testHandleCIVData_shortPayload() {
        let data = Data([0xFE, 0xFE, 0xE0, 0xA4, 0x03, 0x00, 0x00, 0xFD])
        controller.handleCIVData(data)
        XCTAssertEqual(controller.frequencyHz, 0)
    }

    func testHandleCIVData_modeResponse_unknownMode() {
        let data = Data([0xFE, 0xFE, 0xE0, 0xA4, 0x04, 0xFF, 0x01, 0xFD])
        controller.handleCIVData(data)
        drainMainQueue()
        XCTAssertNil(controller.operatingMode)
    }

    // MARK: - CW Speed Response

    func testHandleCIVData_cwSpeedResponse() {
        let data = Data([0xFE, 0xFE, 0xE0, 0xA4, 0x14, 0x0C, 0x01, 0x28, 0xFD])
        controller.handleCIVData(data)
        drainMainQueue()
        XCTAssertEqual(controller.cwSpeed, 27)
    }

    func testHandleCIVData_cwSpeedResponse_min() {
        let data = Data([0xFE, 0xFE, 0xE0, 0xA4, 0x14, 0x0C, 0x00, 0x00, 0xFD])
        controller.handleCIVData(data)
        drainMainQueue()
        XCTAssertEqual(controller.cwSpeed, 6)
    }

    func testHandleCIVData_cwSpeedResponse_max() {
        let data = Data([0xFE, 0xFE, 0xE0, 0xA4, 0x14, 0x0C, 0x02, 0x55, 0xFD])
        controller.handleCIVData(data)
        drainMainQueue()
        XCTAssertEqual(controller.cwSpeed, 48)
    }
}
