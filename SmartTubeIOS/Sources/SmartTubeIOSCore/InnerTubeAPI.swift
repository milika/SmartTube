import Foundation
import os
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let tubeLog = Logger(subsystem: appSubsystem, category: "InnerTube")

// MARK: - LikeStatus

/// The user's current like state for a video.
public enum LikeStatus: Sendable {
    case like
    case dislike
    case none
}

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
            "clientName": InnerTubeClients.Web.name,
            "clientVersion": InnerTubeClients.Web.version,
        ]
    ]

    /// The iOS client context used for stream URL retrieval.
    /// Returns c=iOS URLs and an HLS manifest, both playable natively by AVPlayer.
    private let iosClientContext: [String: Any] = [
        "client": [
            "hl": "en",
            "gl": "US",
            "clientName": InnerTubeClients.iOS.name,
            "clientVersion": InnerTubeClients.iOS.version,
            "deviceMake": "Apple",
            "deviceModel": "iPhone10,4",
            "osName": "iOS",
            "osVersion": "16.7.7.20H330",
            "clientScreen": "WATCH",
        ]
    ]
    private let iosUserAgent = InnerTubeClients.iOS.userAgent

    /// The Android client context used for download URL retrieval.
    /// Exact params match yt-dlp's android client to avoid HTTP 400.
    private let androidClientContext: [String: Any] = [
        "client": [
            "hl": "en",
            "gl": "US",
            "clientName": InnerTubeClients.Android.name,
            "clientVersion": InnerTubeClients.Android.version,
            "androidSdkVersion": InnerTubeClients.Android.androidSdkVersion,
            "osName": "Android",
            "osVersion": "11",
        ]
    ]

    /// The TVHTML5 client context required for all authenticated InnerTube requests
    /// (subscriptions, history, playlists, personalised home).
    /// The OAuth token issued by the TV device-code flow is bound to this client.
    /// The WEB client on www.youtube.com rejects Bearer tokens and returns 400.
    private let tvClientContext: [String: Any] = [
        "client": [
            "hl": "en",
            "gl": "US",
            "clientName": InnerTubeClients.TV.name,
            "clientVersion": InnerTubeClients.TV.version,
        ]
    ]

    private let baseURL = URL(string: "https://www.youtube.com/youtubei/v1")!
    private let playerBaseURL = URL(string: "https://youtubei.googleapis.com/youtubei/v1")!
    // Public InnerTube API key embedded in YouTube's own web client JS — not a developer secret.
    // nosec: false positive — this key is published by Google in youtube.com/s/player JS.
    // Used only for unauthenticated requests (aligned to Android RetrofitOkHttpHelper pattern).
    private let apiKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8" // gitleaks:allow
    // Note: TV key (AIzaSyDCU8...) is defined in Android as API_KEY_OLD and never used.

    public init(authToken: String? = nil) {
        self.session = URLSession(configuration: .default)
        self.authToken = authToken
    }

    // MARK: - Auth

    public func setAuthToken(_ token: String?) {
        let msg = token != nil ? "token(\(token!.prefix(8))…)" : "nil"
        tubeLog.notice("setAuthToken: \(msg, privacy: .public)")

        self.authToken = token
    }

    // MARK: - Browse

    /// Fetches the home feed.
    /// When authenticated, uses TVHTML5 on youtubei.googleapis.com for a personalised feed.
    /// When unauthenticated, uses the WEB client on www.youtube.com for the default feed.
    public func fetchHome(continuationToken: String? = nil) async throws -> VideoGroup {
        let isAuth = authToken != nil
        var body = makeBody(client: isAuth ? tvClientContext : webClientContext,
                            continuationToken: continuationToken)
        if continuationToken == nil {
            body["browseId"] = "FEwhat_to_watch"
        }
        let data = isAuth
            ? try await postTV(endpoint: "browse", body: body)
            : try await post(endpoint: "browse", body: body)
        return try parseVideoGroup(from: data, title: BrowseSection.SectionType.home.defaultTitle)
    }

    /// Fetches subscriptions feed (requires auth).
    /// Uses TVHTML5 client on youtubei.googleapis.com — the only endpoint that accepts
    /// the OAuth token issued by the TV device-code flow.
    public func fetchSubscriptions(continuationToken: String? = nil) async throws -> VideoGroup {
        var body = makeBody(client: tvClientContext, continuationToken: continuationToken)
        if continuationToken == nil {
            body["browseId"] = "FEsubscriptions"
        }
        let data = try await postTV(endpoint: "browse", body: body)
        return try parseVideoGroup(from: data, title: "Subscriptions")
    }

    /// Fetches the list of channels the authenticated user subscribes to (requires auth).
    ///
    /// Strategy:
    ///  1. TV client `FEsubscriptions` + `params:"EgIQAQ=="` — the "Channels" tab —
    ///     returns channelRenderer items with avatar thumbnails and subscriber counts.
    ///     The WEB client cannot be used here: our Bearer token is TV-device-code scoped
    ///     and is rejected by the WEB endpoint (www.youtube.com), causing an anonymous
    ///     response that contains no user-specific data.
    ///  2. If that yields no channels, fall back to parsing unique channels from the default
    ///     TVHTML5 video-tile subscription feed (channel IDs + names, no avatars).
    public func fetchSubscribedChannels() async throws -> [Channel] {
        // Primary: TV client channels tab (authenticated, so our Bearer token is accepted)
        var tvChBody = makeBody(client: tvClientContext)
        tvChBody["browseId"] = "FEsubscriptions"
        tvChBody["params"] = "EgIQAQ=="
        let tvChData = try await postTV(endpoint: "browse", body: tvChBody)
        let topKeys = Array(tvChData.keys.sorted().prefix(8))
        tubeLog.notice("fetchSubscribedChannels TV+params top-level keys: \(topKeys, privacy: .public)")
        let tvChChannels = parseChannelRenderers(from: tvChData)
        tubeLog.notice("fetchSubscribedChannels TV+params → \(tvChChannels.count, privacy: .public) channels")
        if !tvChChannels.isEmpty { return tvChChannels }

        // Fallback: TV subscription video-tile feed — extract unique channels (no avatars)
        tubeLog.notice("fetchSubscribedChannels: TV+params returned 0 — falling back to video tile parse")
        var tvBody = makeBody(client: tvClientContext)
        tvBody["browseId"] = "FEsubscriptions"
        let tvData = try await postTV(endpoint: "browse", body: tvBody)
        return parseSubscribedChannels(from: tvData)
    }

    /// Fetches watch history (requires auth).
    /// Uses TVHTML5 client on youtubei.googleapis.com.
    public func fetchHistory(continuationToken: String? = nil) async throws -> VideoGroup {
        var body = makeBody(client: tvClientContext, continuationToken: continuationToken)
        if continuationToken == nil {
            body["browseId"] = "FEhistory"
        }
        let data = try await postTV(endpoint: "browse", body: body)
        return try parseVideoGroup(from: data, title: "History")
    }

    // MARK: - Search

    public func search(
        query: String,
        continuationToken: String? = nil,
        filter: SearchFilter = .default
    ) async throws -> VideoGroup {
        var body = makeBody(client: webClientContext, continuationToken: continuationToken)
        if continuationToken == nil {
            body["query"] = query
            if let params = filter.encodedParams() {
                body["params"] = params
            }
        }
        let data = try await post(endpoint: "search", body: body)
        return try parseVideoGroup(from: data, title: "Search: \(query)")
    }

    public func fetchSearchSuggestions(query: String) async throws -> [String] {
        guard var components = URLComponents(string: "https://suggestqueries-clients6.youtube.com/complete/search") else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "client", value: "youtube"),
            URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "callback", value: ""),
        ]
        guard let url = components.url else { return [] }
        print("[Suggestions] Fetching URL: \(url)")
        let (data, response) = try await session.data(from: url)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("[Suggestions] HTTP status: \(statusCode), bytes: \(data.count)")
        // Response format: [query, [[suggestion, 0, []], ...], ...]
        guard let raw = String(data: data, encoding: .utf8) else {
            print("[Suggestions] Failed to decode response as UTF-8")
            return []
        }
        print("[Suggestions] Raw prefix: \(raw.prefix(120))")
        // Extract the outermost JSON array — works regardless of callback wrapper name
        guard let arrayStart = raw.firstIndex(of: "["),
              let arrayEnd = raw.lastIndex(of: "]") else {
            print("[Suggestions] Could not find JSON array bounds")
            return []
        }
        let jsonString = String(raw[arrayStart...arrayEnd])
        print("[Suggestions] JSON prefix after strip: \(jsonString.prefix(120))")
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [Any]
        else {
            print("[Suggestions] JSON parse failed")
            return []
        }
        guard let suggestions = json[safe: 1] as? [[Any]] else {
            print("[Suggestions] Unexpected JSON shape: \(json.prefix(2))")
            return []
        }
        let results = suggestions.compactMap { $0[safe: 0] as? String }
        print("[Suggestions] Parsed \(results.count) suggestions: \(results.prefix(5))")
        return results
    }

    // MARK: - Channel

    public func fetchChannel(channelId: String) async throws -> (channel: Channel, videos: VideoGroup) {
        // @handle strings are not valid browseIds — resolve to the real UC… channel ID first.
        let resolvedId: String
        if channelId.hasPrefix("@") {
            tubeLog.notice("fetchChannel resolving handle \(channelId, privacy: .public)")
            resolvedId = try await resolveChannelHandle(channelId)
            tubeLog.notice("fetchChannel resolved \(channelId, privacy: .public) → \(resolvedId, privacy: .public)")
        } else {
            resolvedId = channelId
        }
        var body = makeBody(client: webClientContext)
        body["browseId"] = resolvedId
        tubeLog.notice("fetchChannel browseId=\(resolvedId, privacy: .public)")
        let data = try await post(endpoint: "browse", body: body)
        return try parseChannel(from: data, channelId: resolvedId)
    }

    /// Resolves a YouTube `@handle` to the canonical `UC…` channel ID using the
    /// InnerTube `navigation/resolve_url` endpoint.
    private func resolveChannelHandle(_ handle: String) async throws -> String {
        let handleURL = "https://www.youtube.com/\(handle)"
        var body = makeBody(client: webClientContext)
        body["url"] = handleURL
        tubeLog.notice("resolveChannelHandle url=\(handleURL, privacy: .public)")
        let data = try await post(endpoint: "navigation/resolve_url", body: body)
        // Response shape: { "endpoint": { "browseEndpoint": { "browseId": "UCxxx" } } }
        let endpoint = data["endpoint"] as? [String: Any]
        if let browseId = (endpoint?["browseEndpoint"] as? [String: Any])?["browseId"] as? String {
            return browseId
        }
        let topKeys = data.keys.joined(separator: ", ")
        tubeLog.error("resolveChannelHandle: unexpected response keys=[\(topKeys, privacy: .public)]")
        throw APIError.decodingError("Could not resolve handle \(handle) to a channel ID")
    }

    public func fetchChannelVideos(channelId: String, continuationToken: String? = nil) async throws -> VideoGroup {
        var body = makeBody(client: webClientContext, continuationToken: continuationToken)
        if continuationToken == nil {
            body["browseId"] = channelId
            body["params"] = "EgZ2aWRlb3PyBgQKAjoA"  // "Videos" tab parameter
        }
        let videosParams = (body["params"] as? String) ?? "nil"
        tubeLog.notice("fetchChannelVideos browseId=\(channelId, privacy: .public) hasContinuation=\(continuationToken != nil, privacy: .public) params=\(videosParams, privacy: .public)")
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

    /// Fetches player info using the Web client, which returns muxed (video+audio)
    /// MP4 streams suitable for direct file download and saving to Photos.
    /// The iOS client only returns adaptive-only streams; the Web client includes
    /// itag 18 (360p muxed) and itag 22 (720p muxed) in the `formats` array.
    public func fetchPlayerInfoForDownload(videoId: String) async throws -> PlayerInfo {
        var body = makeBody(client: webClientContext)
        body["videoId"] = videoId
        body["racyCheckOk"] = true
        body["contentCheckOk"] = true
        let data = try await post(endpoint: "player", body: body)
        return try parsePlayerInfo(from: data, videoId: videoId)
    }

    /// Fetches player info using the Android client.
    /// Used as the primary download fallback: Android CDN URLs are signed with
    /// `c=ANDROID` and are reliably downloadable with a standard Android UA.
    /// Unlike TVHTML5-signed URLs, these do not require session cookies.
    public func fetchPlayerInfoAndroid(videoId: String) async throws -> PlayerInfo {
        var body = makeBody(client: androidClientContext)
        body["videoId"] = videoId
        body["racyCheckOk"] = true
        body["contentCheckOk"] = true
        let data = try await postAndroid(endpoint: "player", body: body)
        return try parsePlayerInfo(from: data, videoId: videoId)
    }

    /// Fetches player info using the authenticated TV client.
    /// Used as a fallback when the anonymous Web client returns UNPLAYABLE —
    /// membership-only, age-restricted, or subscription-paywalled videos require auth.
    public func fetchPlayerInfoAuthenticated(videoId: String) async throws -> PlayerInfo {
        var body = makeBody(client: tvClientContext)
        body["videoId"] = videoId
        body["racyCheckOk"] = true
        body["contentCheckOk"] = true
        let data = try await postTV(endpoint: "player", body: body)
        return try parsePlayerInfo(from: data, videoId: videoId)
    }

    // MARK: - Next (related videos / SuggestionsController equivalent)

    /// Fetches related/suggested videos and the current like status for a video.
    /// When authenticated, uses TVHTML5 on youtubei.googleapis.com so the Bearer
    /// token is accepted and the response includes the user's current like state.
    /// Without auth, falls back to the WEB client (like status will be .none).
    /// Mirrors Android's SuggestionsController + LikeDislikePresenter.
    public func fetchNextInfo(videoId: String) async throws -> NextInfo {
        let isAuth = authToken != nil
        var tvBody = makeBody(client: isAuth ? tvClientContext : webClientContext)
        tvBody["videoId"] = videoId

        if isAuth {
            // TV client (/next) returns like status + related but omits
            // engagementPanels (where chapters live). Make a second sequential
            // WEB /next call to extract chapters — no auth needed.
            // (async let cannot be used here: [String:Any] is not Sendable in Swift 6.)
            var webBody = makeBody(client: webClientContext)
            webBody["videoId"] = videoId
            let tvData  = try await postTV(endpoint: "next", body: tvBody)
            let webData = try await post(endpoint: "next", body: webBody)
            let videos   = parseRelatedVideos(from: tvData)
            let status   = parseLikeStatus(from: tvData)
            let chapters = parseChapters(from: webData)
            tubeLog.notice("fetchNextInfo (auth) → related=\(videos.count, privacy: .public) chapters=\(chapters.count, privacy: .public)")
            return NextInfo(relatedVideos: videos, likeStatus: status, chapters: chapters)
        } else {
            let data     = try await post(endpoint: "next", body: tvBody)
            let videos   = parseRelatedVideos(from: data)
            let chapters = parseChapters(from: data)
            tubeLog.notice("fetchNextInfo (anon) → related=\(videos.count, privacy: .public) chapters=\(chapters.count, privacy: .public)")
            return NextInfo(relatedVideos: videos, likeStatus: .none, chapters: chapters)
        }
    }

    // MARK: - Like / Dislike

    /// Sends a like for the given video (requires authentication).
    /// Mirrors Android's `LikeDislikePresenter` → `PostVideoAction.LIKE`.
    public func like(videoId: String) async throws {
        var body = makeBody(client: tvClientContext)
        body["target"] = ["videoId": videoId]
        _ = try await postTV(endpoint: "like/like", body: body)
    }

    /// Sends a dislike for the given video (requires authentication).
    /// Mirrors Android's `LikeDislikePresenter` → `PostVideoAction.DISLIKE`.
    public func dislike(videoId: String) async throws {
        var body = makeBody(client: tvClientContext)
        body["target"] = ["videoId": videoId]
        _ = try await postTV(endpoint: "like/dislike", body: body)
    }

    /// Removes any existing like or dislike for the given video (requires authentication).
    /// Mirrors Android's `LikeDislikePresenter` → `PostVideoAction.REMOVE_LIKE`.
    public func removeLike(videoId: String) async throws {
        var body = makeBody(client: tvClientContext)
        body["target"] = ["videoId": videoId]
        _ = try await postTV(endpoint: "like/removelike", body: body)
    }

    // MARK: - Home rows (TYPE_ROW layout)

    /// Fetches the home feed as multiple named shelves (TYPE_ROW in Android).
    /// Returns one VideoGroup per shelf; each has layout == .row.
    /// Falls back to a single flat VideoGroup if no shelves are found.
    public func fetchHomeRows(continuationToken: String? = nil) async throws -> [VideoGroup] {
        let isAuth = authToken != nil
        var body = makeBody(client: isAuth ? tvClientContext : webClientContext,
                            continuationToken: continuationToken)
        if continuationToken == nil {
            body["browseId"] = "FEwhat_to_watch"
        }
        let data = isAuth
            ? try await postTV(endpoint: "browse", body: body)
            : try await post(endpoint: "browse", body: body)
        let rows = parseVideoGroupRows(from: data)
        tubeLog.notice("fetchHomeRows → \(rows.count, privacy: .public) shelves")
        return rows
    }

    // MARK: - Category sections

    public func fetchShorts() async throws -> VideoGroup {
        do {
            // FEshorts requires TVHTML5 context on www.youtube.com (not googleapis.com).
            var body = makeBody(client: tvClientContext)
            body["browseId"] = "FEshorts"
            let data = try await postTVCategory(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "Shorts")
            if !group.videos.isEmpty { return group }
        } catch {
            tubeLog.notice("fetchShorts browse failed, falling back to search: \(error, privacy: .public)")
        }
        return try await search(query: "shorts")
    }

    public func fetchMusic() async throws -> VideoGroup {
        do {
            // FEmusic_home is the TVHTML5 browse ID for the music category page.
            var body = makeBody(client: tvClientContext)
            body["browseId"] = "FEmusic_home"
            let data = try await postTVCategory(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "Music")
            if !group.videos.isEmpty { return group }
        } catch {
            tubeLog.notice("fetchMusic browse failed, falling back to search: \(error, privacy: .public)")
        }
        return try await search(query: "music")
    }

    public func fetchGaming() async throws -> VideoGroup {
        do {
            // FEgaming requires TVHTML5 context on www.youtube.com (not googleapis.com).
            var body = makeBody(client: tvClientContext)
            body["browseId"] = "FEgaming"
            let data = try await postTVCategory(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "Gaming")
            if !group.videos.isEmpty { return group }
        } catch {
            tubeLog.notice("fetchGaming browse failed, falling back to search: \(error, privacy: .public)")
        }
        return try await search(query: "gaming")
    }

    public func fetchNews() async throws -> VideoGroup {
        // FEnews is not a valid InnerTube browse ID — use search directly.
        return try await search(query: "news today")
    }

    public func fetchLive() async throws -> VideoGroup {
        do {
            var body = makeBody(client: tvClientContext)
            body["browseId"] = "FElive_home"
            let data = try await postTVCategory(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "Live")
            if !group.videos.isEmpty { return group }
        } catch {
            tubeLog.notice("fetchLive browse failed, falling back to search: \(error, privacy: .public)")
        }
        return try await search(query: "live stream")
    }

    public func fetchSports() async throws -> VideoGroup {
        do {
            // FEsportsau is the known TVHTML5 browse ID for the sports category.
            var body = makeBody(client: tvClientContext)
            body["browseId"] = "FEsportsau"
            let data = try await postTVCategory(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "Sports")
            if !group.videos.isEmpty { return group }
        } catch {
            tubeLog.notice("fetchSports browse failed, falling back to search: \(error, privacy: .public)")
        }
        return try await search(query: "sports")
    }

    // MARK: - Playlists

    public func fetchUserPlaylists() async throws -> [PlaylistInfo] {
        var body = makeBody(client: tvClientContext)
        body["browseId"] = "FElibrary"
        let data = try await postTV(endpoint: "browse", body: body)
        // Log the second-level structure so it's easy to diagnose mismatches
        // if the live response shape differs from the mock.
        let contentsKeys = (data["contents"] as? [String: Any])?.keys.map { $0 } ?? []
        tubeLog.notice("fetchUserPlaylists FElibrary contents keys: \(contentsKeys, privacy: .public)")
        return try parsePlaylists(from: data)
    }

    public func fetchPlaylistVideos(playlistId: String, continuationToken: String? = nil) async throws -> VideoGroup {
        let isAuth = authToken != nil
        var body = makeBody(client: isAuth ? tvClientContext : webClientContext,
                            continuationToken: continuationToken)
        if continuationToken == nil {
            body["browseId"] = "VL\(playlistId)"
        }
        let data = isAuth
            ? try await postTV(endpoint: "browse", body: body)
            : try await post(endpoint: "browse", body: body)
        return try parseVideoGroup(from: data, title: nil)
    }

    // MARK: - Networking

    /// Player requests use the Android client UA, googleapis.com base, and no auth header.
    private func postPlayer(body: [String: Any]) async throws -> [String: Any] {
        guard var comps = URLComponents(url: playerBaseURL.appendingPathComponent("player"), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL("player")
        }
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = comps.url else { throw APIError.invalidURL("player") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(iosUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(InnerTubeClients.iOS.nameID, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(InnerTubeClients.iOS.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let playerVideoId = body["videoId"] as? String ?? ""
        tubeLog.notice("POST /player (iOS) videoId=\(playerVideoId, privacy: .public)")
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

    /// Android client player request — used for download URL resolution.
    /// Android client headers use googleapis.com like iOS, but with Android UA/client IDs.
    private func postAndroid(endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        guard var comps = URLComponents(url: playerBaseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL(endpoint)
        }
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = comps.url else { throw APIError.invalidURL(endpoint) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(InnerTubeClients.Android.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(InnerTubeClients.Android.nameID, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(InnerTubeClients.Android.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let videoId = body["videoId"] as? String ?? ""
        tubeLog.notice("POST /\(endpoint, privacy: .public) [Android] videoId=\(videoId, privacy: .public)")
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            tubeLog.error("❌ HTTP \(statusCode, privacy: .public) for /\(endpoint, privacy: .public) [Android]")
            throw APIError.httpError(statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            tubeLog.error("❌ Non-dictionary JSON root for /\(endpoint, privacy: .public) [Android]")
            throw APIError.decodingError("Root JSON is not a dictionary")
        }
        if let error = json["error"] as? [String: Any] {
            tubeLog.error("❌ API error in /\(endpoint, privacy: .public) [Android]: \(String(describing: error["message"] ?? error), privacy: .public)")
        } else {
            let topKeys = Array(json.keys.prefix(6))
            tubeLog.notice("✅ /\(endpoint, privacy: .public) [Android] HTTP \(statusCode, privacy: .public) keys: \(topKeys, privacy: .public)")
        }
        return json
    }

    private func post(endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL(endpoint)
        }
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = comps.url else { throw APIError.invalidURL(endpoint) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(InnerTubeClients.Web.nameID, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(InnerTubeClients.Web.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        tubeLog.notice("POST /\(endpoint, privacy: .public) [WEB]")
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

    /// Unauthenticated TVHTML5 browse on www.youtube.com.
    /// FE* category browse IDs (FEgaming, FEshorts, FEmusic, …) require the TVHTML5
    /// client format but return 400 on youtubei.googleapis.com without a valid auth token.
    /// Posting to www.youtube.com with TV client headers resolves this.
    private func postTVCategory(endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(endpoint),
                                        resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL(endpoint)
        }
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = comps.url else { throw APIError.invalidURL(endpoint) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(InnerTubeClients.TV.nameID, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(InnerTubeClients.TV.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        tubeLog.notice("POST /\(endpoint, privacy: .public) [TV-category]")
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            tubeLog.error("❌ HTTP \(statusCode, privacy: .public) for /\(endpoint, privacy: .public) [TV-category]")
            throw APIError.httpError(statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            tubeLog.error("❌ Non-dictionary JSON root for /\(endpoint, privacy: .public) [TV-category]")
            throw APIError.decodingError("Root JSON is not a dictionary")
        }
        if let error = json["error"] as? [String: Any] {
            tubeLog.error("❌ API error in /\(endpoint, privacy: .public) [TV-category]: \(String(describing: error["message"] ?? error), privacy: .public)")
        } else {
            let topKeys = Array(json.keys.prefix(6))
            tubeLog.notice("✅ /\(endpoint, privacy: .public) [TV-category] HTTP \(statusCode, privacy: .public) keys: \(topKeys, privacy: .public)")
        }
        return json
    }

    /// Authenticated InnerTube endpoint — TVHTML5 client on youtubei.googleapis.com.
    /// Required for subscriptions, history, playlists, and personalised home: the OAuth
    /// token issued by the TV device-code flow is matched to this client. The WEB client
    /// on www.youtube.com rejects Bearer tokens (returns 400).
    ///
    /// Android alignment: when Bearer token is present, no ?key= param is sent
    /// (mirrors RetrofitOkHttpHelper — authHeaders non-empty → skip key, apply Bearer headers).
    /// When unauthenticated, the WEB key is used as on all other clients.
    private func postTV(endpoint: String, body: [String: Any], useAuth: Bool = true) async throws -> [String: Any] {
        guard var comps = URLComponents(url: playerBaseURL.appendingPathComponent(endpoint),
                                        resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL(endpoint)
        }
        // Android: no ?key= when Bearer present; WEB key for unauthenticated
        let shouldAuthenticate = useAuth && authToken != nil
        if !shouldAuthenticate {
            comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        }
        guard let url = comps.url else { throw APIError.invalidURL(endpoint) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(InnerTubeClients.TV.nameID, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(InnerTubeClients.TV.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        if shouldAuthenticate, let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let authLabel = authToken != nil ? "yes" : "no"
        tubeLog.notice("POST /\(endpoint, privacy: .public) [TV] auth=\(authLabel, privacy: .public)")
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            tubeLog.error("\u{274C} HTTP \(statusCode, privacy: .public) for /\(endpoint, privacy: .public) [TV]")
            throw APIError.httpError(statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            tubeLog.error("\u{274C} Non-dictionary JSON root for /\(endpoint, privacy: .public) [TV]")
            throw APIError.decodingError("Root JSON is not a dictionary")
        }
        if let error = json["error"] as? [String: Any] {
            tubeLog.error("\u{274C} API error in /\(endpoint, privacy: .public) [TV]: \(String(describing: error["message"] ?? error), privacy: .public)")
        } else {
            let topKeys = Array(json.keys.prefix(6))
            tubeLog.notice("\u{2705} /\(endpoint, privacy: .public) [TV] HTTP \(statusCode, privacy: .public) keys: \(topKeys, privacy: .public)")
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

    /// Internal accessor so unit tests can exercise the playlist parser without a live network.
    func parsePlaylistsForTesting(_ json: [String: Any]) throws -> [PlaylistInfo] {
        try parsePlaylists(from: json)
    }

    // MARK: - Multi-shelf home row parser

    /// Walks the JSON looking for `richShelfRenderer` sections (YouTube home feed).
    /// Each shelf becomes a VideoGroup with layout == .row.
    /// If no shelves are found, falls back to the flat parser.
    private func parseVideoGroupRows(from json: [String: Any]) -> [VideoGroup] {
        var rows: [VideoGroup] = []
        var continuationToken: String? = nil

        // Renderer keys that are known ad/promoted slots — skip silently.
        let adRendererKeys: Set<String> = [
            "adSlotRenderer", "adRenderer", "promotedSparklesVideoRenderer",
            "promotedVideoRenderer", "adBreakServiceRenderer",
            "movingThumbnailRenderer",
        ]

        func dumpJSON(_ obj: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                  let str = String(data: data, encoding: .utf8) else { return "<unserializable>" }
            // Truncate to avoid flooding the log
            return str.count > 2000 ? String(str.prefix(2000)) + "\n...(truncated)" : str
        }

        func walkShelfContents(_ obj: Any) -> [Video] {
            var videos: [Video] = []
            if let dict = obj as? [String: Any] {
                if let vr = dict["videoRenderer"] as? [String: Any], let v = parseVideoRenderer(vr) {
                    videos.append(v)
                } else if let ri = dict["richItemRenderer"] as? [String: Any],
                          let content = ri["content"] as? [String: Any] {
                    if let vr = content["videoRenderer"] as? [String: Any],
                       let v = parseVideoRenderer(vr) {
                        videos.append(v)
                    } else {
                        let contentKeys = content.keys.sorted()
                        let isAd = contentKeys.contains(where: { adRendererKeys.contains($0) })
                        if isAd {
                            tubeLog.debug("walkShelfContents: skipping ad richItemRenderer keys=\(contentKeys, privacy: .public)")
                        } else {
                            tubeLog.notice("walkShelfContents: unrecognised richItemRenderer — add key to adRendererKeys if it is an ad\nkeys=\(contentKeys, privacy: .public)\nJSON=\(dumpJSON(content), privacy: .public)")
                            for value in content.values { videos += walkShelfContents(value) }
                        }
                    }
                } else {
                    let dictKeys = dict.keys.sorted()
                    let isAd = dictKeys.contains(where: { adRendererKeys.contains($0) })
                    if isAd {
                        tubeLog.debug("walkShelfContents: skipping ad renderer keys=\(dictKeys, privacy: .public)")
                    } else {
                        for value in dict.values { videos += walkShelfContents(value) }
                    }
                }
            } else if let arr = obj as? [Any] {
                for item in arr { videos += walkShelfContents(item) }
            }
            return videos
        }

        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                if let shelf = dict["richShelfRenderer"] as? [String: Any] {
                    let title = (shelf["title"] as? [String: Any]).flatMap { extractText($0) }
                    let videos = walkShelfContents(shelf["contents"] as Any)
                    if !videos.isEmpty {
                        rows.append(VideoGroup(title: title, videos: videos, layout: .row))
                    }
                    return
                }
                if let contItem = dict["continuationItemRenderer"] as? [String: Any],
                   let contEndpoint = contItem["continuationEndpoint"] as? [String: Any],
                   let contCmd = contEndpoint["continuationCommand"] as? [String: Any],
                   let ct = contCmd["token"] as? String {
                    continuationToken = ct
                    return
                }
                // Log any richSectionRenderer whose inner content is not a richShelfRenderer
                // (ads and promos often appear as richSectionRenderer wrapping a non-shelf renderer)
                if let section = dict["richSectionRenderer"] as? [String: Any],
                   let content = section["content"] as? [String: Any] {
                    let contentKeys = content.keys.sorted()
                    let isAd = contentKeys.contains(where: { adRendererKeys.contains($0) })
                    if isAd {
                        tubeLog.debug("walk: skipping ad richSectionRenderer content keys=\(contentKeys, privacy: .public)")
                    } else if !contentKeys.contains("richShelfRenderer") {
                        tubeLog.notice("walk: unrecognised richSectionRenderer — add key to adRendererKeys if it is an ad\nkeys=\(contentKeys, privacy: .public)\nJSON=\(dumpJSON(content), privacy: .public)")
                        for value in dict.values { walk(value) }
                    } else {
                        for value in dict.values { walk(value) }
                    }
                    return
                }
                for value in dict.values { walk(value) }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item) }
            }
        }

        walk(json)

        if rows.isEmpty {
            // No shelves found — fall back to flat parse
            if let flat = try? parseVideoGroup(from: json, title: BrowseSection.SectionType.home.defaultTitle) {
                return [flat]
            }
        } else if let token = continuationToken {
            // Attach continuation to the last row so BrowseViewModel can paginate
            rows[rows.count - 1].nextPageToken = token
        }

        return rows
    }

    // MARK: - Related videos parser (/next endpoint)

    /// Parses the user's current like/dislike state from a `/next` response.
    ///
    /// Handles two layouts:
    /// - WEB client: `videoPrimaryInfoRenderer.likeStatus` → string "LIKE" / "DISLIKE" / "INDIFFERENT"
    /// - TV/WEB client: `segmentedLikeDislikeButtonRenderer.{like,dislike}Button.toggleButtonRenderer.isToggled`
    private func parseLikeStatus(from json: [String: Any]) -> LikeStatus {
        var found: LikeStatus? = nil
        func walk(_ obj: Any) {
            guard found == nil else { return }
            if let dict = obj as? [String: Any] {
                // Strategy 1: direct likeStatus string (videoPrimaryInfoRenderer on WEB)
                if let statusStr = dict["likeStatus"] as? String {
                    switch statusStr {
                    case "LIKE":    found = .like
                    case "DISLIKE": found = .dislike
                    default:        found = .none
                    }
                    return
                }
                // Strategy 2: segmentedLikeDislikeButtonRenderer (WEB + TV clients)
                if let seg = dict["segmentedLikeDislikeButtonRenderer"] as? [String: Any] {
                    let liked = (seg["likeButton"] as? [String: Any])
                        .flatMap { $0["toggleButtonRenderer"] as? [String: Any] }
                        .flatMap { $0["isToggled"] as? Bool } ?? false
                    let disliked = (seg["dislikeButton"] as? [String: Any])
                        .flatMap { $0["toggleButtonRenderer"] as? [String: Any] }
                        .flatMap { $0["isToggled"] as? Bool } ?? false
                    found = liked ? .like : disliked ? .dislike : .none
                    return
                }
                for value in dict.values { walk(value) }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item) }
            }
        }
        walk(json)
        tubeLog.notice("parseLikeStatus → \(String(describing: found ?? .none), privacy: .public)")
        return found ?? .none
    }

    /// Parses related / suggested videos from a `/next` response.
    /// Related videos appear as `compactVideoRenderer` in `secondaryResults`.
    private func parseRelatedVideos(from json: [String: Any]) -> [Video] {
        var videos: [Video] = []
        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                if let r = dict["compactVideoRenderer"] as? [String: Any],
                   let v = parseVideoRenderer(r) {
                    videos.append(v)
                } else {
                    for value in dict.values { walk(value) }
                }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item) }
            }
        }
        walk(json)
        return Array(videos.prefix(25))
    }

    /// Parses video chapters from a `/next` response.
    /// Chapters live in `engagementPanels[].engagementPanelSectionListRenderer
    ///   .content.macroMarkersListRenderer.contents[].macroMarkersListItemRenderer`.
    /// Each item carries a `title` text object and either
    ///   - `onTap.watchEndpoint.startTimeSeconds` (Int) — preferred, or
    ///   - `timeDescription` text object — fallback (parsed via `parseDuration`).
    private func parseChapters(from json: [String: Any]) -> [Chapter] {
        var chapters: [Chapter] = []
        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                if let renderer = dict["macroMarkersListItemRenderer"] as? [String: Any] {
                    let title = (renderer["title"] as? [String: Any]).flatMap { extractText($0) } ?? ""
                    // startTimeSeconds arrives as Int, Double, or NSNumber depending on
                    // how JSONSerialization bridges the JSON number — handle all three.
                    let startTime: TimeInterval? = {
                        if let watchEndpoint = (renderer["onTap"] as? [String: Any])
                            .flatMap({ $0["watchEndpoint"] as? [String: Any] }) {
                            let raw = watchEndpoint["startTimeSeconds"]
                            if let n = raw as? Int    { return TimeInterval(n) }
                            if let n = raw as? Double { return n }
                            if let n = raw as? NSNumber { return n.doubleValue }
                            if let s = raw as? String { return TimeInterval(s) }
                        }
                        // Fallback: parse the visible time description (e.g. "1:23")
                        return (renderer["timeDescription"] as? [String: Any])
                            .flatMap { extractText($0) }
                            .flatMap { parseDuration($0) }
                    }()
                    if let t = startTime {
                        chapters.append(Chapter(title: title, startTime: t))
                    }
                    return
                }
                for value in dict.values { walk(value) }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item) }
            }
        }
        walk(json)
        return chapters.sorted { $0.startTime < $1.startTime }
    }

    private func parseVideoGroup(from json: [String: Any], title: String?) throws -> VideoGroup {
        var videos: [Video] = []
        var nextPageToken: String? = nil

        // Walk the renderer tree to find videoRenderers and continuationItemRenderers.
        // Handles WEB (videoRenderer, richItemRenderer, compactVideoRenderer),
        // WEB grid (gridVideoRenderer), and TVHTML5 tileRenderer (subs/history/home on TV client).
        // Matches Android MediaServiceCore ItemWrapper renderer dispatch order.
        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                // TVHTML5 gridRenderer stores its continuation in
                // gridRenderer.continuations[0].nextContinuationData.continuation.
                // Check this independently of the renderer dispatch below so we still
                // recurse into gridRenderer.items to collect the video tiles.
                if let continuations = dict["continuations"] as? [[String: Any]],
                   let token = continuations.first
                       .flatMap({ $0["nextContinuationData"] as? [String: Any] })
                       .flatMap({ $0["continuation"] as? String }) {
                    nextPageToken = token
                }

                if let renderer = dict["tileRenderer"] as? [String: Any] {
                    // TVHTML5 client (subs, history, home) — Android ItemWrapper.tileRenderer
                    if let v = parseTileRenderer(renderer) { videos.append(v) }
                } else if let renderer = dict["videoRenderer"] as? [String: Any] {
                    if let v = parseVideoRenderer(renderer) { videos.append(v) }
                } else if let renderer = dict["gridVideoRenderer"] as? [String: Any] {
                    if let v = parseVideoRenderer(renderer) { videos.append(v) }
                } else if let renderer = dict["reelItemRenderer"] as? [String: Any] {
                    if let v = parseReelItemRenderer(renderer) { videos.append(v) }
                } else if let renderer = dict["richItemRenderer"] as? [String: Any],
                          let content = renderer["content"] as? [String: Any] {
                    if let videoRenderer = content["videoRenderer"] as? [String: Any] {
                        if let v = parseVideoRenderer(videoRenderer) { videos.append(v) }
                    } else if let reelRenderer = content["reelItemRenderer"] as? [String: Any] {
                        if let v = parseReelItemRenderer(reelRenderer) { videos.append(v) }
                    } else {
                        for value in content.values { walk(value) }
                    }
                } else if let renderer = dict["compactVideoRenderer"] as? [String: Any] {
                    if let v = parseVideoRenderer(renderer) { videos.append(v) }
                } else if let renderer = dict["playlistVideoRenderer"] as? [String: Any] {
                    // WEB browse response for VL<playlistId> — playlist video items
                    if let v = parseVideoRenderer(renderer) { videos.append(v) }
                } else if let renderer = dict["lockupViewModel"] as? [String: Any] {
                    // WEB home v2 (LockupItem in Android) — lockupViewModel
                    if let v = parseLockupViewModel(renderer) { videos.append(v) }
                } else if let contItem = dict["continuationItemRenderer"] as? [String: Any],
                          let endpoint = contItem["continuationEndpoint"] as? [String: Any],
                          let command = endpoint["continuationCommand"] as? [String: Any],
                          let token = command["token"] as? String {
                    nextPageToken = token
                } else {
                    for value in dict.values { walk(value) }
                }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item) }
            }
        }

        walk(json)
        let shortsCount = videos.filter { $0.isShort }.count
        tubeLog.notice("parseVideoGroup '\(title ?? "nil", privacy: .public)' → \(videos.count, privacy: .public) videos (\(videos.count - shortsCount, privacy: .public) regular, \(shortsCount, privacy: .public) shorts), nextPage=\(nextPageToken != nil ? "yes" : "no", privacy: .public)")
        return VideoGroup(title: title, videos: videos, nextPageToken: nextPageToken)
    }

    // MARK: – TVHTML5 tileRenderer parser (Android TileItem methodology)
    // Mirrors: TileItem.getVideoId(), getTitle(), getThumbnails(), getBadgeText(), getChannelId()
    private func parseTileRenderer(_ tile: [String: Any]) -> Video? {
        // Only parse video tiles — require the content type to be explicitly set.
        // Tiles with nil or non-video contentType (e.g. ads with customData/onFirstVisibleCommand)
        // are silently dropped. Android: TILE_CONTENT_TYPE_VIDEO
        guard (tile["contentType"] as? String) == "TILE_CONTENT_TYPE_VIDEO" else { return nil }

        // Newer TVHTML5 history/subs responses sometimes nest it under innertubeCommand, or use
        // navigationEndpoint instead of onSelectCommand — try all three paths so regular history
        // videos are not silently dropped (leaving only reelItemRenderer Shorts visible).
        let onSelectCommand = tile["onSelectCommand"] as? [String: Any]
        let navigationEndpoint = tile["navigationEndpoint"] as? [String: Any]
        // videoId resolution order (most to least common in TVHTML5 history/subs responses):
        // 1. onSelectCommand.watchEndpoint.videoId              — classic path
        // 2. onSelectCommand.innertubeCommand.watchEndpoint.videoId — newer TV variant
        // 3. navigationEndpoint.watchEndpoint.videoId           — another TV variant
        // 4. tile.contentId                                     — confirmed by live log: TVHTML5
        //    history tiles with commandExecutorCommand store the id directly here
        let watchEndpoint: [String: Any]? = {
            if let ep = onSelectCommand?["watchEndpoint"] as? [String: Any] { return ep }
            if let inner = onSelectCommand?["innertubeCommand"] as? [String: Any],
               let ep = inner["watchEndpoint"] as? [String: Any] { return ep }
            if let ep = navigationEndpoint?["watchEndpoint"] as? [String: Any] { return ep }
            return nil
        }()
        guard let videoId = watchEndpoint?["videoId"] as? String ?? (tile["contentId"] as? String) else {
            return nil
        }

        // title: metadata.tileMetadataRenderer.title — Android: TileItem.getTitle()
        let tileMetadata = (tile["metadata"] as? [String: Any])?["tileMetadataRenderer"] as? [String: Any]
        let title = (tileMetadata?["title"] as? [String: Any]).flatMap { extractText($0) } ?? ""

        // channelTitle: first line of tileMetadataRenderer.lines[0].lineRenderer.items[0].lineItemRenderer.text
        // Android TileItem.getUserName() = null, but we attempt best-effort extraction from lines
        let channelTitle: String = {
            guard let lines = tileMetadata?["lines"] as? [[String: Any]],
                  let firstLine = lines.first,
                  let lineRenderer = firstLine["lineRenderer"] as? [String: Any],
                  let items = lineRenderer["items"] as? [[String: Any]],
                  let firstItem = items.first,
                  let lineItemRenderer = firstItem["lineItemRenderer"] as? [String: Any],
                  let text = lineItemRenderer["text"] as? [String: Any]
            else { return "" }
            return extractText(text) ?? ""
        }()

        // channelId: watchEndpoint.channelId (primary) or onSelectCommand.browseEndpoint.browseId (secondary)
        // Fallback: extract @handle from onLongPressCommand.showMenuCommand.subtitle.simpleText
        // TV client subtitle format: "ChannelName • @handle" — YouTube browse API accepts @handle as browseId.
        let channelId: String? = {
            if let id = watchEndpoint?["channelId"] as? String { return id }
            if let id = (onSelectCommand?["browseEndpoint"] as? [String: Any])?["browseId"] as? String { return id }
            guard let showMenu = (tile["onLongPressCommand"] as? [String: Any])?["showMenuCommand"] as? [String: Any],
                  let subtitleText = (showMenu["subtitle"] as? [String: Any])?["simpleText"] as? String,
                  let atIndex = subtitleText.firstIndex(of: "@")
            else { return nil }
            let handle = subtitleText[atIndex...]
                .components(separatedBy: .whitespacesAndNewlines)
                .first
                .map { String($0) }
            return handle
        }()

        // thumbnail: header.tileHeaderRenderer.thumbnail.thumbnails — Android: TileItem.getThumbnails()
        let tileHeader = (tile["header"] as? [String: Any])?["tileHeaderRenderer"] as? [String: Any]
        let thumbnails = (tileHeader?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbURL = thumbnails?.last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }

        // duration: header.tileHeaderRenderer.thumbnailOverlays[].thumbnailOverlayTimeStatusRenderer.text
        // Android: TileItem.getBadgeText()
        let overlays = tileHeader?["thumbnailOverlays"] as? [[String: Any]]
        let lengthText = overlays?.compactMap {
            ($0["thumbnailOverlayTimeStatusRenderer"] as? [String: Any]).flatMap {
                ($0["text"] as? [String: Any]).flatMap { extractText($0) }
            }
        }.first
        let duration = lengthText.flatMap { parseDuration($0) }

        // percentWatched: thumbnailOverlays[].thumbnailOverlayResumePlaybackRenderer.percentDurationWatched
        // (same path as WEB, used for watch-again resume)

        // isLive: thumbnailOverlay style == "LIVE" — Android: TileItem.isLive()
        let isLive = overlays?.contains {
            ($0["thumbnailOverlayTimeStatusRenderer"] as? [String: Any])?["style"] as? String == "LIVE"
        } ?? false

        // isShorts: style == "TILE_STYLE_YTLR_SHORTS" — Android: TileItem.isShorts()
        let isShort = (tile["style"] as? String) == "TILE_STYLE_YTLR_SHORTS"

        return Video(
            id: videoId,
            title: title,
            channelTitle: channelTitle,
            channelId: channelId,
            thumbnailURL: thumbURL,
            duration: duration,
            viewCount: nil,
            isLive: isLive,
            isShort: isShort,
            badges: []
        )
    }

    // MARK: – WEB lockupViewModel parser (Android LockupItem methodology)
    // Mirrors: LockupItem.getVideoId(), getTitle(), getThumbnails() in CommonHelper.kt
    private func parseLockupViewModel(_ lockup: [String: Any]) -> Video? {
        // videoId: rendererContext.commandContext.onTap.innertubeCommand.watchEndpoint.videoId
        guard let rendererContext = lockup["rendererContext"] as? [String: Any],
              let commandContext = rendererContext["commandContext"] as? [String: Any],
              let onTap = commandContext["onTap"] as? [String: Any],
              let innertubeCommand = onTap["innertubeCommand"] as? [String: Any],
              let watchEndpoint = innertubeCommand["watchEndpoint"] as? [String: Any],
              let videoId = watchEndpoint["videoId"] as? String else { return nil }

        // title: metadata.lockupMetadataViewModel.title
        let lockupMeta = (lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any]
        let title = (lockupMeta?["title"] as? [String: Any]).flatMap { extractText($0) } ?? ""

        // channelTitle + channelId: metadata.lockupMetadataViewModel.metadata.contentMetadataViewModel.metadataRows
        // The first row typically contains the channel name with a browseEndpoint for the channel.
        let metaContentVM = (lockupMeta?["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any]
        let metaRows = metaContentVM?["metadataRows"] as? [[String: Any]] ?? []

        let channelTitle: String = {
            guard let firstRow = metaRows.first,
                  let parts = firstRow["metadataParts"] as? [[String: Any]],
                  let firstPart = parts.first,
                  let text = firstPart["text"] as? [String: Any]
            else { return "" }
            return text["content"] as? String ?? extractText(text) ?? ""
        }()

        // channelId: watchEndpoint.channelId (primary) or
        // lockupMetadataViewModel.metadata.contentMetadataViewModel.metadataRows[].metadataParts[]
        //   .text.commandRuns[].onTap.innertubeCommand.browseEndpoint.browseId (fallback)
        let channelId: String? = (watchEndpoint["channelId"] as? String) ?? {
            for row in metaRows {
                guard let parts = row["metadataParts"] as? [[String: Any]] else { continue }
                for part in parts {
                    guard let text = part["text"] as? [String: Any],
                          let commandRuns = text["commandRuns"] as? [[String: Any]]
                    else { continue }
                    for run in commandRuns {
                        guard let cmd = (run["onTap"] as? [String: Any])?["innertubeCommand"] as? [String: Any],
                              let browseId = (cmd["browseEndpoint"] as? [String: Any])?["browseId"] as? String,
                              browseId.hasPrefix("UC")
                        else { continue }
                        return browseId
                    }
                }
            }
            return nil
        }()

        // thumbnail: contentImage.thumbnailViewModel.image.thumbnails
        let thumbVM = (lockup["contentImage"] as? [String: Any])?["thumbnailViewModel"] as? [String: Any]
        let thumbnails = (thumbVM?["image"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbURL = thumbnails?.last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }

        return Video(
            id: videoId, title: title, channelTitle: channelTitle, channelId: channelId,
            thumbnailURL: thumbURL, duration: nil, viewCount: nil,
            isLive: false, isShort: false, badges: []
        )
    }

    // MARK: – Shorts reelItemRenderer parser
    private func parseReelItemRenderer(_ r: [String: Any]) -> Video? {
        guard let videoId = r["videoId"] as? String else { return nil }
        let title = (r["headline"] as? [String: Any]).flatMap { extractText($0) } ?? ""
        let thumbnails = (r["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbURL = thumbnails?.last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }

        // channelTitle: ownerText or shortBylineText
        let channelTitle: String = (r["ownerText"] as? [String: Any]).flatMap { extractText($0) }
            ?? (r["shortBylineText"] as? [String: Any]).flatMap { extractText($0) }
            ?? ""

        // channelId: navigationEndpoint.reelWatchEndpoint.channelId (primary)
        // or ownerText/shortBylineText runs[0].navigationEndpoint.browseEndpoint.browseId (fallback)
        let channelId: String? = {
            if let channelId = (r["navigationEndpoint"] as? [String: Any])
                .flatMap({ ($0["reelWatchEndpoint"] as? [String: Any])?["channelId"] as? String }) {
                return channelId
            }
            let sourceKey = r["ownerText"] != nil ? "ownerText" : "shortBylineText"
            guard let runs = (r[sourceKey] as? [String: Any])?["runs"] as? [[String: Any]],
                  let first = runs.first,
                  let nav = first["navigationEndpoint"] as? [String: Any],
                  let browse = nav["browseEndpoint"] as? [String: Any]
            else { return nil }
            return browse["browseId"] as? String
        }()

        return Video(
            id: videoId, title: title, channelTitle: channelTitle, channelId: channelId,
            thumbnailURL: thumbURL, duration: nil, viewCount: nil,
            isLive: false, isShort: true, badges: []
        )
    }

    // MARK: – WEB videoRenderer parser
    private func parseVideoRenderer(_ r: [String: Any]) -> Video? {
        guard let videoId = r["videoId"] as? String else { return nil }
        let title = (r["title"] as? [String: Any]).flatMap { extractText($0) }
            ?? (r["headline"] as? [String: Any]).flatMap { extractText($0) }
            ?? ""
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
        let headerDict = json["header"] as? [String: Any]
        tubeLog.notice("parseChannel header keys=[\((headerDict?.keys.joined(separator: ",")) ?? "nil", privacy: .public)]")
        let header = headerDict?["c4TabbedHeaderRenderer"] as? [String: Any]
            ?? headerDict?["pageHeaderRenderer"] as? [String: Any]
        let title = header.flatMap { $0["title"] as? String }
            ?? (header?["pageTitle"] as? String)
            ?? {
                // pageHeaderRenderer uses content.pageHeaderViewModel.title.content
                if let content = (header?["content"] as? [String: Any])?["pageHeaderViewModel"] as? [String: Any] {
                    return (content["title"] as? [String: Any]).flatMap { extractText($0) }
                        ?? content["title"] as? String
                }
                return nil
            }()
            ?? ""
        tubeLog.notice("parseChannel header=\(header != nil ? "found" : "nil", privacy: .public) title='\(title, privacy: .public)'")
        let description = header
            .flatMap { $0["description"] as? [String: Any] }
            .flatMap { extractText($0) }
        // avatar: c4TabbedHeaderRenderer uses avatar.thumbnails, pageHeaderRenderer uses banner or content avatar
        let thumbURL: URL? = {
            // c4TabbedHeaderRenderer path
            if let url = ((header?["avatar"] as? [String: Any])?["thumbnails"] as? [[String: Any]])?
                .last.flatMap({ $0["url"] as? String }).flatMap({ URL(string: $0) }) {
                return url
            }
            // pageHeaderViewModel path: content.pageHeaderViewModel.image.decoratedAvatarViewModel.avatar.avatarViewModel.image.sources
            if let hvm = (header?["content"] as? [String: Any])?["pageHeaderViewModel"] as? [String: Any],
               let sources = ((((hvm["image"] as? [String: Any])?["decoratedAvatarViewModel"] as? [String: Any])?["avatar"] as? [String: Any])?["avatarViewModel"] as? [String: Any])?["image"] as? [String: Any],
               let urlStr = (sources["sources"] as? [[String: Any]])?.last?["url"] as? String {
                return URL(string: urlStr)
            }
            // metadata fallback: json.metadata.channelMetadataRenderer.avatar.thumbnails
            if let urlStr = (((json["metadata"] as? [String: Any])?["channelMetadataRenderer"] as? [String: Any])?["avatar"] as? [String: Any]).flatMap({ ($0["thumbnails"] as? [[String: Any]])?.last?["url"] as? String }) {
                return URL(string: urlStr)
            }
            return nil
        }()
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
        let playabilityDict  = json["playabilityStatus"] as? [String: Any]
        let playabilityStatus = playabilityDict?["status"] as? String ?? "unknown"
        let playabilityReason = playabilityDict?["reason"] as? String
            ?? (playabilityDict?["errorScreen"] as? [String: Any])
                .flatMap { ($0["playerErrorMessageRenderer"] as? [String: Any])?["subreason"] as? [String: Any] }
                .flatMap { extractText($0) }
        tubeLog.notice("parsePlayerInfo id=\(videoId, privacy: .public) playability=\(playabilityStatus, privacy: .public) reason=\(playabilityReason ?? "nil", privacy: .public) hasStreamingData=\(streamingData != nil, privacy: .public)")
        // Fail early for definitely-unplayable videos so callers don't waste work on
        // related/SponsorBlock fetches. Mirrors Android playabilityStatus check.
        if streamingData == nil, playabilityStatus != "OK" {
            let reason = playabilityReason ?? "This video is unavailable (\(playabilityStatus))"
            tubeLog.error("❌ parsePlayerInfo: unplayable — \(reason, privacy: .public)")
            throw APIError.unavailable(reason)
        }
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
        // Remove exact-duplicate entries that appear when a video has many audio tracks
        // (e.g. multi-language uploads return the same itag repeated for each language
        // variant, all with distinct URLs). Keep unique by URL string; fall back to
        // index-based dedup for formats without a URL.
        var seen = Set<String>()
        formats = formats.filter { fmt in
            let key = fmt.url?.absoluteString ?? "\(fmt.mimeType)-\(fmt.label)-\(fmt.bitrate ?? 0)"
            return seen.insert(key).inserted
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

        guard hlsURL != nil || !formats.isEmpty else {
            throw APIError.unavailable("This video is unavailable")
        }
        return PlayerInfo(video: video, formats: formats, hlsURL: hlsURL, dashURL: dashURL)
    }

    // MARK: – Channel renderer parser (TV/WEB client subscriptions "Channels" tab)
    //
    // Handles channelRenderer, gridChannelRenderer, compactChannelRenderer, and
    // TVHTML5 tileRenderer with TILE_CONTENT_TYPE_CHANNEL.
    private func parseChannelRenderers(from json: [String: Any]) -> [Channel] {
        var channels: [Channel] = []
        var seen = Set<String>()
        // Collect all distinct renderer key names encountered for diagnostics
        var encounteredRendererKeys = Set<String>()

        func extractChannel(from renderer: [String: Any]) -> Channel? {
            // channelId: direct "channelId" key, or from navigationEndpoint.browseEndpoint.browseId
            let channelId: String? = renderer["channelId"] as? String
                ?? (renderer["navigationEndpoint"] as? [String: Any])
                    .flatMap { ($0["browseEndpoint"] as? [String: Any])?["browseId"] as? String }
            guard let channelId, !channelId.isEmpty else { return nil }

            let title = (renderer["title"] as? [String: Any]).flatMap { extractText($0) }
                ?? renderer["title"] as? String
                ?? ""

            // Avatars: channelRenderer uses "thumbnail"; gridChannelRenderer may use
            // "thumbnail" or "channelThumbnailSupportedRenderers.channelThumbnailRenderer.thumbnail"
            let primaryThumb = (renderer["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
            let ctsr = (renderer["channelThumbnailSupportedRenderers"] as? [String: Any])?["channelThumbnailRenderer"] as? [String: Any]
            let secondaryThumb = (ctsr?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
            let thumbSources: [[String: Any]]? = primaryThumb ?? secondaryThumb
            let thumbURL = thumbSources?.last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }

            let subscriberCount = (renderer["subscriberCountText"] as? [String: Any])
                .flatMap { extractText($0) }
                ?? (renderer["videoCountText"] as? [String: Any]).flatMap { extractText($0) }

            return Channel(
                id: channelId,
                title: title,
                thumbnailURL: thumbURL,
                subscriberCount: subscriberCount
            )
        }

        func extractChannelFromTile(_ tile: [String: Any]) -> Channel? {
            guard (tile["contentType"] as? String) == "TILE_CONTENT_TYPE_CHANNEL" else { return nil }
            let onSelectCommand = tile["onSelectCommand"] as? [String: Any]
            let channelId: String? = (onSelectCommand?["browseEndpoint"] as? [String: Any])?["browseId"] as? String
                ?? (onSelectCommand?["innertubeCommand"] as? [String: Any])
                    .flatMap { ($0["browseEndpoint"] as? [String: Any])?["browseId"] as? String }
            guard let channelId, !channelId.isEmpty else { return nil }
            let tileMetadata = (tile["metadata"] as? [String: Any])?["tileMetadataRenderer"] as? [String: Any]
            let title = (tileMetadata?["title"] as? [String: Any]).flatMap { extractText($0) } ?? ""
            let tileHeader = (tile["header"] as? [String: Any])?["tileHeaderRenderer"] as? [String: Any]
            let thumbURL = ((tileHeader?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]])?
                .last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }
            return Channel(id: channelId, title: title, thumbnailURL: thumbURL)
        }

        var avatarLockupDumped = false
        var notificationDumped = false

        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                // Track all "xxxRenderer" keys at this level for diagnostics
                for k in dict.keys where k.hasSuffix("Renderer") || k.hasSuffix("ViewModel") {
                    encounteredRendererKeys.insert(k)
                }
                // Dump the first avatarLockupRenderer that actually has a navigationEndpoint (i.e. is a channel, not a sort header)
                if !avatarLockupDumped, let lockup = dict["avatarLockupRenderer"] as? [String: Any],
                   lockup["navigationEndpoint"] != nil {
                    avatarLockupDumped = true
                    if let data = try? JSONSerialization.data(withJSONObject: lockup, options: [.sortedKeys]),
                       let str = String(data: data, encoding: .utf8) {
                        tubeLog.notice("avatarLockupRenderer (with nav) JSON: \(String(str.prefix(2000)), privacy: .public)")
                    }
                }
                // Dump the first notificationMultiActionRenderer (these appear per-channel)
                if !notificationDumped, let notif = dict["notificationMultiActionRenderer"] as? [String: Any] {
                    notificationDumped = true
                    if let data = try? JSONSerialization.data(withJSONObject: notif, options: [.sortedKeys]),
                       let str = String(data: data, encoding: .utf8) {
                        tubeLog.notice("notificationMultiActionRenderer JSON: \(String(str.prefix(2000)), privacy: .public)")
                    }
                }
                // TVHTML5 channel tile
                if let tile = dict["tileRenderer"] as? [String: Any],
                   let channel = extractChannelFromTile(tile) {
                    if seen.insert(channel.id).inserted { channels.append(channel) }
                    return
                }
                // WEB channelRenderer / gridChannelRenderer / compactChannelRenderer
                let rendererKeys = ["channelRenderer", "gridChannelRenderer", "compactChannelRenderer"]
                if let key = rendererKeys.first(where: { dict[$0] is [String: Any] }),
                   let renderer = dict[key] as? [String: Any],
                   let channel = extractChannel(from: renderer) {
                    if seen.insert(channel.id).inserted { channels.append(channel) }
                    return
                }
                for value in dict.values { walk(value) }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item) }
            }
        }

        walk(json)
        let withThumbs = channels.filter { $0.thumbnailURL != nil }.count
        let rendererSample = Array(encounteredRendererKeys.sorted().prefix(12))
        tubeLog.notice("parseChannelRenderers → \(channels.count, privacy: .public) channels, \(withThumbs, privacy: .public) with thumbnail | renderer keys seen: \(rendererSample, privacy: .public)")
        return channels
    }

    // MARK: – Subscribed channels parser (TVHTML5 fallback)
    //
    // Extracts unique Channel objects from a TVHTML5 FEsubscriptions response.
    // Each video tileRenderer carries the channelId and channel name in its metadata;
    // thumbnail URLs and subscriber counts are not present and remain nil.
    private func parseSubscribedChannels(from json: [String: Any]) -> [Channel] {
        var channels: [Channel] = []
        var seen = Set<String>()

        func channelFromTile(_ tile: [String: Any]) -> Channel? {
            guard (tile["contentType"] as? String) == "TILE_CONTENT_TYPE_VIDEO" else { return nil }
            let onSelectCommand = tile["onSelectCommand"] as? [String: Any]
            let navigationEndpoint = tile["navigationEndpoint"] as? [String: Any]
            let watchEndpoint: [String: Any]? = {
                if let ep = onSelectCommand?["watchEndpoint"] as? [String: Any] { return ep }
                if let inner = onSelectCommand?["innertubeCommand"] as? [String: Any],
                   let ep = inner["watchEndpoint"] as? [String: Any] { return ep }
                if let ep = navigationEndpoint?["watchEndpoint"] as? [String: Any] { return ep }
                return nil
            }()
            let channelId: String? = watchEndpoint?["channelId"] as? String
                ?? (onSelectCommand?["browseEndpoint"] as? [String: Any])?["browseId"] as? String
                ?? {
                    guard let showMenu = (tile["onLongPressCommand"] as? [String: Any])?["showMenuCommand"] as? [String: Any],
                          let subtitleText = (showMenu["subtitle"] as? [String: Any])?["simpleText"] as? String,
                          let atIndex = subtitleText.firstIndex(of: "@")
                    else { return nil }
                    return subtitleText[atIndex...]
                        .components(separatedBy: .whitespacesAndNewlines)
                        .first
                        .map { String($0) }
                }()
            guard let channelId, !channelId.isEmpty else { return nil }

            let tileMetadata = (tile["metadata"] as? [String: Any])?["tileMetadataRenderer"] as? [String: Any]
            let channelTitle: String = {
                guard let lines = tileMetadata?["lines"] as? [[String: Any]],
                      let firstLine = lines.first,
                      let lineRenderer = firstLine["lineRenderer"] as? [String: Any],
                      let items = lineRenderer["items"] as? [[String: Any]],
                      let firstItem = items.first,
                      let lineItemRenderer = firstItem["lineItemRenderer"] as? [String: Any],
                      let text = lineItemRenderer["text"] as? [String: Any]
                else { return "" }
                return extractText(text) ?? ""
            }()
            return Channel(id: channelId, title: channelTitle)
        }

        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                if let tile = dict["tileRenderer"] as? [String: Any],
                   let channel = channelFromTile(tile) {
                    if seen.insert(channel.id).inserted {
                        channels.append(channel)
                    }
                    return
                }
                for value in dict.values { walk(value) }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item) }
            }
        }

        walk(json)
        tubeLog.notice("parseSubscribedChannels → \(channels.count, privacy: .public) unique channels")
        return channels
    }

    private func parsePlaylists(from json: [String: Any]) throws -> [PlaylistInfo] {
        var playlists: [PlaylistInfo] = []

        // Extracts a PlaylistInfo from a renderer dict, handling both
        // `playlistRenderer` (WEB search results) and
        // `gridPlaylistRenderer` / `compactPlaylistRenderer` (TVHTML5 library).
        func extractPlaylist(from renderer: [String: Any]) -> PlaylistInfo? {
            guard let id = renderer["playlistId"] as? String,
                  let title = (renderer["title"] as? [String: Any]).flatMap({ extractText($0) })
                           ?? (renderer["title"] as? String)
            else { return nil }
            // Thumbnails may be at renderer["thumbnails"][0]["thumbnails"] (WEB)
            // or renderer["thumbnail"]["thumbnails"] (TV grid).
            let thumbSources: [[String: Any]]? =
                ((renderer["thumbnails"] as? [[String: Any]])?.first?["thumbnails"] as? [[String: Any]])
                ?? (renderer["thumbnail"] as? [String: Any]).flatMap { $0["thumbnails"] as? [[String: Any]] }
            let thumbURL = thumbSources?.last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }
            // Video count may be a plain string or in a text object.
            let count: Int? =
                (renderer["videoCount"] as? String).flatMap { Int($0) }
                ?? (renderer["videoCountText"] as? [String: Any]).flatMap { extractText($0) }.flatMap { extractNumber($0) }
                ?? (renderer["videoCountShortText"] as? [String: Any]).flatMap { extractText($0) }.flatMap { extractNumber($0) }
            return PlaylistInfo(id: id, title: title, videoCount: count, thumbnailURL: thumbURL)
        }

        // Extracts a PlaylistInfo from a TVHTML5 tileRenderer.
        // Playlist tiles carry a browseId prefixed with "VL" in onSelectCommand;
        // video tiles use watchEndpoint instead, so we filter by the "VL" prefix.
        func extractPlaylistFromTile(_ tile: [String: Any]) -> PlaylistInfo? {
            func findBrowseId(_ cmd: [String: Any]) -> String? {
                if let ep = cmd["browseEndpoint"] as? [String: Any],
                   let bid = ep["browseId"] as? String { return bid }
                for v in cmd.values {
                    if let nested = v as? [String: Any], let bid = findBrowseId(nested) { return bid }
                }
                return nil
            }
            guard let cmd = tile["onSelectCommand"] as? [String: Any],
                  let rawId = findBrowseId(cmd),
                  rawId.hasPrefix("VL")
            else { return nil }
            let id = String(rawId.dropFirst(2))

            let metadata = (tile["metadata"] as? [String: Any])?["tileMetadataRenderer"] as? [String: Any]
            guard let titleRaw = metadata?["title"],
                  let title = (titleRaw as? [String: Any]).flatMap({ extractText($0) }) ?? (titleRaw as? String)
            else { return nil }

            let thumbSources =
                // tileHeaderRenderer.thumbnail.thumbnails
                ((tile["header"] as? [String: Any])?["tileHeaderRenderer"] as? [String: Any])
                    .flatMap { $0["thumbnail"] as? [String: Any] }
                    .flatMap { $0["thumbnails"] as? [[String: Any]] }
                // direct tile.thumbnail.thumbnails
                ?? (tile["thumbnail"] as? [String: Any]).flatMap { $0["thumbnails"] as? [[String: Any]] }
                // tile.thumbnails[0].thumbnails (WEB-style)
                ?? (tile["thumbnails"] as? [[String: Any]])?.first.flatMap { $0["thumbnails"] as? [[String: Any]] }
            let thumbURL = thumbSources?.last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }

            return PlaylistInfo(id: id, title: title, videoCount: nil, thumbnailURL: thumbURL)
        }

        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                let rendererKeys = ["playlistRenderer", "gridPlaylistRenderer", "compactPlaylistRenderer"]
                if let key = rendererKeys.first(where: { dict[$0] is [String: Any] }),
                   let renderer = dict[key] as? [String: Any],
                   let info = extractPlaylist(from: renderer) {
                    playlists.append(info)
                } else if let tile = dict["tileRenderer"] as? [String: Any],
                          let info = extractPlaylistFromTile(tile) {
                    playlists.append(info)
                } else {
                    for value in dict.values { walk(value) }
                }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item) }
            }
        }

        walk(json)
        tubeLog.notice("parsePlaylists → \(playlists.count, privacy: .public) playlists")
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

