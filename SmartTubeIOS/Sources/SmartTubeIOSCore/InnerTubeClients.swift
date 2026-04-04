import Foundation

// MARK: - InnerTubeClients
//
// Single source of truth for YouTube InnerTube client identifiers and versions.
// Used by InnerTubeAPI (request bodies + headers) and AuthService (TV context body).

package enum InnerTubeClients {

    package enum Web {
        package static let name      = "WEB"
        package static let nameID    = "1"
        package static let version   = "2.20260206.01.00"
        /// Browser UA used by the YouTube web client. CDN URLs signed by the web
        /// client embed c=WEB and require a desktop browser User-Agent to avoid 403.
        package static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }

    package enum iOS {
        package static let name      = "iOS"
        package static let nameID    = "5"
        package static let version   = "19.43.5"
        /// Native iOS app UA. CDN URLs signed by the iOS client embed c=IOS and
        /// require this UA. Device model and OS must match the client context body.
        package static let userAgent = "com.google.ios.youtube/\(version) (iPhone16,2; U; CPU iOS 18_1_1 like Mac OS X)"
    }

    package enum TV {
        package static let name      = "TVHTML5"
        package static let nameID    = "7"
        package static let version   = "7.20260311.12.00"
        /// Cobalt/TV UA expected by the TVHTML5 client CDN URLs (c=TVHTML5).
        package static let userAgent = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"
    }

    /// Maximum number of videos fetched per shelf/related-videos request.
    package static let maxVideoResults = 20
}
