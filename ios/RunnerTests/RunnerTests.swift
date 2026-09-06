import XCTest
@testable import Runner

final class RunnerTests: XCTestCase {
    func testBackgroundDownloadChannelNameMatchesFlutterContract() {
        XCTAssertEqual(
            BackgroundDownloadPlugin.channelName,
            "com.lineguide/background_download"
        )
    }
}