// MARK: - NextInfo

/// Combined result from the `/next` InnerTube endpoint.
public struct NextInfo: Sendable {
    public let relatedVideos: [Video]
    public let likeStatus: LikeStatus
    public let chapters: [Chapter]
}

// MARK: - PlayerInfo

public struct PlayerInfo: Sendable {
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

    /// A direct MP4 URL suitable for file download (muxed video+audio).
    /// Muxed formats list two codecs separated by ", " (e.g. "avc1.xxx, mp4a.xxx"),
    /// unlike adaptive streams which have a single codec.
    /// Returns nil if no muxed MP4 with a plain URL is available.
    public var bestMuxedDownloadURL: URL? {
        let muxed = formats.filter {
            $0.mimeType.hasPrefix("video/mp4") &&
            $0.mimeType.contains(", ") &&
            $0.url != nil
        }
        return muxed.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }.first?.url
    }

    /// Best adaptive video-only MP4 URL (single codec, no audio).
    /// Used together with bestAdaptiveAudioURL for the merge fallback.
    public var bestAdaptiveVideoURL: URL? {
        let videoOnly = formats.filter {
            $0.mimeType.hasPrefix("video/mp4") &&
            !$0.mimeType.contains(", ") &&
            $0.url != nil
        }
        return videoOnly.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }.first?.url
    }

    /// Best adaptive audio-only MP4 URL.
    /// Used together with bestAdaptiveVideoURL for the merge fallback.
    public var bestAdaptiveAudioURL: URL? {
        let audioOnly = formats.filter {
            $0.mimeType.hasPrefix("audio/mp4") &&
            $0.url != nil
        }
        return audioOnly.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }.first?.url
    }
}

// MARK: - APIError

public enum APIError: LocalizedError {
    case httpError(Int)
    case decodingError(String)
    case notAuthenticated
    case unavailable(String)
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .httpError(let code):      return "HTTP error \(code)"
        case .decodingError(let msg):   return "Decoding error: \(msg)"
        case .notAuthenticated:          return "You are not signed in"
        case .unavailable(let reason):   return reason
        case .invalidURL(let endpoint):  return "Could not build URL for endpoint: \(endpoint)"
        }
    }
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
