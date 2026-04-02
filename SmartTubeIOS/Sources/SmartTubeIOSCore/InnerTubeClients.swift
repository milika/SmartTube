import Foundation

// MARK: - InnerTubeClients
//
// Single source of truth for YouTube InnerTube client identifiers and versions.
// Used by InnerTubeAPI (request bodies + headers) and AuthService (TV context body).

package enum InnerTubeClients {

    package enum Web {
        package static let name    = "WEB"
        package static let nameID  = "1"
        package static let version = "2.20260206.01.00"
    }

    package enum iOS {
        package static let name    = "iOS"
        package static let nameID  = "5"
        package static let version = "20.11.6"
        package static let userAgent = "com.google.ios.youtube/\(version) (iPhone10,4; U; CPU iOS 16_7_7 like Mac OS X)"
    }

    package enum TV {
        package static let name    = "TVHTML5"
        package static let nameID  = "7"
        package static let version = "7.20230405.08.01"
    }

    /// Maximum number of videos fetched per shelf/related-videos request.
    package static let maxVideoResults = 20
}
