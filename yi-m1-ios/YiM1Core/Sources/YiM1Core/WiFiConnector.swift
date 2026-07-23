// Wi-Fi "join" - v1 manual flow (DECIDED 2026-07-07, see DEVELOPMENT_PLAN.md Part 4.2).
//
// No paid Apple Developer account, so no NEHotspotConfiguration entitlement in v1: this does
// NOT attempt to programmatically join the camera's Wi-Fi network. Instead, the UI layer shows
// the user the credentials (from BLEPairing) with a copy-password button and a button that
// opens Settings (UIApplication.openSettingsURLString - official, unentitled API; the user taps
// Wi-Fi from there themselves), while this polls for reachability in the background - the same
// "don't trust the join mechanism, just check the thing we actually need" lesson already proven
// on the macOS app (see ../../yi-m1-remote-control/app/ARCHITECTURE.md bug #8).
//
// 2026-07-12: a programmatic NEHotspotConfiguration-based auto-join was spiked and reverted -
// personal (free) Apple Developer accounts can't provision the Hotspot Configuration
// entitlement, so Xcode couldn't create a signing profile at all. Back to manual-join only;
// see YiM1Monitor/App/YiM1Monitor.entitlements (now removed) and project.yml.
import Foundation

public actor WiFiConnector {
    public enum ConnectorError: Error, Sendable, Equatable {
        case reachabilityTimedOut
    }

    private let httpClient: HTTPClient

    public init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    /// Polls GetCameraStatus until it succeeds or `timeout` elapses. Call this after presenting
    /// the manual-join sheet (or immediately, for the "already on camera Wi-Fi" direct-connect
    /// path - fact #2 in DEVELOPMENT_PLAN.md, no BLE/sheet needed if already reachable).
    public func waitForReachability(timeout: TimeInterval = 120, pollInterval: TimeInterval = 1.5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return }
            let response = await httpClient.send(Commands.getCameraStatus(), timeout: 2.0)
            if response.status == 200 {
                return
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw ConnectorError.reachabilityTimedOut
    }

    /// One-shot reachability check with no retry loop - for the "Connect directly" button,
    /// which should fail fast (not wait 120s) if the phone isn't actually on the camera network.
    public func isReachableNow() async -> Bool {
        let response = await httpClient.send(Commands.getCameraStatus(), timeout: 2.0)
        return response.status == 200
    }
}
