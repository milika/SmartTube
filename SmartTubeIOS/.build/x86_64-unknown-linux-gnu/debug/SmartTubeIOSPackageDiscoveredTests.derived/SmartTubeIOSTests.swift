import XCTest
@testable import SmartTubeIOSTests

fileprivate extension AppSettingsTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__AppSettingsTests = [
        ("testDefaultSettings", testDefaultSettings),
        ("testSettingsEncodeDecode", testSettingsEncodeDecode)
    ]
}

fileprivate extension SponsorSegmentTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__SponsorSegmentTests = [
        ("testAllCategoriesCovered", testAllCategoriesCovered),
        ("testSegmentInRange", testSegmentInRange)
    ]
}

fileprivate extension VideoFormatTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__VideoFormatTests = [
        ("testQualityLabel30fps", testQualityLabel30fps),
        ("testQualityLabel60fps", testQualityLabel60fps)
    ]
}

fileprivate extension VideoGroupTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__VideoGroupTests = [
        ("testDefaultSections", testDefaultSections),
        ("testVideoGroupAppend", testVideoGroupAppend)
    ]
}

fileprivate extension VideoModelTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__VideoModelTests = [
        ("testFormattedDurationMinutesSeconds", testFormattedDurationMinutesSeconds),
        ("testFormattedDurationNil", testFormattedDurationNil),
        ("testFormattedDurationWithHours", testFormattedDurationWithHours),
        ("testFormattedViewCountMillions", testFormattedViewCountMillions),
        ("testFormattedViewCountThousands", testFormattedViewCountThousands),
        ("testHighQualityThumbnailURL", testHighQualityThumbnailURL),
        ("testVideoHashableAndEquatable", testVideoHashableAndEquatable)
    ]
}
@available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
func __SmartTubeIOSTests__allTests() -> [XCTestCaseEntry] {
    return [
        testCase(AppSettingsTests.__allTests__AppSettingsTests),
        testCase(SponsorSegmentTests.__allTests__SponsorSegmentTests),
        testCase(VideoFormatTests.__allTests__VideoFormatTests),
        testCase(VideoGroupTests.__allTests__VideoGroupTests),
        testCase(VideoModelTests.__allTests__VideoModelTests)
    ]
}