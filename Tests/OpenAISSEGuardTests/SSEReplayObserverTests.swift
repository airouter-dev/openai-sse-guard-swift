import Foundation
import XCTest
@testable import OpenAISSEGuard

final class SSEReplayObserverTests: XCTestCase {
    func testSplitUTF8ChatChunksAndDoneMarker() {
        var first = Array("data: {\"choices\":[{\"delta\":{\"content\":\"caf".utf8)
        first.append(0xC3)

        var second: [UInt8] = [0xA9]
        second.append(contentsOf: Array("\"}}]}\n\n".utf8))

        var observer = SSEReplayObserver()
        observer.push(Data(first))
        observer.push(Data(second))
        observer.push(Data("data: [DONE]\n\n".utf8))
        let snapshot = observer.finish()

        XCTAssertEqual(snapshot.protocolHint, .chatCompletions)
        XCTAssertEqual(snapshot.termination, .done)
        XCTAssertTrue(snapshot.hasOutput)
        XCTAssertTrue(snapshot.sawTerminalEvent)
        XCTAssertEqual(snapshot.eventCount, 2)
        XCTAssertEqual(snapshot.malformedEventCount, 0)
    }

    func testResponsesCompletedWithCRLFFraming() {
        let snapshot = SSEReplayObserver.observe([
            Data("event: response.output_text.delta\r\ndata: {\"delta\":\"hello\"}\r\n\r\n".utf8),
            Data("event: response.completed\r\ndata: {}\r\n\r\n".utf8)
        ])

        XCTAssertEqual(snapshot.protocolHint, .responses)
        XCTAssertEqual(snapshot.termination, .done)
        XCTAssertEqual(snapshot.lastEventType, "response.completed")
        XCTAssertTrue(snapshot.hasOutput)
        XCTAssertEqual(snapshot.eventCount, 2)
    }

    func testErrorEventKeepsOnlyBoundedErrorIdentifier() {
        let snapshot = SSEReplayObserver.observe([
            Data("event: error\ndata: {\"error\":{\"code\":\"rate_limit_exceeded\",\"message\":\"do not retain this prose\"}}\n\n".utf8)
        ])

        XCTAssertEqual(snapshot.termination, .error)
        XCTAssertEqual(snapshot.errorCode, "rate_limit_exceeded")
        XCTAssertTrue(snapshot.hasOutput)
        XCTAssertNil(snapshot.lastEventType?.first(where: { $0 == "{" }))
    }

    func testPartialEventAtEOFIsConservativeOutputEvidence() {
        var observer = SSEReplayObserver()
        observer.push(Data("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}".utf8))
        let snapshot = observer.finish()

        XCTAssertEqual(snapshot.termination, .unexpectedEOF)
        XCTAssertTrue(snapshot.hasOutput)
        XCTAssertFalse(snapshot.sawTerminalEvent)
    }

    func testFrameLimitFailsClosed() {
        let snapshot = SSEReplayObserver.observe(
            [Data(("data: " + String(repeating: "x", count: 300) + "\n\n").utf8)],
            options: SSEReplayOptions(maxFrameBytes: 16)
        )

        XCTAssertEqual(snapshot.termination, .error)
        XCTAssertEqual(snapshot.malformedEventCount, 1)
    }

    func testEventLimitFailsClosed() {
        let snapshot = SSEReplayObserver.observe(
            [Data("data: first\n\n".utf8), Data("data: second\n\n".utf8)],
            options: SSEReplayOptions(maxEvents: 1)
        )

        XCTAssertEqual(snapshot.termination, .error)
        XCTAssertEqual(snapshot.eventCount, 1)
        XCTAssertEqual(snapshot.malformedEventCount, 1)
    }

    func testInvalidUTF8FailsAfterACompleteEventArrives() {
        var bytes = Array("data: ".utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: [10, 10])

        let snapshot = SSEReplayObserver.observe([Data(bytes)])

        XCTAssertEqual(snapshot.termination, .error)
        XCTAssertEqual(snapshot.malformedEventCount, 1)
    }

    func testCROnlyBoundariesAndIgnoredFields() {
        let snapshot = SSEReplayObserver.observe([
            Data(": keep-alive\rid: 42\revent: response.incomplete\rdata: {\"reason\":\"max_output_tokens\"}\r\r".utf8)
        ])

        XCTAssertEqual(snapshot.protocolHint, .responses)
        XCTAssertEqual(snapshot.termination, .incomplete)
        XCTAssertEqual(snapshot.lastEventType, "response.incomplete")
        XCTAssertTrue(snapshot.hasOutput)
    }

    func testOptionsClampUnsafeValues() {
        let minimum = SSEReplayOptions(maxFrameBytes: -1, maxEvents: 0)
        XCTAssertEqual(minimum.maxFrameBytes, 256)
        XCTAssertEqual(minimum.maxEvents, 1)

        let maximum = SSEReplayOptions(maxFrameBytes: 99_999_999, maxEvents: 99_999_999)
        XCTAssertEqual(maximum.maxFrameBytes, 4 * 1024 * 1024)
        XCTAssertEqual(maximum.maxEvents, 1_000_000)
    }

    func testFinishIsIdempotentAfterDone() {
        var observer = SSEReplayObserver()
        observer.push(Data("data: [DONE]\n\n".utf8))

        let first = observer.finish()
        let second = observer.finish()

        XCTAssertEqual(first, second)
    }

    func testUnknownDataBearingEventIsOutputEvidence() {
        let snapshot = SSEReplayObserver.observe([
            Data("event: vendor.delta\ndata: {\"chunk\":\"opaque\"}\n\n".utf8)
        ])

        XCTAssertEqual(snapshot.protocolHint, .unknown)
        XCTAssertEqual(snapshot.termination, .unexpectedEOF)
        XCTAssertTrue(snapshot.hasOutput)
    }
}
