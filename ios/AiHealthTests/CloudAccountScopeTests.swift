import XCTest
@testable import AiHealth

final class CloudAccountScopeTests: XCTestCase {
    func testFixedCloudKeepsThePreviousLocalNamespaceOnlyForTheSameAccount() {
        let account = UUID().uuidString.lowercased()
        let other = UUID().uuidString.lowercased()
        let current = "https://health.gzqy.xyz"
        let old = CloudAccountScope.previousURL + "/" + account
        XCTAssertEqual(CloudAccountScope.value(currentURL: current, userID: account, rememberedAlias: old), old)
        XCTAssertEqual(CloudAccountScope.value(currentURL: current, userID: other, rememberedAlias: old), current + "/" + other)
        XCTAssertEqual(CloudAccountScope.value(currentURL: current, userID: account, rememberedAlias: nil), current + "/" + account)
    }
}
