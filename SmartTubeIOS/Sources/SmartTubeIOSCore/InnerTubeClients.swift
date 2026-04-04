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
        /// Browser UA used by the YouTube web client.
        package static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }

    package enum iOS {
        package static let name      = "iOS"
        package static let nameID    = "5"
        package static let version   = "20.11.6"
        package static let userAgent = "com.google.ios.youtube/\(version) (iPhone10,4; U; CPU iOS 16_7_7 like Mac OS X)"
    }

    /// Android client — used exclusively for downloads.
    /// CDN URLs signed by the Android client (`c=ANDROID`) are reliably downloadable
    /// with a standard Android UA and do not require TVHTML5 session cookies.
    package enum Android {
        package static let name            = "ANDROID"
        package static let nameID          = "3"
        package static let version         = "19.44.38"
        package static let androidSdkVersion = 34  // Android 14
        package static let userAgent       = "com.google.android.youtube/\(version) (Linux; U; Android 14; en_US; Pixel 7) gzip"
    }

    package enum TV {
        package static let name      = "TVHTML5"
        package static let nameID    = "7"
        package static let version   = "7.20260311.12.00"
        package static let userAgent = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"
    }

    /// Maximum number of videos fetched per shelf/related-videos request.
    package static let maxVideoResults = 20
}
