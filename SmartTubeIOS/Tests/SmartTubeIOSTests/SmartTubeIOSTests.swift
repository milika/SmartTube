import XCTest
@testable import SmartTubeIOSCore

// MARK: - VideoModelTests

final class VideoModelTests: XCTestCase {

    func testFormattedDurationMinutesSeconds() {
        let video = Video(id: "test", title: "Test", channelTitle: "Channel", duration: 125)
        XCTAssertEqual(video.formattedDuration, "2:05")
    }

    func testFormattedDurationWithHours() {
        let video = Video(id: "test", title: "Test", channelTitle: "Channel", duration: 3661)
        XCTAssertEqual(video.formattedDuration, "1:01:01")
    }

    func testFormattedDurationNil() {
        let video = Video(id: "test", title: "Test", channelTitle: "Channel")
        XCTAssertEqual(video.formattedDuration, "")
    }

    func testFormattedViewCountThousands() {
        let video = Video(id: "v", title: "T", channelTitle: "C", viewCount: 1_500)
        XCTAssertEqual(video.formattedViewCount, "1.5K views")
    }

    func testFormattedViewCountMillions() {
        let video = Video(id: "v", title: "T", channelTitle: "C", viewCount: 2_000_000)
        XCTAssertEqual(video.formattedViewCount, "2.0M views")
    }

    func testHighQualityThumbnailURL() {
        let video = Video(id: "dQw4w9WgXcQ", title: "T", channelTitle: "C")
        XCTAssertEqual(
            video.highQualityThumbnailURL,
            URL(string: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
        )
    }

    func testVideoHashableAndEquatable() {
        let v1 = Video(id: "abc", title: "A", channelTitle: "X")
        let v2 = Video(id: "abc", title: "A", channelTitle: "X")
        let v3 = Video(id: "xyz", title: "B", channelTitle: "Y")
        XCTAssertEqual(v1, v2)
        XCTAssertNotEqual(v1, v3)
    }
}

// MARK: - VideoGroupTests

final class VideoGroupTests: XCTestCase {

    func testDefaultSections() {
        let sections = BrowseSection.defaultSections
        XCTAssertFalse(sections.isEmpty)
        XCTAssertEqual(sections.first?.type, .home)
    }

    func testVideoGroupAppend() {
        var group = VideoGroup(title: "Home", videos: [
            Video(id: "1", title: "V1", channelTitle: "C"),
        ])
        let newVideo = Video(id: "2", title: "V2", channelTitle: "C")
        group.videos.append(newVideo)
        XCTAssertEqual(group.videos.count, 2)
    }
}

// MARK: - AppSettingsTests

final class AppSettingsTests: XCTestCase {

    func testDefaultSettings() {
        let settings = AppSettings()
        XCTAssertEqual(settings.preferredQuality, .auto)
        XCTAssertEqual(settings.playbackSpeed, 1.0)
        XCTAssertTrue(settings.autoplayEnabled)
        XCTAssertFalse(settings.subtitlesEnabled)
        XCTAssertTrue(settings.sponsorBlockEnabled)
        XCTAssertFalse(settings.deArrowEnabled)
        XCTAssertEqual(settings.themeName, .system)
    }

    func testSettingsEncodeDecode() throws {
        var settings = AppSettings()
        settings.preferredQuality = .q1080
        settings.playbackSpeed    = 1.5
        settings.sponsorBlockEnabled = false

        let data    = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.preferredQuality,    .q1080)
        XCTAssertEqual(decoded.playbackSpeed,        1.5)
        XCTAssertFalse(decoded.sponsorBlockEnabled)
    }
}

// MARK: - SponsorSegmentTests

final class SponsorSegmentTests: XCTestCase {

    func testSegmentInRange() {
        let seg = SponsorSegment(start: 30.0, end: 60.0, category: .sponsor)
        XCTAssertTrue(45.0 >= seg.start && 45.0 < seg.end)
        XCTAssertFalse(25.0 >= seg.start && 25.0 < seg.end)
    }

    func testAllCategoriesCovered() {
        // Ensure every Category rawValue is unique
        let raws = SponsorSegment.Category.allCases.map { $0.rawValue }
        XCTAssertEqual(Set(raws).count, raws.count)
    }
}

// MARK: - VideoFormatTests

final class VideoFormatTests: XCTestCase {

    func testQualityLabel30fps() {
        let f = VideoFormat(label: "720p", width: 1280, height: 720, fps: 30, mimeType: "video/mp4")
        XCTAssertEqual(f.qualityLabel, "720p")
    }

    func testQualityLabel60fps() {
        let f = VideoFormat(label: "1080p60", width: 1920, height: 1080, fps: 60, mimeType: "video/mp4")
        XCTAssertEqual(f.qualityLabel, "1080p60")
    }
}
