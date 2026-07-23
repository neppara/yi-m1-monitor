// UDP live-view stream receiver - port of the reassembly loop in
// yi-m1-remote-control/app/camera_session.py's run().
//
// Frame format (each UDP datagram): bytes [0:4] = frame index (big-endian UInt32),
// [4:8] = total packet count for this frame, [8:12] = this packet's index within the frame,
// [12:] = payload chunk. When a frame's packets are fully and contiguously received, the first
// 2048 bytes of the reassembled buffer are a null-padded JSON metadata header (see
// CameraMetadata.swift) and the rest is JPEG data.
//
// Implemented with a raw BSD UDP socket (bind to 0.0.0.0:54321, recv with a timeout so the loop
// can be cancelled) rather than Network.framework's NWListener, to mirror the reference
// implementation's exact semantics (bind + blocking recv-with-timeout) as closely as possible.
//
// runLoop() runs on its own dedicated Thread, not a DispatchQueue: it occupies its execution
// context for the receiver's entire lifetime (a `while` loop, not a quick block that returns),
// and a *serial* DispatchQueue can never run a second block (like stop()'s) until the first one
// returns - i.e. stop() would be queued forever behind a still-running runLoop and could never
// actually take effect. `isRunning`/`socketFD` are shared between that thread and whichever
// thread calls stop(), guarded by `lock`.
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct LiveViewFrame: Sendable {
    public let metadata: CameraMetadata?
    public let jpegData: Data
}

/// Reads a big-endian UInt32 from `data` at the given byte offset (relative to `data`'s own
/// startIndex, so this works whether `data` is a fresh Data or a slice with a non-zero
/// startIndex). Deliberately avoids raw unaligned pointer loads.
private func bigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
    let base = data.startIndex + offset
    let b0 = UInt32(data[base])
    let b1 = UInt32(data[base + 1])
    let b2 = UInt32(data[base + 2])
    let b3 = UInt32(data[base + 3])
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

/// Cumulative counts for the live-view fps/dropped-frame debug overlay (approved 2026-07-09
/// backlog item, added 2026-07-11) - lets a slow feed away from home (crowded 2.4GHz RF vs a
/// genuine app-side problem) actually be diagnosed instead of just eyeballed.
///
/// `droppedFrameCount` and `bufferDroppedFrameCount` are deliberately separate - they indict
/// different layers, and conflating them was exactly what made the 2026-07-11 regression
/// confusing to diagnose from the numbers alone:
/// - `droppedFrameCount`: a frame's UDP packets never fully arrived (real network loss) -
///   this thread's problem, upstream of everything else.
/// - `bufferDroppedFrameCount`: the frame WAS fully and correctly reassembled here, but the
///   `AsyncStream`'s `.bufferingNewest(1)` policy discarded it before the consumer (MainActor)
///   ever saw it, because the consumer hadn't finished processing the previous one yet - this
///   is downstream congestion, not a networking problem, and no amount of packet-reassembly
///   improvement can fix it.
public struct LiveViewStats: Sendable, Equatable {
    public let validFrameCount: Int
    public let droppedFrameCount: Int
    public let bufferDroppedFrameCount: Int
    /// Frames whose FIRST packet was seen - started+completed rates together tell the camera's
    /// actual send rate vs what survives reassembly.
    public let framesStartedCount: Int
    /// Forensics for dropped frames: how many packets they were missing in total vs how many
    /// they expected in total. Missing-few-of-many = tail loss (e.g. an AP buffer overflowing in
    /// bursts); missing-most = the radio was away for whole stretches (e.g. Wi-Fi power-save
    /// duty-cycling). Distinguishing those two is the point of collecting this.
    public let droppedFramesMissingPackets: Int
    public let droppedFramesExpectedPackets: Int
    /// The RECEIVE buffer size the kernel actually granted (getsockopt readback after our 1MB
    /// setsockopt request) - 0 until the socket is up. If the OS clamped it small, kernel-level
    /// datagram discard under burst is back on the suspect list.
    public let socketReceiveBufferBytes: Int
    /// Direct radio-away detector: the LONGEST gap between two consecutively received datagrams
    /// since the previous statsSnapshot() call (reset on each snapshot - it's a per-interval
    /// peak, unlike the cumulative counters above). While the camera streams (~1000 packets/s),
    /// inter-packet gaps should be ~1ms; a gap of 50-300ms means the phone's radio was away
    /// (power-save doze, channel scan) for that long - packets sent during it are what die.
    public let maxRecvGapMs: Int
    /// Cumulative count of inter-packet gaps exceeding 50ms - how OFTEN the radio goes away,
    /// complementing maxRecvGapMs's how LONG.
    public let recvGapsOver50msCount: Int
}

