import Testing
@testable import OhmModel

struct OhmModelTests {
    @Test func placeholder() {
        let identity = ProcessIdentity(pid: 100, startAbsTime: 12345)
        #expect(identity.pid == 100)
        #expect(identity.startAbsTime == 12345)
    }
}
