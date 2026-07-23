// End-to-end reassembly tests: real UDP packets are sent to localhost and read back through the
// actual LiveViewReceiver socket code (not just its extracted logic), to genuinely exercise the
// frame-reassembly state machine ported from camera_session.py's run() loop.
import XCTest
@testable import YiM1Core
#if canImport(Darwin)
import Darwin
#endif

final class LiveViewReceiverTests: XCTestCase {
    private let testPort: UInt16 = 54329 // distinct from the real 54321 to avoid any conflicts

    private func send(_ bytes: [UInt8], to port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bytes.withUnsafeBufferPointer { bufPtr in
                    sendto(fd, bufPtr.baseAddress, bytes.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func packetHeader(frameIndex: UInt32, totalPackets: UInt32, packetIndex: UInt32) -> [UInt8] {
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        return be(frameIndex) + be(totalPackets) + be(packetIndex)
    }

    private func metadataHeaderBytes(json: String) -> [UInt8] {
        var bytes = Array(json.utf8)
        bytes.append(contentsOf: Array(repeating: 0, count: 2048 - bytes.count))
        return bytes
    }

    func testSinglePacketFrameReassembly() async throws {
        let receiver = LiveViewReceiver(port: testPort, keepAliveHost: nil)
        let stream = receiver.start()
        try await Task.sleep(nanoseconds: 200_000_000) // let the socket bind before we send

        let json = #"{"ISOSetting":"200","VideoFormat":"FHD_30"}"#
        let jpegMarker: [UInt8] = [0xFF, 0xD8, 0xFF, 0xD9] // fake but distinct payload tail
        let payload = metadataHeaderBytes(json: json) + jpegMarker
        let packet = packetHeader(frameIndex: 1, totalPackets: 1, packetIndex: 0) + payload
        send(packet, to: testPort)

        var received: LiveViewFrame?
        for await frame in stream {
            received = frame
            break
        }
        receiver.stop()

        let frame = try XCTUnwrap(received)
        XCTAssertEqual(frame.metadata?[.iso], "200")
        XCTAssertEqual(frame.metadata?.videoFormat, "FHD_30")
        XCTAssertEqual(Array(frame.jpegData), jpegMarker)
    }

    func testMultiPacketFrameReassembly() async throws {
        let receiver = LiveViewReceiver(port: testPort + 1, keepAliveHost: nil)
        let stream = receiver.start()
        try await Task.sleep(nanoseconds: 200_000_000)

        let json = #"{"ISOSetting":"800"}"#
        let headerBytes = metadataHeaderBytes(json: json) // exactly 2048 bytes
        let jpegPart1: [UInt8] = Array(repeating: 0xAA, count: 10)
        let jpegPart2: [UInt8] = Array(repeating: 0xBB, count: 10)

        // Packet 0 carries the full 2048-byte header + first JPEG chunk; packet 1 carries the
        // rest - mirrors how a real multi-packet frame splits the header/JPEG boundary
        // arbitrarily across UDP datagram boundaries.
        let packet0 = packetHeader(frameIndex: 5, totalPackets: 2, packetIndex: 0) + headerBytes + jpegPart1
        let packet1 = packetHeader(frameIndex: 5, totalPackets: 2, packetIndex: 1) + jpegPart2

        send(packet0, to: testPort + 1)
        send(packet1, to: testPort + 1)

        var received: LiveViewFrame?
        for await frame in stream {
            received = frame
            break
        }
        receiver.stop()

        let frame = try XCTUnwrap(received)
        XCTAssertEqual(frame.metadata?[.iso], "800")
        XCTAssertEqual(Array(frame.jpegData), jpegPart1 + jpegPart2)
    }

    /// Regression test for the on-device stutter/fps-drop bug (2026-07-11, worse while panning
    /// the camera): the OLD reassembly required packets to arrive in strict ascending order and
    /// discarded the whole frame the instant one was reordered - but UDP guarantees delivery, not
    /// order, so a merely-reordered (not lost) packet was wrongly treated identically to a real
    /// loss. Sends a 3-packet frame with packet 2 arriving BEFORE packet 1 and asserts the
    /// receiver still reassembles it correctly (in the right order) instead of dropping it.
    func testOutOfOrderPacketsWithinAFrameStillReassemble() async throws {
        let receiver = LiveViewReceiver(port: testPort + 4, keepAliveHost: nil)
        let stream = receiver.start()
        try await Task.sleep(nanoseconds: 200_000_000)

        let json = #"{"ISOSetting":"400"}"#
        let headerBytes = metadataHeaderBytes(json: json)
        let part1: [UInt8] = Array(repeating: 0x11, count: 8)
        let part2: [UInt8] = Array(repeating: 0x22, count: 8)

        let packet0 = packetHeader(frameIndex: 9, totalPackets: 3, packetIndex: 0) + headerBytes
        let packet2 = packetHeader(frameIndex: 9, totalPackets: 3, packetIndex: 2) + part2
        let packet1 = packetHeader(frameIndex: 9, totalPackets: 3, packetIndex: 1) + part1

        // Deliberately out of order: 0, then 2, then 1 - packet 1 arrives LAST even though it
        // belongs before packet 2 in the reassembled data.
        send(packet0, to: testPort + 4)
        send(packet2, to: testPort + 4)
        send(packet1, to: testPort + 4)

        var received: LiveViewFrame?
        for await frame in stream {
            received = frame
            break
        }
        receiver.stop()

        let frame = try XCTUnwrap(received, "a frame with only reordered (not missing) packets must still be reassembled")
        XCTAssertEqual(frame.metadata?[.iso], "400")
        XCTAssertEqual(Array(frame.jpegData), part1 + part2, "pieces must be reassembled in index order, not arrival order")

        let stats = receiver.statsSnapshot()
        XCTAssertEqual(stats.validFrameCount, 1)
        XCTAssertEqual(stats.droppedFrameCount, 0, "reordering alone must not count as a drop")
    }

    /// The two-frame reassembly window (2026-07-11, motivated by 599-net-drops on-device): a
    /// packet belonging to frame N routinely arrives AFTER frame N+1 has started (Wi-Fi
    /// MAC-layer retransmission delay) - an INTER-frame straggler. The single-frame window
    /// abandoned frame N the moment N+1's first packet showed up; with two frames in flight,
    /// the straggler still completes its frame.
    func testInterFrameStragglerStillCompletesPreviousFrame() async throws {
        let receiver = LiveViewReceiver(port: testPort + 6, keepAliveHost: nil)
        let stream = receiver.start()
        try await Task.sleep(nanoseconds: 200_000_000)

        let port = testPort + 6
        let f1Header = metadataHeaderBytes(json: #"{"ISOSetting":"250"}"#)
        let f1Tail: [UInt8] = [0xA1, 0xA2]
        let f2Header = metadataHeaderBytes(json: #"{"ISOSetting":"500"}"#)
        let f2Tail: [UInt8] = [0xB1, 0xB2]

        // Frame 1 = 3 packets, sent MISSING packet 1. Frame 2 (2 packets) starts arriving.
        // Then frame 1's straggler (packet 1) shows up - after the next frame began, exactly
        // like a delayed Wi-Fi retransmission. Then frame 2 finishes.
        send(packetHeader(frameIndex: 1, totalPackets: 3, packetIndex: 0) + f1Header, to: port)
        send(packetHeader(frameIndex: 1, totalPackets: 3, packetIndex: 2) + f1Tail, to: port)
        send(packetHeader(frameIndex: 2, totalPackets: 2, packetIndex: 0) + f2Header, to: port)
        send(packetHeader(frameIndex: 1, totalPackets: 3, packetIndex: 1) + [0xAA], to: port) // straggler
        send(packetHeader(frameIndex: 2, totalPackets: 2, packetIndex: 1) + f2Tail, to: port)

        // Consume until frame 2 arrives (frame 1 may or may not still be in the buffer slot
        // ahead of it depending on timing - bufferingNewest(1) only keeps the latest).
        var lastISO: String?
        for await frame in stream {
            lastISO = frame.metadata?[.iso]
            if lastISO == "500" { break }
        }
        receiver.stop()

        XCTAssertEqual(lastISO, "500")
        let stats = receiver.statsSnapshot()
        XCTAssertEqual(stats.validFrameCount, 2, "the straggler must have completed frame 1 - both frames count as valid")
        XCTAssertEqual(stats.droppedFrameCount, 0, "an inter-frame straggler is late, not lost - nothing should count as dropped")
    }

    /// Regression test distinguishing the two loss layers found during the 2026-07-11 fps
    /// regression: a frame can be perfectly reassembled here (network layer fine) and still
    /// never reach the consumer, because `.bufferingNewest(1)` discards it first. Sends 5
    /// complete single-packet frames back-to-back with no one reading the stream in between,
    /// then consumes once - all 5 must be counted as validly reassembled, but several must show
    /// up as buffer-dropped (discarded before the consumer got to them), not just vanish
    /// unaccounted for.
    func testBufferDroppedCountsFramesDiscardedByConsumerLag() async throws {
        let receiver = LiveViewReceiver(port: testPort + 5, keepAliveHost: nil)
        let stream = receiver.start()
        try await Task.sleep(nanoseconds: 200_000_000)

        for i in 1...5 {
            let payload = metadataHeaderBytes(json: #"{"ISOSetting":"100"}"#) + [UInt8(i)]
            let packet = packetHeader(frameIndex: UInt32(i), totalPackets: 1, packetIndex: 0) + payload
            send(packet, to: testPort + 5)
        }
        try await Task.sleep(nanoseconds: 300_000_000) // let the receiver thread process & yield all 5 before we ever read

        var received: LiveViewFrame?
        for await frame in stream {
            received = frame
            break
        }
        receiver.stop()

        XCTAssertNotNil(received, "the stream must still deliver the newest frame despite the pile-up")
        let stats = receiver.statsSnapshot()
        XCTAssertEqual(stats.validFrameCount, 5, "all 5 were fully and correctly reassembled at the network layer")
        XCTAssertGreaterThan(stats.bufferDroppedFrameCount, 0,
                              "bufferingNewest(1) must have discarded some of the 5 before the consumer read even one - that loss needs to be visible, not silent")
    }

    func testDroppedPacketInvalidatesFrameButNextFrameRecovers() async throws {
        let receiver = LiveViewReceiver(port: testPort + 2, keepAliveHost: nil)
        let stream = receiver.start()
        try await Task.sleep(nanoseconds: 200_000_000)

        let headerBytes = metadataHeaderBytes(json: #"{"ISOSetting":"100"}"#)

        // Frame 1: send packet 0 of 2, then SKIP packet 1 (simulates a real drop) - this frame
        // must never be yielded.
        let badFrame0 = packetHeader(frameIndex: 1, totalPackets: 2, packetIndex: 0) + headerBytes
        send(badFrame0, to: testPort + 2)

        // Frame 2: a clean single-packet frame - the receiver must recover and yield this one,
        // proving a dropped packet doesn't wedge the whole reassembly state machine.
        let goodPayload = metadataHeaderBytes(json: #"{"ISOSetting":"3200"}"#) + [0x01, 0x02]
        let goodFrame = packetHeader(frameIndex: 2, totalPackets: 1, packetIndex: 0) + goodPayload
        send(goodFrame, to: testPort + 2)

        var received: LiveViewFrame?
        for await frame in stream {
            received = frame
            break
        }
        receiver.stop()

        let frame = try XCTUnwrap(received)
        XCTAssertEqual(frame.metadata?[.iso], "3200", "should have recovered on the next clean frame, not gotten stuck on the dropped one")

        // Drives the fps/dropped-frame debug overlay (2026-07-11) - one valid frame delivered,
        // one dropped from the skipped packet.
        let stats = receiver.statsSnapshot()
        XCTAssertEqual(stats.validFrameCount, 1)
        XCTAssertEqual(stats.droppedFrameCount, 1)
    }

    /// Regression test for a real on-device bug: after disconnect -> reconnect to the same
    /// camera Wi-Fi, live view never resumed. Root cause was runLoop() occupying a *serial*
    /// DispatchQueue for its entire lifetime (a `while` loop, not a returning block), so stop()'s
    /// queued block - and a second start()'s runLoop - could never actually run, both stuck
    /// behind the still-executing first runLoop forever. This drives the same receiver instance
    /// through stop() then start() again and asserts the second connection's frames actually
    /// arrive - would hang (and time out) against the old DispatchQueue-based implementation.
    func testReceiverWorksAfterStopThenRestart() async throws {
        let port = testPort + 3
        let receiver = LiveViewReceiver(port: port, keepAliveHost: nil)

        let firstStream = receiver.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        send(packetHeader(frameIndex: 1, totalPackets: 1, packetIndex: 0) + metadataHeaderBytes(json: #"{"ISOSetting":"100"}"#) + [0xAA], to: port)
        var firstFrame: LiveViewFrame?
        for await frame in firstStream {
            firstFrame = frame
            break
        }
        XCTAssertEqual(firstFrame?.metadata?[.iso], "100")

        receiver.stop()
        try await Task.sleep(nanoseconds: 200_000_000) // let the old runLoop actually unwind

        let secondStream = receiver.start()
        try await Task.sleep(nanoseconds: 200_000_000) // let the new socket rebind to the same port
        send(packetHeader(frameIndex: 1, totalPackets: 1, packetIndex: 0) + metadataHeaderBytes(json: #"{"ISOSetting":"400"}"#) + [0xBB], to: port)
        var secondFrame: LiveViewFrame?
        for await frame in secondStream {
            secondFrame = frame
            break
        }
        receiver.stop()

        let frame = try XCTUnwrap(secondFrame, "reconnecting after stop() should receive frames again, not hang forever")
        XCTAssertEqual(frame.metadata?[.iso], "400")
    }
}
