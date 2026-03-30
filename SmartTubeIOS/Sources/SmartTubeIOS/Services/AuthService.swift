#if canImport(SwiftUI)
import Foundation
import AuthenticationServices

// MARK: - AuthService
//
// Handles Google OAuth 2.0 authentication for the YouTube API.
// Uses ASWebAuthenticationSession (available on iOS 12+, macOS 10.15+).

@MainActor
public final class AuthService: NSObject, ObservableObject {

    // MARK: - Published state

    @Published public private(set) var isSignedIn: Bool = false
    @Published public private(set) var accountName: String?
    @Published public private(set) var accountAvatarURL: URL?
    @Published public var error: Error?

    // MARK: - Private

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?

    // OAuth 2.0 credentials.
    // Replace "YOUR_GOOGLE_CLIENT_ID" with your own client ID from
    // https://console.cloud.google.com/apis/credentials
    // In production, load this from a local config file that is excluded
    // from version control (e.g. Secrets.plist in .gitignore).
    private let clientID = "YOUR_GOOGLE_CLIENT_ID"
    private let redirectURI = "smarttube://oauth2callback"
    private let scopes = ["https://www.googleapis.com/auth/youtube"]

    private let tokenKey    = "st_access_token"
    private let refreshKey  = "st_refresh_token"
    private let expiryKey   = "st_token_expiry"
    private let accountKey  = "st_account_name"
    private let avatarKey   = "st_avatar_url"

    public override init() {
        super.init()
        loadFromKeychain()
    }

    // MARK: - Public API

    /// Initiates an OAuth 2.0 sign-in flow using `ASWebAuthenticationSession`.
    public func signIn(presentationAnchor: ASPresentationAnchor) async {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id",     value: clientID),
            URLQueryItem(name: "redirect_uri",  value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope",         value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type",   value: "offline"),
            URLQueryItem(name: "prompt",        value: "consent"),
        ]
        guard let authURL = components.url else { return }

        do {
            let callbackURL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: "smarttube"
                ) { url, error in
                    if let error { cont.resume(throwing: error); return }
                    if let url   { cont.resume(returning: url); return }
                    cont.resume(throwing: AuthError.cancelled)
                }
                session.prefersEphemeralWebBrowserSession = false
                session.presentationContextProvider = PresentationAnchorProvider(anchor: presentationAnchor)
                session.start()
            }

            guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value
            else {
                error = AuthError.missingCode
                return
            }

            try await exchangeCodeForTokens(code: code)
            try await fetchUserInfo()
        } catch {
            self.error = error
        }
    }

    public func signOut() {
        accessToken  = nil
        refreshToken = nil
        tokenExpiry  = nil
        accountName  = nil
        accountAvatarURL = nil
        isSignedIn   = false
        clearKeychain()
    }

    /// Returns a valid access token, refreshing it if necessary.
    public func validAccessToken() async throws -> String {
        if let token = accessToken, let expiry = tokenExpiry, expiry > Date() {
            return token
        }
        guard let refresh = refreshToken else { throw AuthError.notSignedIn }
        try await refreshAccessToken(using: refresh)
        guard let token = accessToken else { throw AuthError.notSignedIn }
        return token
    }

    // MARK: - Token exchange

    private func exchangeCodeForTokens(code: String) async throws {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "code":          code,
            "client_id":     clientID,
            "redirect_uri":  redirectURI,
            "grant_type":    "authorization_code",
        ]
        request.httpBody = body.map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        try await handleTokenResponse(request: request)
    }

    private func refreshAccessToken(using refreshToken: String) async throws {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "refresh_token": refreshToken,
            "client_id":     clientID,
            "grant_type":    "refresh_token",
        ]
        request.httpBody = body.map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        try await handleTokenResponse(request: request)
    }

    private func handleTokenResponse(request: URLRequest) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.tokenExchangeFailed
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.tokenExchangeFailed
        }
        accessToken  = json["access_token"]  as? String
        if let r = json["refresh_token"] as? String { refreshToken = r }
        if let exp = json["expires_in"] as? TimeInterval {
            tokenExpiry = Date().addingTimeInterval(exp - 60)
        }
        isSignedIn = accessToken != nil
        saveToKeychain()
    }

    // MARK: - User info

    private func fetchUserInfo() async throws {
        guard let token = accessToken else { return }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        accountName     = json["name"] as? String
        accountAvatarURL = (json["picture"] as? String).flatMap { URL(string: $0) }
        saveToKeychain()
    }

    // MARK: - Keychain (simple UserDefaults wrapper; use Keychain in production)

    private func saveToKeychain() {
        let defaults = UserDefaults.standard
        defaults.set(accessToken,  forKey: tokenKey)
        defaults.set(refreshToken, forKey: refreshKey)
        defaults.set(tokenExpiry,  forKey: expiryKey)
        defaults.set(accountName,  forKey: accountKey)
        defaults.set(accountAvatarURL?.absoluteString, forKey: avatarKey)
    }

    private func loadFromKeychain() {
        let defaults = UserDefaults.standard
        accessToken  = defaults.string(forKey: tokenKey)
        refreshToken = defaults.string(forKey: refreshKey)
        tokenExpiry  = defaults.object(forKey: expiryKey) as? Date
        accountName  = defaults.string(forKey: accountKey)
        accountAvatarURL = defaults.string(forKey: avatarKey).flatMap { URL(string: $0) }
        isSignedIn   = accessToken != nil
    }

    private func clearKeychain() {
        let defaults = UserDefaults.standard
        [tokenKey, refreshKey, expiryKey, accountKey, avatarKey].forEach { defaults.removeObject(forKey: $0) }
    }
}

// MARK: - AuthError

public enum AuthError: LocalizedError {
    case cancelled
    case missingCode
    case tokenExchangeFailed
    case notSignedIn

    public var errorDescription: String? {
        switch self {
        case .cancelled:           return "Sign-in was cancelled"
        case .missingCode:         return "OAuth code was missing from callback"
        case .tokenExchangeFailed: return "Failed to exchange code for tokens"
        case .notSignedIn:         return "You are not signed in"
        }
    }
}

// MARK: - PresentationAnchorProvider

private final class PresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    let anchor: ASPresentationAnchor
    init(anchor: ASPresentationAnchor) { self.anchor = anchor }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
}
#endif
