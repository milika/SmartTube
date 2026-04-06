import UIKit
import UniformTypeIdentifiers
import SmartTubeIOSCore

// MARK: - ShareViewController
//
// Principal class for the SmartTube Share Extension.
// Appears in the iOS share sheet when sharing any YouTube or youtu.be URL.
//
// Mechanism:
//  1. Write video ID to App Group UserDefaults (backup, consumed when the main
//     app next comes to foreground).
//  2. Open smarttube://video/<videoID> via extensionContext.open() on the main
//     thread — this brings the main app to foreground immediately.
//     NOTE: extensionContext.open() must be called on the MAIN THREAD; calling
//     it from a loadItem callback (background thread) silently no-ops.

final class ShareViewController: UIViewController {

    private static let appGroup   = "group.com.void.smarttube"
    private static let pendingKey = "pendingVideoID"

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { @MainActor in await extractAndOpen() }
    }

    // MARK: - Extraction

    @MainActor
    private func extractAndOpen() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            cancel(); return
        }

        for item in items {
            for provider in item.attachments ?? [] {
                guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else { continue }

                let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
                let url: URL?
                if let u = loaded as? URL { url = u }
                else if let s = loaded as? String { url = URL(string: s) }
                else { url = nil }

                guard let url,
                      let videoID = YouTubeLinkHandler.videoID(from: url),
                      let deeplink = URL(string: "smarttube://video/\(videoID)")
                else { continue }

                // Write to App Group as a fallback in case the user doesn't
                // immediately switch to SmartTube.
                if let defaults = UserDefaults(suiteName: Self.appGroup) {
                    defaults.set(videoID, forKey: Self.pendingKey)
                    defaults.synchronize()
                }

                // Open the main app (must be called on main thread — guaranteed
                // here because this whole method is @MainActor).
                extensionContext?.open(deeplink) { [weak self] _ in
                    self?.extensionContext?.completeRequest(returningItems: nil)
                }
                return
            }
        }

        cancel()
    }

    private func cancel() {
        extensionContext?.cancelRequest(
            withError: NSError(domain: "com.void.smarttube.share", code: 0, userInfo: nil)
        )
    }
}