public final class LiveViewReceiver: @unchecked Sendable {
    private let port: UInt16
    /// When set, a tiny datagram is sent to this host every `keepAliveInterval` from the receive
    /// loop. Purpose: OUTBOUND traffic forces the phone's Wi-Fi radio to stay awake. iOS
    /// aggressively power-saves Wi-Fi between AP beacons when traffic looks idle/inbound-only,
    /// making the AP (the camera, with its tiny embedded buffer) queue packets - and at ~1MB/s
    /// of live view, overflow and drop them before they're ever transmitted. This is the
    /// leading hypothesis for the massive "net" (never-arrived) frame loss measured on-device
    /// 2026-07-11 (1200+ net drops with buf≈0 at close range, unaffected by disabling
    /// cellular data). The content/port don't matter - only the radio activity does.
    private let keepAliveHost: String?
    /// 100ms - matched to the typical Wi-Fi AP beacon interval. The first attempt (250ms) still
    /// left measurable radio-away windows on-device (field data 2026-07-11 evening: "in" fps
    /// oscillating 8.7-30.2 while the camera sends a steady ~30, dropped frames missing ~20% of
    /// their packets in bursts - whole frames vanishing trace-free plus burst-damaged edges is
    /// exactly the radio-away signature); a keep-alive slower than the beacon cadence leaves the
    /// radio room to doze between our transmissions.
    private let keepAliveInterval: TimeInterval = 0.1

    private let lock = NSLock()
    private var socketFD: Int32 = -1
    private var isRunning = false
    private var validFrameCount = 0
    private var droppedFrameCount = 0
    private var bufferDroppedFrameCount = 0
    private var framesStartedCount = 0
    private var droppedFramesMissingPackets = 0
    private var droppedFramesExpectedPackets = 0
    private var socketReceiveBufferBytes = 0
    private var maxRecvGapNanos: UInt64 = 0
    private var recvGapsOver50msCount = 0

    public init(port: UInt16 = 54321, keepAliveHost: String? = "192.168.0.10") {
        self.port = port
        self.keepAliveHost = keepAliveHost
    }

    /// `resetPeakGap` matters: `maxRecvGapMs` is a peak-since-last-reset, and this method has
    /// two callers on very different cadences - CameraSession's per-frame stats refresh (which
    /// must NOT reset the peak, or the 5s log only ever sees the gap since the most recent
    /// frame - the exact bug that made the first field logs show "maxgap=0ms" next to dozens of
    /// >50ms gaps) and the 5s diagnostic sampler (which should reset it, defining the interval).
    public func statsSnapshot(resetPeakGap: Bool = false) -> LiveViewStats {
        lock.lock()
        defer { lock.unlock() }
        let gapMs = Int(maxRecvGapNanos / 1_000_000)
        if resetPeakGap {
            maxRecvGapNanos = 0
        }
        return LiveViewStats(
            validFrameCount: validFrameCount,
            droppedFrameCount: droppedFrameCount,
            bufferDroppedFrameCount: bufferDroppedFrameCount,
            framesStartedCount: framesStartedCount,
            droppedFramesMissingPackets: droppedFramesMissingPackets,
            droppedFramesExpectedPackets: droppedFramesExpectedPackets,
            socketReceiveBufferBytes: socketReceiveBufferBytes,
            maxRecvGapMs: gapMs,
            recvGapsOver50msCount: recvGapsOver50msCount
        )
    }

