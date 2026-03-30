#if canImport(SwiftUI)
import Foundation
import os
import SmartTubeIOSCore

private let authLog = Logger(subsystem: "com.smarttube.app", category: "Auth")

// MARK: - AuthService
//
// Google OAuth 2.0 **Device Authorization Grant** flow (RFC 8628).
//
// Mirrors exactly how the Android SmartTube app authenticates:
//  1. Fetch client_id / client_secret by scraping YouTube's own base.js
//     (see YouTubeClientCredentialsFetcher in SmartTubeIOSCore).
//  2. POST to https://oauth2.googleapis.com/device/code → get user_code +
//     verification_url (youtube.com/activate).
//  3. Show the user_code on-screen so the user can enter it at
//     https://youtube.com/activate on any device.
//  4. Poll https://oauth2.googleapis.com/token every `interval` seconds until
//     the user approves or cancels.
//
// No redirect URI, no registered client ID, no ASWebAuthenticationSession.

@MainActor
public final class AuthService: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var isSignedIn: Bool = false
    @Published public private(set) var accountName: String?
    @Published public private(set) var accountAvatarURL: URL?
    @Published public var error: Error?

    /// Non-nil while waiting for the user to enter the code at youtube.com/activate.
    @Published public private(set) var pendingActivation: ActivationInfo?

    // MARK: - ActivationInfo

    public struct ActivationInfo {
        /// The short code the user types at youtube.com/activate (e.g. "ABCD-1234").
        public let userCode: String
        /// Always https://youtube.com/activate
        public let verificationURL: URL
        /// When this activation attempt expires.
        public let expiresAt: Date
    }

    // MARK: - Private state

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?
    private var pollTask: Task<Void, Never>?

    private let credentialsFetcher = YouTubeClientCredentialsFetcher()
    private let scope = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"

    private let tokenKey   = "st_access_token"
    private let refreshKey = "st_refresh_token"
    private let expiryKey  = "st_token_expiry"
    private let accountKey = "st_account_name"
    private let avatarKey  = "st_avatar_url"

    public init() {
        loadFromKeychain()
        // If already signed in but no account info (e.g. stored before the
        // fetchUserInfo fix), refresh it silently in the background.
        if isSignedIn && accountName == nil {
            Task { try? await fetchUserInfo() }
        }
    }

    // MARK: - Public API

    /// Step 1 – request a device code and expose the user_code for display.
    /// Call this when the user taps "Sign in".
    public func beginSignIn() async {
        pollTask?.cancel()
        error = nil
        pendingActivation = nil
        authLog.notice("beginSignIn() — fetching credentials…")

        let creds = await credentialsFetcher.credentials()
        authLog.notice("Using clientId: \(creds.clientId, privacy: .public)")

        do {
            let deviceResponse = try await requestDeviceCode(creds: creds)
            authLog.notice("✅ Got device code. userCode=\(deviceResponse.userCode, privacy: .public) expiresIn=\(deviceResponse.expiresIn, privacy: .public)s interval=\(deviceResponse.interval, privacy: .public)s")
            let expiresAt = Date().addingTimeInterval(TimeInterval(deviceResponse.expiresIn - 10))
            let verURL = URL(string: deviceResponse.verificationURL) ?? URL(string: "https://youtube.com/activate")!

            pendingActivation = ActivationInfo(
                userCode: deviceResponse.userCode,
                verificationURL: verURL,
                expiresAt: expiresAt
            )

            // Step 2 – start polling in the background
            let interval = max(TimeInterval(deviceResponse.interval), 5)
            pollTask = Task { [weak self] in
                await self?.pollForToken(deviceCode: deviceResponse.deviceCode,
                                         interval: interval,
                                         creds: creds)
            }
        } catch {
            authLog.error("❌ beginSignIn error: \(String(describing: error), privacy: .public)")
            self.error = error
        }
    }

    /// Cancel an in-progress activation.
    public func cancelSignIn() {
        pollTask?.cancel()
        pollTask = nil
        pendingActivation = nil
    }

    public func signOut() {
        pollTask?.cancel()
        pollTask = nil
        accessToken      = nil
        refreshToken     = nil
        tokenExpiry      = nil
        accountName      = nil
        accountAvatarURL = nil
        isSignedIn       = false
        pendingActivation = nil
        clearKeychain()
    }

    /// Returns a valid access token, refreshing if necessary.
    public func validAccessToken() async throws -> String {
        if let t = accessToken, let exp = tokenExpiry, exp > Date() { return t }
        guard let refresh = refreshToken else { throw AuthError.notSignedIn }
        let creds = await credentialsFetcher.credentials()
        try await refreshAccessToken(refreshToken: refresh, creds: creds)
        guard let t = accessToken else { throw AuthError.notSignedIn }
        return t
    }

    // MARK: - Device Code request

    private struct DeviceCodeResponse {
        let deviceCode: String
        let userCode: String
        let verificationURL: String
        let expiresIn: Int
        let interval: Int
    }

    private func requestDeviceCode(creds: YouTubeClientCredentials) async throws -> DeviceCodeResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/device/code")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            "client_id": creds.clientId,
            "scope":     scope,
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.deviceCodeRequestFailed
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = json["device_code"]       as? String,
              let userCode   = json["user_code"]         as? String,
              let verURL     = json["verification_url"]  as? String,
              let expiresIn  = json["expires_in"]        as? Int
        else { throw AuthError.deviceCodeRequestFailed }

        return DeviceCodeResponse(
            deviceCode:      deviceCode,
            userCode:        userCode,
            verificationURL: verURL,
            expiresIn:       expiresIn,
            interval:        json["interval"] as? Int ?? 5
        )
    }

    // MARK: - Polling

    private func pollForToken(deviceCode: String, interval: TimeInterval, creds: YouTubeClientCredentials) async {
        authLog.notice("Starting poll loop (interval \(Int(interval), privacy: .public)s)")
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }

            do {
                try await exchangeDeviceCode(deviceCode: deviceCode, creds: creds)
                // Success — fetchUserInfo and clean up
                authLog.notice("✅ Token exchanged — fetching user info")
                try await fetchUserInfo()
                authLog.notice("✅ Signed in as \(self.accountName ?? "unknown", privacy: .public)")
                pendingActivation = nil
                pollTask = nil
                return
            } catch AuthError.authorizationPending {
                authLog.debug("Polling… (authorization_pending)")
                continue   // user hasn't entered code yet — keep polling
            } catch AuthError.slowDown {
                authLog.notice("slow_down received — waiting extra 5s")
                try? await Task.sleep(nanoseconds: UInt64(5 * 1_000_000_000))
                continue
            } catch {
                authLog.error("❌ Poll error: \(String(describing: error), privacy: .public)")
                self.error = error
                pendingActivation = nil
                pollTask = nil
                return
            }
        }
        authLog.notice("Poll loop cancelled")
    }

    private func exchangeDeviceCode(deviceCode: String, creds: YouTubeClientCredentials) async throws {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            "code":          deviceCode,
            "client_id":     creds.clientId,
            "client_secret": creds.clientSecret,
            "grant_type":    "http://oauth.net/grant_type/device/1.0",
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.tokenExchangeFailed
        }

        // RFC 8628 §3.5 error codes
        if let oauthError = json["error"] as? String {
            switch oauthError {
            case "authorization_pending": throw AuthError.authorizationPending
            case "slow_down":             throw AuthError.slowDown
            case "access_denied":         throw AuthError.cancelled
            case "expired_token":         throw AuthError.deviceCodeExpired
            default:                      throw AuthError.tokenExchangeFailed
            }
        }

        guard (200..<300).contains(statusCode) else { throw AuthError.tokenExchangeFailed }

        accessToken = json["access_token"] as? String
        if let r = json["refresh_token"] as? String { refreshToken = r }
        if let exp = json["expires_in"] as? TimeInterval {
            tokenExpiry = Date().addingTimeInterval(exp - 60)
        }
        isSignedIn = accessToken != nil
        saveToKeychain()
    }

    // MARK: - Token refresh

    private func refreshAccessToken(refreshToken: String, creds: YouTubeClientCredentials) async throws {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            "refresh_token": refreshToken,
            "client_id":     creds.clientId,
            "client_secret": creds.clientSecret,
            "grant_type":    "refresh_token",
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AuthError.tokenExchangeFailed }

        accessToken = json["access_token"] as? String
        if let exp = json["expires_in"] as? TimeInterval {
            tokenExpiry = Date().addingTimeInterval(exp - 60)
        }
        isSignedIn = accessToken != nil
        saveToKeychain()
    }

    // MARK: - User info

    private func fetchUserInfo() async throws {
        let token = try await validAccessToken()
        // The sign-in scope doesn't include `profile`/`openid`, so the OAuth
        // userinfo endpoint returns nothing.  Use the YouTube Data API v3
        // channels endpoint instead — it works with the existing YouTube scopes
        // and returns the channel title + thumbnail that SmartTube Android shows.
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]],
              let first = items.first,
              let snippet = first["snippet"] as? [String: Any]
        else { return }
        accountName = snippet["title"] as? String
        // Prefer the highest-resolution thumbnail available
        if let thumbs = snippet["thumbnails"] as? [String: Any] {
            let preferred = ["high", "medium", "default"]
            for key in preferred {
                if let t = thumbs[key] as? [String: Any],
                   let urlStr = t["url"] as? String {
                    accountAvatarURL = URL(string: urlStr)
                    break
                }
            }
        }
        saveToKeychain()
    }

    // MARK: - Persistence (UserDefaults; swap for Keychain in production)

    private func saveToKeychain() {
        let d = UserDefaults.standard
        d.set(accessToken,  forKey: tokenKey)
        d.set(refreshToken, forKey: refreshKey)
        d.set(tokenExpiry,  forKey: expiryKey)
        d.set(accountName,  forKey: accountKey)
        d.set(accountAvatarURL?.absoluteString, forKey: avatarKey)
    }

    private func loadFromKeychain() {
        let d = UserDefaults.standard
        accessToken      = d.string(forKey: tokenKey)
        refreshToken     = d.string(forKey: refreshKey)
        tokenExpiry      = d.object(forKey: expiryKey) as? Date
        accountName      = d.string(forKey: accountKey)
        accountAvatarURL = d.string(forKey: avatarKey).flatMap { URL(string: $0) }
        isSignedIn       = accessToken != nil
    }

    private func clearKeychain() {
        let d = UserDefaults.standard
        [tokenKey, refreshKey, expiryKey, accountKey, avatarKey].forEach { d.removeObject(forKey: $0) }
    }

    // MARK: - Helpers

    private func formEncode(_ params: [String: String]) -> Data? {
        params.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            return "\(ek)=\(ev)"
        }
        .joined(separator: "&")
        .data(using: .utf8)
    }
}

// MARK: - AuthError

public enum AuthError: LocalizedError {
    case cancelled
    case missingCode
    case tokenExchangeFailed
    case notSignedIn
    case configurationError
    case deviceCodeRequestFailed
    case authorizationPending
    case slowDown
    case deviceCodeExpired

    public var errorDescription: String? {
        switch self {
        case .cancelled:              return "Sign-in was cancelled"
        case .missingCode:            return "OAuth code was missing from callback"
        case .tokenExchangeFailed:    return "Failed to exchange code for tokens"
        case .notSignedIn:            return "You are not signed in"
        case .configurationError:     return "OAuth credentials could not be obtained"
        case .deviceCodeRequestFailed:return "Could not start sign-in. Check your internet connection."
        case .authorizationPending:   return "Waiting for authorisation…"
        case .slowDown:               return "Too many requests — slowing down"
        case .deviceCodeExpired:      return "The sign-in code expired. Please try again."
        }
    }
}
#endif
