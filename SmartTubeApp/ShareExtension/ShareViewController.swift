import UIKit
import UniformTypeIdentifiers
import SmartTubeIOSCore
import os

private let shareLog = Logger(subsystem: "com.void.smarttube.app.shareextension", category: "Share")

// MARK: - ShareViewController
//
// Opens the main app from a Share Extension by walking the UIResponder chain
// to find the first responder that responds to `openURL:`. Casting to UIApplication
// does not work in a Share Extension process — there is no UIApplication instance
// in the chain — but Apple's internal application proxy object responds to the
// openURL: selector and correctly cross-launches the containing app.

final class ShareViewController: UIViewController {

    private static let appGroup   = "group.com.void.smarttube"
    private static let pendingKey = "pendingVideoID"

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        shareLog.notice("viewDidAppear — starting extraction")
        Task { @MainActor in await extractAndOpen() }
    }

    // MARK: - Extraction

    @MainActor
    private func extractAndOpen() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            shareLog.error("No inputItems — cancelling")
            cancel(); return
        }

        shareLog.notice("inputItems count: \(items.count, privacy: .public)")

        for (i, item) in items.enumerated() {
            let attachments = item.attachments ?? []
            shareLog.notice("item[\(i, privacy: .public)] attachments: \(attachments.count, privacy: .public)")
            for (j, provider) in attachments.enumerated() {
                let types = provider.registeredTypeIdentifiers
                shareLog.notice("  provider[\(j, privacy: .public)] types: \(types.joined(separator: ", "), privacy: .public)")

                guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else {
                    shareLog.notice("  provider[\(j, privacy: .public)] — no URL type, skipping")
                    continue
                }

                shareLog.notice("  provider[\(j, privacy: .public)] — loading URL item")
                let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
                shareLog.notice("  loaded type: \(String(describing: type(of: loaded)), privacy: .public) value: \(String(describing: loaded), privacy: .public)")

                let url: URL?
                if let u = loaded as? URL {
                    url = u
                } else if let s = loaded as? String {
                    shareLog.notice("  value is String, constructing URL: \(s, privacy: .public)")
                    url = URL(string: s)
                } else {
                    shareLog.error("  unexpected loaded type — skipping")
                    url = nil
                }

                guard let url else {
                    shareLog.error("  could not resolve URL — skipping")
                    continue
                }

                shareLog.notice("  resolved URL: \(url.absoluteString, privacy: .public)")

                guard let videoID = YouTubeLinkHandler.videoID(from: url) else {
                    shareLog.error("  YouTubeLinkHandler returned nil for: \(url.absoluteString, privacy: .public)")
                    continue
                }

                shareLog.notice("  videoID: \(videoID, privacy: .public)")

                // Write to App Group as fallback
                if let defaults = UserDefaults(suiteName: Self.appGroup) {
                    defaults.set(videoID, forKey: Self.pendingKey)
                    defaults.synchronize()
                    shareLog.notice("  wrote to App Group \(Self.appGroup, privacy: .public)")
                } else {
                    shareLog.error("  FAILED to open App Group \(Self.appGroup, privacy: .public)")
                }

                guard let deeplink = URL(string: "smarttube://video/\(videoID)") else {
                    shareLog.error("  failed to build deeplink — completing without open")
                    extensionContext?.completeRequest(returningItems: nil)
                    return
                }

                shareLog.notice("  walking responder chain to open \(deeplink.absoluteString, privacy: .public)")
                openViaResponderChain(deeplink)
                extensionContext?.completeRequest(returningItems: nil)
                return
            }
        }

        shareLog.error("No YouTube URL found in any attachment — cancelling")
        cancel()
    }

    /// Walks the UIResponder chain from `self` upward until it finds an object that
    /// responds to `openURL:`, then uses it to open `url`. In a Share Extension
    /// process there is no UIApplication instance to cast to, but Apple's internal
    /// application proxy object does respond to the selector and correctly brings
    /// the containing app to the foreground.
    private func openViaResponderChain(_ url: URL) {
        let openURLSel = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let r = responder {
            if r.responds(to: openURLSel) {
                shareLog.notice("  found openURL: responder (\(type(of: r), privacy: .public)) — opening URL")
                r.perform(openURLSel, with: url)
                return
            }
            responder = r.next
        }
        shareLog.error("  no responder with openURL: found in chain")
    }

    private func cancel() {
        shareLog.notice("cancel() called")
        extensionContext?.cancelRequest(
            withError: NSError(domain: "com.void.smarttube.share", code: 0, userInfo: nil)
        )
    }
}