    /// Starts listening; frames are delivered via the returned AsyncStream until `stop()` is
    /// called or the consuming Task is cancelled (which triggers onTermination -> stop()).
    ///
    /// `.bufferingNewest(1)` (not the default `.unbounded`) matters: if the MainActor consumer
    /// falls behind for a moment (decoding a thumbnail, running focus-peaking's Core Image
    /// pipeline, etc.), an unbounded buffer would let frames pile up and then get drained in one
    /// tight back-to-back loop once the consumer catches up - each iteration synchronously
    /// reassigning `CameraSession.latestFrameData` with no chance for SwiftUI to render in
    /// between, which is exactly what triggered a live, on-device "onChange action tried to
    /// update multiple times per frame" fault (2026-07-11). Keeping only the newest buffered
    /// frame means a slow consumer just skips stale frames instead of ever building a backlog -
    /// there is never anything to "catch up" on.
    public func start() -> AsyncStream<LiveViewFrame> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let thread = Thread { [weak self] in
                self?.runLoop(continuation: continuation)
            }
            thread.name = "com.yim1.liveview.udp"
            // At ~600 packets/s a default-priority thread competes badly with UI work for CPU
            // time; falling behind on recv() is one of the ways the kernel's socket buffer can
            // overflow and silently discard datagrams (which then shows up as "net" frame drops
            // indistinguishable from RF loss). This thread does little work per packet - give it
            // the priority to actually run whenever a packet is waiting.
            thread.qualityOfService = .userInteractive
            thread.start()
            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        isRunning = false
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    private func runLoop(continuation: AsyncStream<LiveViewFrame>.Continuation) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            continuation.finish()
            return
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            continuation.finish()
            return
        }

        // Receive timeout so the loop periodically re-checks isRunning instead of blocking
        // forever - mirrors the Python reference's sock.settimeout(0.5).
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Bigger kernel receive buffer (default is a few tens of KB) so a brief stall on our end
        // (a slow MainActor render, a momentary RF dip) doesn't make the OS itself start
        // silently dropping datagrams before this thread even gets to read them - found
        // on-device 2026-07-11 (stutters + fps dips while panning the camera). Best-effort: if
        // the OS clamps it lower, that's fine, this is just headroom, not a correctness
        // requirement.
        var rcvbufSize: Int32 = 1_048_576
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbufSize, socklen_t(MemoryLayout<Int32>.size))

        // Mark this socket's traffic as interactive video (WMM access category VI) - a public,
        // documented lever that hints the system's Wi-Fi power management to keep the radio
        // active for this flow. Added 2026-07-11 after field logs showed bimodal radio-away
        // behavior (stretches of 5-6 >50ms gaps per second) that the keep-alive alone didn't
        // prevent. Best-effort: ignored where unsupported.
        var serviceType: Int32 = NET_SERVICE_TYPE_VI
        setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &serviceType, socklen_t(MemoryLayout<Int32>.size))
        // Read back what the kernel ACTUALLY granted (it silently clamps requests) - reported in
        // stats so a too-small buffer is visible instead of assumed away.
        var actualRcvbuf: Int32 = 0
        var actualRcvbufLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &actualRcvbuf, &actualRcvbufLen)

        // Prepared once for the Wi-Fi keep-alive uplink (see keepAliveHost's doc comment).
        var keepAliveAddr: sockaddr_in?
        if let host = keepAliveHost {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr(host)
            keepAliveAddr = addr
        }
        var lastKeepAlive = DispatchTime.now()

        lock.lock()
        socketFD = fd
        isRunning = true
        validFrameCount = 0
        droppedFrameCount = 0
        bufferDroppedFrameCount = 0
        framesStartedCount = 0
        droppedFramesMissingPackets = 0
        droppedFramesExpectedPackets = 0
        socketReceiveBufferBytes = Int(actualRcvbuf)
        maxRecvGapNanos = 0
        recvGapsOver50msCount = 0
        lock.unlock()
        var lastRecvTime: UInt64 = 0

        // Reorder-tolerant reassembly with a TWO-frame window (evolved 2026-07-11 across the
        // stream-stability work; see DEVELOPMENT_PLAN.md's dated notes):
        // - v1 (original port): packets had to arrive in strict ascending order; any
        //   out-of-sequence packet killed the whole frame. But UDP guarantees delivery, not
        //   order - mere reordering was treated as loss.
        // - v2: buffer packets by index within the current frame, complete when all arrive. But
        //   the frame was still abandoned the instant the NEXT frame's first packet showed up -
        //   and with Wi-Fi MAC-layer retransmissions, frame N's last packet routinely arrives
        //   AFTER frame N+1 has started (INTER-frame straggler). On-device stats showed drops
        //   were overwhelmingly this "net" category (599 net vs 11 buf), motivating:
        // - v3 (this): keep up to TWO frames in assembly simultaneously. A straggler for the
        //   previous frame can still complete it while the next one is being received. A frame
        //   is dropped only when (a) a third frame index arrives while it's still incomplete
        //   (evicted - by then its packets are genuinely not coming), or (b) a NEWER frame
        //   completes first (the older one would be stale on screen anyway; evicting on newer-
        //   completion also keeps "an old frame never flashes after a newer one" as an
        //   invariant, so yields stay monotonic without any extra bookkeeping).
        struct PendingFrame {
            let frameIdx: UInt32
            let expected: Int
            var pieces: [Data?]
            var receivedCount = 0
            var byteCount = 0

            init(frameIdx: UInt32, expected: Int) {
                self.frameIdx = frameIdx
                self.expected = expected
                self.pieces = Array(repeating: nil, count: expected)
            }

            var isComplete: Bool { receivedCount == expected }

            mutating func add(_ payload: Data, at index: Int) {
                guard index >= 0, index < pieces.count, pieces[index] == nil else { return }
                pieces[index] = payload
                receivedCount += 1
                byteCount += payload.count
            }

            func assembled() -> Data? {
                var data = Data()
                data.reserveCapacity(byteCount)
                for piece in pieces {
                    guard let piece else { return nil } // defensive; isComplete guards this
                    data.append(piece)
                }
                return data
            }
        }

        // Sanity bound on the per-packet-declared total: lenPacketFrame comes off the wire, and
        // a corrupt value would otherwise drive a huge Array allocation. Real frames are ~30-40
        // packets (a ~50KB JPEG at ~1.4KB per datagram).
        let maxReasonablePacketCount = 1024
        var pending: [PendingFrame] = [] // arrival order, at most 2 entries
        var buffer = [UInt8](repeating: 0, count: 1_024_000)

        func recordDrop(_ frame: PendingFrame) {
            lock.lock()
            droppedFrameCount += 1
            droppedFramesMissingPackets += frame.expected - frame.receivedCount
            droppedFramesExpectedPackets += frame.expected
            lock.unlock()
        }

        while true {
            lock.lock()
            let running = isRunning
            lock.unlock()
            guard running else { break }

            // Wi-Fi keep-alive uplink (see keepAliveHost's doc comment) - checked here so it
            // fires both on packet arrivals and on recv timeouts (i.e. it keeps transmitting
            // even during exactly the kind of inbound dead air it's meant to prevent).
            if var addr = keepAliveAddr,
               DispatchTime.now().uptimeNanoseconds - lastKeepAlive.uptimeNanoseconds > UInt64(keepAliveInterval * 1_000_000_000) {
                lastKeepAlive = DispatchTime.now()
                var byte: UInt8 = 0
                _ = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        sendto(fd, &byte, 1, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }

            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                recv(fd, rawBuffer.baseAddress, rawBuffer.count, 0)
            }
            guard bytesRead >= 12 else {
                // Includes recv() < 0 (timeout/EWOULDBLOCK included, or the socket having just
                // been closed by stop() from another thread) - just loop and recheck isRunning.
                continue
            }

            // Radio-away detection: gap since the previous successful datagram (see
            // LiveViewStats.maxRecvGapMs). ~1ms is normal mid-stream; tens/hundreds of ms means
            // the radio wasn't listening. Only gaps above 5ms bother taking the lock - the
            // normal-case packet cadence never comes near that.
            let nowNanos = DispatchTime.now().uptimeNanoseconds
            if lastRecvTime != 0 {
                let gap = nowNanos - lastRecvTime
                if gap > 5_000_000 {
                    lock.lock()
                    if gap > maxRecvGapNanos { maxRecvGapNanos = gap }
                    if gap > 50_000_000 { recvGapsOver50msCount += 1 }
                    lock.unlock()
                }
            }
            lastRecvTime = nowNanos

            // Header fields parsed straight out of the receive buffer, and the payload copied
            // out of it exactly once - the earlier code first wrapped the whole packet in a
            // `Data` and then copied the payload out of THAT (two allocations+copies per packet,
            // ~600 packets/s at speed, on this hot thread).
            func beU32(_ offset: Int) -> UInt32 {
                UInt32(buffer[offset]) << 24 | UInt32(buffer[offset + 1]) << 16
                    | UInt32(buffer[offset + 2]) << 8 | UInt32(buffer[offset + 3])
            }
            let idxFrame = beU32(0)
            let lenPacketFrame = beU32(4)
            let idxPacketFrame = beU32(8)
            let payload = Data(buffer[12..<bytesRead])

            if let i = pending.firstIndex(where: { $0.frameIdx == idxFrame }) {
                pending[i].add(payload, at: Int(idxPacketFrame))
            } else {
                let expected = Int(lenPacketFrame)
                guard expected > 0, expected <= maxReasonablePacketCount else { continue }
                var newFrame = PendingFrame(frameIdx: idxFrame, expected: expected)
                newFrame.add(payload, at: Int(idxPacketFrame))
                pending.append(newFrame)
                lock.lock()
                framesStartedCount += 1
                lock.unlock()
                if pending.count > 2 {
                    // The oldest in-flight frame has now survived two newer frames starting -
                    // its missing packets are genuinely gone, not just late.
                    let evicted = pending.removeFirst()
                    recordDrop(evicted)
                }
            }

            guard let completedAt = pending.firstIndex(where: { $0.isComplete }) else { continue }
            let completed = pending.remove(at: completedAt)
            // Anything older than the completed frame is stale now - it may only complete
            // after a newer frame has already been shown, so it's dropped here (this is also
            // what keeps yields monotonically newer).
            while completedAt > 0, !pending.isEmpty {
                let evicted = pending.removeFirst()
                recordDrop(evicted)
                break // completedAt > 0 means exactly one older entry can exist (window of 2)
            }

            guard let frameData = completed.assembled(), frameData.count > 2048 else { continue }
            let headerBytes = Data(frameData.prefix(2048))
            let jpegBytes = Data(frameData.suffix(from: frameData.startIndex + 2048))
            let metadata = CameraMetadata.parse(headerBytes: headerBytes)
            lock.lock()
            validFrameCount += 1
            lock.unlock()
            // The yield result tells us whether the AsyncStream's `.bufferingNewest(1)`
            // policy actually delivered this frame or silently discarded it because the
            // consumer hadn't finished with the previous one - see the LiveViewStats doc
            // comment. Without checking this, a fully-reassembled frame that never reaches
            // the screen looks identical to one that was never lost, from this thread's own
            // point of view.
            switch continuation.yield(LiveViewFrame(metadata: metadata, jpegData: jpegBytes)) {
            case .dropped:
                lock.lock()
                bufferDroppedFrameCount += 1
                lock.unlock()
            case .enqueued, .terminated:
                break
            @unknown default:
                break
            }
        }

        // If the loop exited because stop() flipped isRunning to false, stop() already closed
        // the socket and cleared socketFD - only close it here if that hasn't happened (e.g. the
        // consuming Task was cancelled and AsyncStream's onTermination hasn't run yet).
        lock.lock()
        if socketFD == fd {
            close(fd)
            socketFD = -1
        }
        lock.unlock()
        continuation.finish()
    }
}
