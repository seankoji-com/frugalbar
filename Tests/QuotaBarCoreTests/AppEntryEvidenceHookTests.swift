import Foundation
import Testing

/// C7: `ActivityEvidenceRenderer` is only reachable from a built executable if
/// the app entry point calls it. No test target depends on the executable
/// target, so this checks the entry source directly: a deleted call — the
/// exact defect that made the released-binary route unreachable — fails here.
@Suite("App entry evidence hook")
struct AppEntryEvidenceHookTests {

    private func appMainSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // QuotaBarCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
        return try String(
            contentsOf: root.appendingPathComponent("Sources/QuotaBarApp/AppMain.swift"),
            encoding: .utf8)
    }

    @Test("the entry initializer runs the evidence renderer after CLI flags and before app state")
    func evidenceHookRunsAfterCLIAndBeforeAppState() throws {
        let source = try appMainSource()
        let appStruct = try #require(source.range(of: "struct QuotaBarApp: App"))
        let initStart = try #require(
            source.range(of: "init() {", range: appStruct.lowerBound..<source.endIndex))
        let bodyStart = try #require(
            source.range(of: "var body: some Scene", range: initStart.lowerBound..<source.endIndex))
        let cli = try #require(
            source.range(
                of: "CLIArguments.handleIfPresent()",
                range: initStart.upperBound..<bodyStart.lowerBound))
        let hook = try #require(
            source.range(
                of: "ActivityEvidenceRenderer.runFromEnvironmentAndExit()",
                range: cli.upperBound..<bodyStart.lowerBound),
            "the app entry point never invokes the controlled evidence renderer")

        // --help, --version and --doctor still exit before the renderer is
        // consulted.
        #expect(cli.lowerBound < hook.lowerBound)
        // Nothing between the CLI exit and the hook builds the app delegate,
        // a store or a poll.
        let between = source[cli.upperBound..<hook.lowerBound]
        #expect(!between.contains("AppDelegate("))
        #expect(!between.contains("QuotaManager"))
        #expect(!between.contains("QuotaHistoryStore"))
    }
}
