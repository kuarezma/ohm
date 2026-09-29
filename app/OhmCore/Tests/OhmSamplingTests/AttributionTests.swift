import OhmModel
import Testing
@testable import OhmSampling

@Suite struct AttributionTests {
    static let chrome = "/Applications/Google Chrome.app"
    static let chromeRenderer = chrome + "/Contents/Frameworks/Google Chrome Framework.framework/Versions/130/Helpers/"
        + "Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
    static let safari = "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"
    static let webContent = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/"
        + "com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"

    func world() -> FakeMetadata {
        let m = FakeMetadata()
        m.bundles[Self.chrome] = BundleInfo(bundleID: "com.google.Chrome", executable: "Google Chrome", displayName: "Google Chrome")
        m.bundles[Self.safari] = BundleInfo(bundleID: "com.apple.Safari", executable: "Safari", displayName: "Safari")
        m.bundles["/Applications/Slack.app"] = BundleInfo(bundleID: "com.tinyspeck.slackmacgap", executable: "Slack", displayName: "Slack")
        m.bundles["/Applications/Utilities/Terminal.app"] = BundleInfo(bundleID: "com.apple.Terminal", executable: "Terminal", displayName: nil)
        m.paths[100] = Self.chrome + "/Contents/MacOS/Google Chrome"
        m.paths[101] = Self.chromeRenderer
        m.responsible[101] = 100
        m.paths[200] = Self.safari + "/Contents/MacOS/Safari"
        m.paths[201] = Self.webContent
        m.responsible[201] = 200
        m.paths[300] = "/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
        m.paths[301] = "/opt/homebrew/Cellar/node/22.1.0/bin/node"
        m.responsible[301] = 300
        m.paths[400] = "/Applications/Slack.app/Contents/Frameworks/Slack Helper (Renderer).app/Contents/MacOS/Slack Helper (Renderer)"
        m.responsible[400] = 400  // Electron helpers often report themselves
        return m
    }

    func resolve(_ pid: Int32, _ m: FakeMetadata) -> Attribution {
        AttributionResolver(meta: m).resolve(ProcessIdentity(pid: pid, startAbsTime: 1))
    }

    @Test func chromeHelperRollsUpToChrome() {
        let a = resolve(101, world())
        #expect(a.key == AppKey(kind: .bundleID, value: "com.google.Chrome"))
        #expect(a.bundlePath == Self.chrome)
        #expect(a.category == .userApp)
    }

    @Test func chromeHelperRollsUpWithoutSPI() {
        let m = world()
        m.spiAvailable = false
        #expect(resolve(101, m).key == AppKey(kind: .bundleID, value: "com.google.Chrome"))
    }

    @Test func webContentXPCRollsUpToSafariViaResponsiblePID() {
        let a = resolve(201, world())
        #expect(a.key == AppKey(kind: .bundleID, value: "com.apple.Safari"))
        #expect(a.category == .userApp)  // cryptex path counts as /System/Applications
    }

    @Test func webContentWithoutSPIGetsItsOwnRow() {
        let m = world()
        m.spiAvailable = false
        let a = resolve(201, m)
        #expect(a.key == AppKey(kind: .executableName, value: "com.apple.WebKit.WebContent"))
        #expect(a.category == .macOSService)
    }

    @Test func terminalLaunchedNodeKeepsItsOwnRowAcrossVersions() {
        let a = resolve(301, world())
        #expect(a.key == AppKey(kind: .executableName, value: "node"))
        #expect(a.bundlePath == nil)
    }

    @Test func electronHelperWithSelfResponsibilityUsesOutermostApp() {
        #expect(resolve(400, world()).key == AppKey(kind: .bundleID, value: "com.tinyspeck.slackmacgap"))
    }

    @Test func unreadablePathFallsBackToProcessName() {
        let m = world()
        m.names[500] = "mds_stores"
        #expect(resolve(500, m).key == AppKey(kind: .processName, value: "mds_stores"))
    }

    @Test func bundleWithoutIdentifierUsesExecutableName() {
        let m = FakeMetadata()
        m.paths[600] = "/Applications/Tool.app/Contents/MacOS/tool"
        m.bundles["/Applications/Tool.app"] = BundleInfo(bundleID: nil, executable: "tool", displayName: nil)
        let a = resolve(600, m)
        #expect(a.key == AppKey(kind: .executableName, value: "tool"))
        #expect(a.displayName == "Tool")
    }

    @Test func displayNameFallsBackToBundleFileName() {
        #expect(resolve(300, world()).displayName == "Terminal")
    }

    @Test func resultIsCachedPerIdentityAndPruned() {
        let m = world()
        let r = AttributionResolver(meta: m)
        let id = ProcessIdentity(pid: 100, startAbsTime: 1)
        _ = r.resolve(id)
        let calls = m.pathCalls
        _ = r.resolve(id)
        #expect(m.pathCalls == calls)
        r.prune(keeping: [])
        #expect(r.cachedCount == 0)
    }

    @Test(arguments: [
        ("/usr/libexec/trustd", nil, AppCategory.macOSService),
        ("/System/Cryptexes/App/usr/libexec/SafariNotificationAgent", nil, .macOSService),
        ("/Library/Apple/System/Library/foo", nil, .macOSService),
        ("/System/Applications/Mail.app", "com.apple.mail", .userApp),
        ("/Applications/Xcode.app", "com.apple.dt.Xcode", .userApp),
        ("/Library/PrivilegedHelperTools/X.app", "com.apple.fake", .macOSService),
        ("/usr/local/bin/python3", nil, .userApp),
        ("/Users/u/bin/tool", nil, .userApp),
    ] as [(String, String?, AppCategory)])
    func categoryRules(path: String, bundleID: String?, expected: AppCategory) {
        #expect(AttributionResolver.category(path: path, bundleID: bundleID) == expected)
    }

    @Test func outermostAppPicksFirstBundle() {
        #expect(AttributionResolver.outermostApp(Self.chromeRenderer) == Self.chrome)
        #expect(AttributionResolver.outermostApp("/usr/bin/yes") == nil)
    }
}
