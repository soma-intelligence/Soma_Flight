import XCTest

/// DesignBridge parity captures: launches each screenshot scenario on the Debug fakes and writes the
/// screen (PNG) and every visible element's type, label and frame (JSON) to `BRIDGE_DUMP_DIR`. The
/// Penpot boards are rebuilt from these. Skipped when the variable is not set.
@MainActor
final class BridgeDumpUITests: XCTestCase {
    private static let scenarios: [(String, [String])] = [
        ("home-medium", ["-detent", "medium"]),
        ("home-expanded", ["-detent", "expanded"]),
        ("flight", ["-open", "flight", "-detent", "expanded"]),
        ("flight-medium", ["-open", "flight", "-detent", "medium"]),
        ("airport", ["-open", "airport:KSFO", "-detent", "expanded"]),
        ("friends", ["-tab", "friends", "-detent", "expanded"]),
        ("friend", ["-open", "friend", "-detent", "expanded"]),
        ("passport", ["-tab", "passport", "-detent", "expanded"]),
        ("fp-passport", ["-fullPage", "passport"]),
        ("fp-delays", ["-fullPage", "delays"]),
        ("fp-aircraft", ["-fullPage", "aircraftStats"]),
        ("search", ["-sheet", "search", "-searchText", "af 84"]),
        ("settings", ["-sheet", "settings"]),
        ("settings-docs", ["-sheet", "settings", "-settingsPage", "documents"]),
        ("profile", ["-sheet", "settings", "-settingsPage", "profile", "-fakeSignIn", "apple"]),
    ]

    func testDumpScreens() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["BRIDGE_DUMP_DIR"] ?? env["TEST_RUNNER_BRIDGE_DUMP_DIR"] else {
            throw XCTSkip("BRIDGE_DUMP_DIR not set")
        }
        let only = (env["BRIDGE_DUMP_ONLY"] ?? env["TEST_RUNNER_BRIDGE_DUMP_ONLY"])?.split(separator: ",").map(String.init)
        let appearance = env["BRIDGE_DUMP_APPEARANCE"] ?? env["TEST_RUNNER_BRIDGE_DUMP_APPEARANCE"] ?? "light"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, args) in Self.scenarios where only == nil || only!.contains(name) {
            let app = XCUIApplication()
            // The appearance is the simulator's (`simctl ui <udid> appearance dark`); it only names the files.
            app.launchArguments = ["-useFakes", "YES"] + args
            app.launch()
            sleep(6)
            let shot = app.screenshot().pngRepresentation
            try shot.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(appearance).png"))
            let window = app.windows.firstMatch.frame
            // One snapshot of the whole tree: querying each element is minutes per screen.
            var rows: [[String: Any]] = []
            func walk(_ el: XCUIElementSnapshot, _ depth: Int) {
                let f = el.frame
                if !f.isEmpty, window.intersects(f) {
                    rows.append(["type": el.elementType.rawValue, "label": el.label, "value": (el.value as? String) ?? "",
                                 "id": el.identifier, "depth": depth,
                                 "x": f.minX, "y": f.minY, "w": f.width, "h": f.height])
                }
                for child in el.children { walk(child, depth + 1) }
            }
            walk(try app.snapshot(), 0)
            let data = try JSONSerialization.data(withJSONObject: ["screen": name, "window": [window.width, window.height],
                                                                   "elements": rows], options: [.prettyPrinted])
            try data.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(appearance).json"))
            app.terminate()
        }
    }
}
