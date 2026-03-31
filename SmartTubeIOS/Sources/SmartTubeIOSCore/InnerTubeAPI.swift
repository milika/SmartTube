import Foundation
import os
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let tubeLog = Logger(subsystem: "com.smarttube.app", category: "InnerTube")

// MARK: - InnerTubeAPI
//
// Implements a subset of the unofficial YouTube InnerTube API used by
// the Android SmartTube client (MediaServiceCore). This layer replaces
// the Java-based youtubeapi module.
//
// References:
//   https://github.com/LuanRT/YouTube.js/blob/main/src/core/clients/Web.ts
//   https://github.com/TeamNewPipe/NewPipeExtractor

public actor InnerTubeAPI {

    // MARK: - Configuration

    private let session: URLSession
    private var visitorData: String?
    private var authToken: String?

    /// The web client context used to fetch home/search/channel feeds.
    private let webClientContext: [String: Any] = [
        "client": [
            "hl": "en",
            "gl": "US",
            "clientName": "WEB",
            "clientVersion": "2.20260206.01.00",
        ]
    ]

    /// The Android client context used for authenticated browse (subscriptions, history).
    /// youtubei.googleapis.com accepts OAuth Bearer tokens; youtube.com (WEB client) does not.
    private let androidClientContext: [String: Any] = [
        "client": [
            "hl": "en",
            "gl": "US",
            "clientName": "ANDROID",
            "clientVersion": "18.11.34",
            "androidSdkVersion": 30,
            "deviceMake": "Google",
            "deviceModel": "Pixel 2 XL",
        ]
    ]

    /// The iOS client context used for stream URL retrieval.
    /// Returns c=iOS URLs and an HLS manifest, both playable natively by AVPlayer.
    private let iosClientContext: [String: Any] = [
        "client": [
            "hl": "en",
            "gl": "US",
            "clientName": "iOS",
            "clientVersion": "20.11.6",
            "deviceMake": "Apple",
            "deviceModel": "iPhone10,4",
            "osName": "iOS",
            "osVersion": "16.7.7.20H330",
            "clientScreen": "WATCH",
        ]
    ]
    private let iosUserAgent = "com.google.ios.youtube/20.11.6 (iPhone10,4; U; CPU iOS 16_7_7 like Mac OS X)"

    private let baseURL = URL(string: "https://www.youtube.com/youtubei/v1")!
    /// Authenticated browse uses googleapis.com which supports OAuth Bearer tokens.
    private let authBaseURL = URL(string: "https://youtubei.googleapis.com/youtubei/v1")!
    private let playerBaseURL = URL(string: "https://youtubei.googleapis.com/youtubei/v1")!
    // Public InnerTube API key embedded in YouTube's own web client JS — not a developer secret.
    // nosec: false positive — this key is published by Google in youtube.com/s/player JS.
    private let apiKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8" // gitleaks:allow

    public init(authToken: String? = nil) {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "Content-Type": "application/json",
            "X-YouTube-Client-Name": "1",
            "X-YouTube-Client-Version": "2.20240101.00.00",
            "Origin": "https://www.youtube.com",
        ]
        self.session = URLSession(configuration: config)
        self.authToken = authToken
    }

    // MARK: - Auth

    public func setAuthToken(_ token: String?) {
        let msg = token != nil ? "token(\(token!.prefix(8))…)" : "nil"
        tubeLog.notice("setAuthToken: \(msg, privacy: .public)")
        print("[InnerTube] setAuthToken: \(msg)")
        self.authToken = token
    }

    // MARK: - Browse

    /// Fetches the home feed.
    public func fetchHome(continuationToken: String? = nil) async throws -> VideoGroup {
        let body = makeBody(client: webClientContext, continuationToken: continuationToken)
        let endpoint = continuationToken != nil ? "browse" : "browse"
        var browseBody = body
        if continuationToken == nil {
            browseBody["browseId"] = "FEwhat_to_watch"
        }
        let data = try await post(endpoint: endpoint, body: browseBody)
        return try parseVideoGroup(from: data, title: "Home")
    }

    /// Fetches the trending feed.
    public func fetchTrending() async throws -> VideoGroup {
        let body = makeBody(client: webClientContext)
        var browseBody = body
        browseBody["browseId"] = "FEtrending"
        let data = try await post(endpoint: "browse", body: browseBody)
        return try parseVideoGroup(from: data, title: "Trending")
    }

    /// Fetches subscriptions feed (requires auth).
    public func fetchSubscriptions(continuationToken: String? = nil) async throws -> VideoGroup {
        var body = makeBody(client: androidClientContext, continuationToken: continuationToken)
        if continuationToken == nil {
            body["browseId"] = "FEsubscriptions"
        }
        // Use googleapis.com which supports OAuth Bearer tokens; youtube.com WEB client does not.
        let data = try await postAuthenticated(endpoint: "browse", body: body)
        return try parseVideoGroup(from: data, title: "Subscriptions")
    }

    /// Fetches watch history (requires auth).
    public func fetchHistory(continuationToken: String? = nil) async throws -> VideoGroup {
        var body = makeBody(client: androidClientContext, continuationToken: continuationToken)
        if continuationToken == nil {
            body["browseId"] = "FEhistory"
        }
        let data = try await postAuthenticated(endpoint: "browse", body: body)
        return try parseVideoGroup(from: data, title: "History")
    }

    // MARK: - Search

    public func search(query: String, continuationToken: String? = nil) async throws -> VideoGroup {
        var body = makeBody(client: webClientContext, continuationToken: continuationToken)
        if continuationToken == nil {
            body["query"] = query
        }
        let data = try await post(endpoint: "search", body: body)
        return try parseVideoGroup(from: data, title: "Search: \(query)")
    }

    public func fetchSearchSuggestions(query: String) async throws -> [String] {
        var components = URLComponents(string: "https://suggestqueries-clients6.youtube.com/complete/search")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "youtube"),
            URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "callback", value: ""),
        ]
        guard let url = components.url else { return [] }
        let (data, _) = try await session.data(from: url)
        // Response format: [query, [[suggestion, 0, []], ...], ...]
        guard let raw = String(data: data, encoding: .utf8) else { return [] }
        // Strip callback wrapper
        let jsonString = raw
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "^\\w+\\(", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\)$", with: "", options: .regularExpression)
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [Any],
              let suggestions = json[safe: 1] as? [[Any]]
        else { return [] }
        return suggestions.compactMap { $0[safe: 0] as? String }
    }

    // MARK: - Channel

    public func fetchChannel(channelId: String) async throws -> (channel: Channel, videos: VideoGroup) {
        var body = makeBody(client: webClientContext)
        body["browseId"] = channelId
        let data = try await post(endpoint: "browse", body: body)
        return try parseChannel(from: data, channelId: channelId)
    }

    public func fetchChannelVideos(channelId: String, continuationToken: String? = nil) async throws -> VideoGroup {
        var body = makeBody(client: webClientContext, continuationToken: continuationToken)
        if continuationToken == nil {
            body["browseId"] = channelId
            body["params"] = "EgZ2aWRlb3PyBgQKAjoA"  // "Videos" tab parameter
        }
        let data = try await post(endpoint: "browse", body: body)
        return try parseVideoGroup(from: data, title: nil)
    }

    // MARK: - Player (stream URLs)

    public func fetchPlayerInfo(videoId: String) async throws -> PlayerInfo {
        var body = makeBody(client: iosClientContext)
        body["videoId"] = videoId
        body["racyCheckOk"] = true
        body["contentCheckOk"] = true
        let data = try await postPlayer(body: body)
        return try parsePlayerInfo(from: data, videoId: videoId)
    }

    // MARK: - Playlists

    public func fetchUserPlaylists() async throws -> [PlaylistInfo] {
        var body = makeBody(client: webClientContext)
        body["browseId"] = "FEmy_videos"
        let data = try await post(endpoint: "browse", body: body)
        return try parsePlaylists(from: data)
    }

    public func fetchPlaylistVideos(playlistId: String, continuationToken: String? = nil) async throws -> VideoGroup {
        var body = makeBody(client: webClientContext, continuationToken: continuationToken)
        if continuationToken == nil {
            body["browseId"] = "VL\(playlistId)"
        }
        let data = try await post(endpoint: "browse", body: body)
        return try parseVideoGroup(from: data, title: nil)
    }

    // MARK: - Networking

    /// Player requests use the Android client UA, googleapis.com base, and no auth header.
    private func postPlayer(body: [String: Any]) async throws -> [String: Any] {
        var comps = URLComponents(url: playerBaseURL.appendingPathComponent("player"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(iosUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("5", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue("20.11.6", forHTTPHeaderField: "X-YouTube-Client-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let playerVideoId = body["videoId"] as? String ?? ""
        tubeLog.notice("POST /player (ANDROID) videoId=\(playerVideoId, privacy: .public)")
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            tubeLog.error("❌ HTTP \(statusCode, privacy: .public) for /player")
            throw APIError.httpError(statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            tubeLog.error("❌ Non-dictionary JSON root for /player")
            throw APIError.decodingError("Root JSON is not a dictionary")
        }
        if let error = json["error"] as? [String: Any] {
            tubeLog.error("❌ API error in /player: \(String(describing: error["message"] ?? error), privacy: .public)")
        } else {
            let topKeys = Array(json.keys.prefix(6))
            tubeLog.notice("✅ /player HTTP \(statusCode, privacy: .public) keys: \(topKeys, privacy: .public)")
        }
        return json
    }

    private func post(endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        var comps = URLComponents(url: baseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // NOTE: youtube.com WEB client does NOT accept OAuth Bearer tokens.
        // Only postAuthenticated() (googleapis.com + Android client) adds the auth header.
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        tubeLog.notice("POST /\(endpoint, privacy: .public) auth=no (WEB/guest)")
        print("[InnerTube] POST /\(endpoint) auth=no (WEB/guest)")
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            tubeLog.error("❌ HTTP \(statusCode, privacy: .public) for /\(endpoint, privacy: .public)")
            throw APIError.httpError(statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            tubeLog.error("❌ Non-dictionary JSON root for /\(endpoint, privacy: .public)")
            throw APIError.decodingError("Root JSON is not a dictionary")
        }
        let topKeys = Array(json.keys.prefix(6))
        if let error = json["error"] as? [String: Any] {
            tubeLog.error("❌ API error in /\(endpoint, privacy: .public): \(String(describing: error["message"] ?? error), privacy: .public)")
        } else {
            tubeLog.notice("✅ /\(endpoint, privacy: .public) HTTP \(statusCode, privacy: .public) keys: \(topKeys, privacy: .public)")
        }
        return json
    }

    /// Authenticated browse request via youtubei.googleapis.com with Android client.
    /// googleapis.com supports OAuth Bearer tokens; youtube.com WEB client does not.
    private func postAuthenticated(endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        var comps = URLComponents(url: authBaseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let hasAuth = authToken != nil
        tubeLog.notice("POST (auth) /\(endpoint, privacy: .public) auth=\(hasAuth ? "yes" : "no", privacy: .public)")
        print("[InnerTube] POST auth/\(endpoint) auth=\(hasAuth ? "yes" : "no")")
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            tubeLog.error("❌ HTTP \(statusCode, privacy: .public) for auth/\(endpoint, privacy: .public)")
            throw APIError.httpError(statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            tubeLog.error("❌ Non-dictionary JSON root for auth/\(endpoint, privacy: .public)")
            throw APIError.decodingError("Root JSON is not a dictionary")
        }
        let topKeysAuth = Array(json.keys.prefix(6))
        if let error = json["error"] as? [String: Any] {
            tubeLog.error("❌ API error in auth/\(endpoint, privacy: .public): \(String(describing: error["message"] ?? error), privacy: .public)")
        } else {
            tubeLog.notice("✅ auth/\(endpoint, privacy: .public) HTTP \(statusCode, privacy: .public) keys: \(topKeysAuth, privacy: .public)")
        }
        return json
    }

    // MARK: - Body builders

    private func makeBody(client: [String: Any], continuationToken: String? = nil) -> [String: Any] {
        var body: [String: Any] = ["context": client]
        if let token = continuationToken {
            body["continuation"] = token
        }
        return body
    }

    // MARK: - Parsers

    /// Internal accessor so unit tests can exercise the JSON parser without a live network.
    func parseVideoGroupForTesting(_ json: [String: Any], title: String?) throws -> VideoGroup {
        try parseVideoGroup(from: json, title: title)
    }

    private func parseVideoGroup(from json: [String: Any], title: String?) throws -> VideoGroup {
        var videos: [Video] = []
        var nextPageToken: String? = nil

        // Walk the renderer tree to find videoRenderers and continuationItemRenderers
        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                if let renderer = dict["videoRenderer"] as? [String: Any] {
                    if let v = parseVideoRenderer(renderer) { videos.append(v) }
                } else if let renderer = dict["gridVideoRenderer"] as? [String: Any] {
                    if let v = parseVideoRenderer(renderer) { videos.append(v) }
                } else if let renderer = dict["richItemRenderer"] as? [String: Any],
                          let content = renderer["content"] as? [String: Any],
                          let videoRenderer = content["videoRenderer"] as? [String: Any] {
                    if let v = parseVideoRenderer(videoRenderer) { videos.append(v) }
                } else if let renderer = dict["compactVideoRenderer"] as? [String: Any] {
                    if let v = parseVideoRenderer(renderer) { videos.append(v) }
                } else if let token = (dict["continuationItemRenderer"] as? [String: Any])?["continuationEndpoint"] as? [String: Any],
                          let continuation = (token["continuationCommand"] as? [String: Any])?["token"] as? String {
                    nextPageToken = continuation
                } else {
                    for value in dict.values { walk(value) }
                }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item) }
            }
        }

        walk(json)
        tubeLog.notice("parseVideoGroup '\(title ?? "nil", privacy: .public)' → \(videos.count, privacy: .public) videos, nextPage=\(nextPageToken != nil ? "yes" : "no", privacy: .public)")
        return VideoGroup(title: title, videos: videos, nextPageToken: nextPageToken)
    }

    private func parseVideoRenderer(_ r: [String: Any]) -> Video? {
        guard let videoId = r["videoId"] as? String else { return nil }

        let title = (r["title"] as? [String: Any]).flatMap { extractText($0) } ?? ""
        let channelTitle = (r["ownerText"] as? [String: Any]).flatMap { extractText($0) }
            ?? (r["shortBylineText"] as? [String: Any]).flatMap { extractText($0) }
            ?? ""

        // channelId: ownerText (videoRenderer) or shortBylineText (gridVideoRenderer)
        let channelId: String? = {
            let sourceKey = r["ownerText"] != nil ? "ownerText" : "shortBylineText"
            guard let runs = (r[sourceKey] as? [String: Any])?["runs"] as? [[String: Any]],
                  let first = runs.first,
                  let nav = first["navigationEndpoint"] as? [String: Any],
                  let browse = nav["browseEndpoint"] as? [String: Any]
            else { return nil }
            return browse["browseId"] as? String
        }()

        let thumbnails = (r["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbURL = thumbnails?.last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }

        // duration: lengthText (videoRenderer) or thumbnailOverlays[N].thumbnailOverlayTimeStatusRenderer.text (gridVideoRenderer)
        let lengthText: String? = (r["lengthText"] as? [String: Any]).flatMap { extractText($0) }
            ?? (r["thumbnailOverlays"] as? [[String: Any]])?
                .compactMap { ($0["thumbnailOverlayTimeStatusRenderer"] as? [String: Any])?["text"] as? [String: Any] }
                .first.flatMap { extractText($0) }
        let duration = lengthText.flatMap { parseDuration($0) }

        let viewCountText = (r["viewCountText"] as? [String: Any]).flatMap { extractText($0) }
        let viewCount = viewCountText.flatMap { extractNumber($0) }

        let isLive = (r["badges"] as? [[String: Any]])?.contains {
            (($0["metadataBadgeRenderer"] as? [String: Any])?["style"] as? String) == "BADGE_STYLE_TYPE_LIVE_NOW"
        } ?? false

        let isShort: Bool = {
            guard let nav = r["navigationEndpoint"] as? [String: Any] else { return false }
            return nav["reelWatchEndpoint"] != nil
        }()

        let badges = (r["badges"] as? [[String: Any]])?.compactMap {
            ($0["metadataBadgeRenderer"] as? [String: Any])?["label"] as? String
        } ?? []

        return Video(
            id: videoId,
            title: title,
            channelTitle: channelTitle,
            channelId: channelId,
            thumbnailURL: thumbURL,
            duration: duration,
            viewCount: viewCount,
            isLive: isLive,
            isShort: isShort,
            badges: badges
        )
    }

    private func parseChannel(from json: [String: Any], channelId: String) throws -> (Channel, VideoGroup) {
        let header = (json["header"] as? [String: Any])?["c4TabbedHeaderRenderer"] as? [String: Any]
        let title = header.flatMap { $0["title"] as? String } ?? ""
        let description = header
            .flatMap { $0["description"] as? [String: Any] }
            .flatMap { extractText($0) }
        let thumbURL = ((header?["avatar"] as? [String: Any])?["thumbnails"] as? [[String: Any]])?
            .last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }
        let subscribers = header.flatMap { $0["subscriberCountText"] as? [String: Any] }.flatMap { extractText($0) }

        let channel = Channel(
            id: channelId,
            title: title,
            description: description,
            thumbnailURL: thumbURL,
            subscriberCount: subscribers
        )
        let videoGroup = try parseVideoGroup(from: json, title: title)
        return (channel, videoGroup)
    }

    private func parsePlayerInfo(from json: [String: Any], videoId: String) throws -> PlayerInfo {
        let videoDetails = json["videoDetails"] as? [String: Any]
        let title = videoDetails?["title"] as? String ?? ""
        let channelTitle = videoDetails?["author"] as? String ?? ""
        let description = videoDetails?["shortDescription"] as? String
        let durationStr = videoDetails?["lengthSeconds"] as? String
        let duration = durationStr.flatMap { Double($0) }
        let isLive = videoDetails?["isLiveContent"] as? Bool ?? false
        let viewCount = (videoDetails?["viewCount"] as? String).flatMap { Int($0) }
        let thumbURL = ((videoDetails?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]])?
            .last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }

        // Stream formats
        let streamingData = json["streamingData"] as? [String: Any]
        let playabilityStatus = (json["playabilityStatus"] as? [String: Any])?["status"] as? String ?? "unknown"
        tubeLog.notice("parsePlayerInfo id=\(videoId, privacy: .public) playability=\(playabilityStatus, privacy: .public) hasStreamingData=\(streamingData != nil, privacy: .public)")
        var formats: [VideoFormat] = []

        func parseFormats(_ raw: [[String: Any]]) -> [VideoFormat] {
            raw.compactMap { f -> VideoFormat? in
                guard f["itag"] is Int else { return nil }
                let urlStr = f["url"] as? String
                let hasCipher = f["signatureCipher"] != nil || f["cipher"] != nil
                let url = urlStr.flatMap { URL(string: $0) }
                let quality = f["qualityLabel"] as? String ?? f["quality"] as? String ?? "unknown"
                let mimeType = f["mimeType"] as? String ?? ""
                let width = f["width"] as? Int ?? 0
                let height = f["height"] as? Int ?? 0
                let fps = f["fps"] as? Int ?? 30
                let bitrate = f["bitrate"] as? Int
                tubeLog.notice("  fmt itag=\(f["itag"] as? Int ?? 0, privacy: .public) quality=\(quality, privacy: .public) hasURL=\(url != nil, privacy: .public) hasCipher=\(hasCipher, privacy: .public) mime=\(mimeType.prefix(40), privacy: .public)")
                return VideoFormat(label: quality, width: width, height: height, fps: fps, mimeType: mimeType, url: url, bitrate: bitrate)
            }
        }

        if let f = streamingData?["formats"] as? [[String: Any]] {
            formats += parseFormats(f)
        }
        if let f = streamingData?["adaptiveFormats"] as? [[String: Any]] {
            formats += parseFormats(f)
        }

        let hlsURL = (streamingData?["hlsManifestUrl"] as? String).flatMap { URL(string: $0) }
        let dashURL = (streamingData?["dashManifestUrl"] as? String).flatMap { URL(string: $0) }

        let video = Video(
            id: videoId,
            title: title,
            channelTitle: channelTitle,
            description: description,
            thumbnailURL: thumbURL,
            duration: duration,
            viewCount: viewCount,
            isLive: isLive
        )

        return PlayerInfo(video: video, formats: formats, hlsURL: hlsURL, dashURL: dashURL)
    }

    private func parsePlaylists(from json: [String: Any]) throws -> [PlaylistInfo] {
        var playlists: [PlaylistInfo] = []

        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                if let renderer = dict["playlistRenderer"] as? [String: Any],
                   let id = renderer["playlistId"] as? String,
                   let title = (renderer["title"] as? [String: Any]).flatMap({ extractText($0) }) {
                    let thumbURL = ((renderer["thumbnails"] as? [[String: Any]])?.first?["thumbnails"] as? [[String: Any]])?
                        .last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }
                    let count = (renderer["videoCount"] as? String).flatMap { Int($0) }
                    playlists.append(PlaylistInfo(id: id, title: title, videoCount: count, thumbnailURL: thumbURL))
                } else {
                    for value in dict.values { walk(value) }
                }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item) }
            }
        }

        walk(json)
        return playlists
    }

    // MARK: - Text extraction helpers

    private func extractText(_ dict: [String: Any]) -> String? {
        if let simple = dict["simpleText"] as? String { return simple }
        if let runs = dict["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }

    private func parseDuration(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return TimeInterval(parts[0] * 60 + parts[1])
        case 3: return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
        default: return nil
        }
    }

    private func extractNumber(_ text: String) -> Int? {
        let digits = text.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int(digits)
    }
}

// MARK: - PlayerInfo

public struct PlayerInfo {
    public let video: Video
    public let formats: [VideoFormat]
    public let hlsURL: URL?
    public let dashURL: URL?

    /// The best stream URL to hand to AVPlayer.
    /// Prefers HLS (works natively in AVPlayer on iOS, handles adaptive quality).
    /// Falls back to combined muxed mp4 for non-HLS responses.
    public var preferredStreamURL: URL? {
        // HLS is the most reliable for AVPlayer — adaptive, no header restrictions
        if let hls = hlsURL { return hls }
        // Combined (muxed) video+audio MP4 as fallback
        let combined = formats.filter { $0.mimeType.contains("video/mp4") && $0.mimeType.contains("codecs=") }
        return combined.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }.first?.url
    }
}

// MARK: - APIError

public enum APIError: LocalizedError {
    case httpError(Int)
    case decodingError(String)
    case notAuthenticated

    public var errorDescription: String? {
        switch self {
        case .httpError(let code):   return "HTTP error \(code)"
        case .decodingError(let msg): return "Decoding error: \(msg)"
        case .notAuthenticated:       return "You are not signed in"
        }
    }
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
