import Foundation
import os
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let tubeLog = Logger(subsystem: appSubsystem, category: "InnerTube")

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

    // MARK: - Next (related videos / SuggestionsController equivalent)

    /// Fetches related / suggested videos for a given video ID.
    /// Mirrors Android's SuggestionsController which calls the `/next` endpoint.
    public func fetchNextInfo(videoId: String) async throws -> [Video] {
        var body = makeBody(client: webClientContext)
        body["videoId"] = videoId
        let data = try await post(endpoint: "next", body: body)
        return parseRelatedVideos(from: data)
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
        do {
            var body = makeBody(client: tvClientContext)
            body["browseId"] = "FEnews"
            let data = try await postTVCategory(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "News")
            if !group.videos.isEmpty { return group }
        } catch {
            tubeLog.notice("fetchNews browse failed, falling back to search: \(error, privacy: .public)")
        }
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

        func walkShelfContents(_ obj: Any) -> [Video] {
            var videos: [Video] = []
            if let dict = obj as? [String: Any] {
                if let vr = dict["videoRenderer"] as? [String: Any], let v = parseVideoRenderer(vr) {
                    videos.append(v)
                } else if let ri = dict["richItemRenderer"] as? [String: Any],
                          let content = ri["content"] as? [String: Any],
                          let vr = content["videoRenderer"] as? [String: Any],
                          let v = parseVideoRenderer(vr) {
                    videos.append(v)
                } else {
                    for value in dict.values { videos += walkShelfContents(value) }
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

    private func parseVideoGroup(from json: [String: Any], title: String?) throws -> VideoGroup {
        var videos: [Video] = []
        var nextPageToken: String? = nil

        // Walk the renderer tree to find videoRenderers and continuationItemRenderers.
        // Handles WEB (videoRenderer, richItemRenderer, compactVideoRenderer),
        // WEB grid (gridVideoRenderer), and TVHTML5 tileRenderer (subs/history/home on TV client).
        // Matches Android MediaServiceCore ItemWrapper renderer dispatch order.
        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
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
        tubeLog.notice("parseVideoGroup '\(title ?? "nil", privacy: .public)' → \(videos.count, privacy: .public) videos, nextPage=\(nextPageToken != nil ? "yes" : "no", privacy: .public)")
        return VideoGroup(title: title, videos: videos, nextPageToken: nextPageToken)
    }

    // MARK: – TVHTML5 tileRenderer parser (Android TileItem methodology)
    // Mirrors: TileItem.getVideoId(), getTitle(), getThumbnails(), getBadgeText(), getChannelId()
    private func parseTileRenderer(_ tile: [String: Any]) -> Video? {
        // Only parse video tiles (skip channel/playlist tiles) — Android: TILE_CONTENT_TYPE_VIDEO
        let contentType = tile["contentType"] as? String
        if let ct = contentType, ct != "TILE_CONTENT_TYPE_VIDEO" { return nil }

        // videoId: onSelectCommand.watchEndpoint.videoId — Android: TileItem.getVideoId()
        guard let onSelect = tile["onSelectCommand"] as? [String: Any],
              let watchEndpoint = onSelect["watchEndpoint"] as? [String: Any],
              let videoId = watchEndpoint["videoId"] as? String else { return nil }

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

        // channelId: onSelectCommand.browseEndpoint.browseId — Android: TileItem.getChannelId()
        let channelId = (onSelect["browseEndpoint"] as? [String: Any])?["browseId"] as? String

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

        // thumbnail: contentImage.thumbnailViewModel.image.thumbnails
        let thumbVM = (lockup["contentImage"] as? [String: Any])?["thumbnailViewModel"] as? [String: Any]
        let thumbnails = (thumbVM?["image"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbURL = thumbnails?.last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }

        return Video(
            id: videoId, title: title, channelTitle: "", channelId: nil,
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
        return Video(
            id: videoId, title: title, channelTitle: "", channelId: nil,
            thumbnailURL: thumbURL, duration: nil, viewCount: nil,
            isLive: false, isShort: true, badges: []
        )
    }

    // MARK: – WEB videoRenderer parser
    private func parseVideoRenderer(_ r: [String: Any]) -> Video? {
        guard let videoId = r["videoId"] as? String else { return nil }

        // "title" is the WEB key; "headline" is used in some TVHTML5 renderers
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

            let thumbSources = ((tile["header"] as? [String: Any])?["tileHeaderRenderer"] as? [String: Any])
                .flatMap { $0["thumbnail"] as? [String: Any] }
                .flatMap { $0["thumbnails"] as? [[String: Any]] }
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
