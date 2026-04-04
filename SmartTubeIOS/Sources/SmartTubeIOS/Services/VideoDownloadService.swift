import Foundation
import AVFoundation
import Photos
import Observation
import os
import SmartTubeIOSCore

private let downloadLog = Logger(subsystem: appSubsystem, category: "Download")

// MARK: - VideoDownloadService
//
// Downloads a YouTube video stream to the device's Photos library.
// Uses InnerTubeAPI to resolve the best stream URL, then downloads the
// file to a temp location before saving it via PHPhotoLibrary.

@MainActor
@Observable
public final class VideoDownloadService {

    // MARK: - State

    public enum DownloadState: Equatable {
        case idle
        case fetching
        case downloading(progress: Double)
        case saving
        case done
        case failed(String)

        public var isActive: Bool {
            switch self {
            case .fetching, .downloading, .saving: return true
            default: return false
            }
        }
    }

    public private(set) var state: DownloadState = .idle

    // MARK: - Private

    private let api: InnerTubeAPI
    private var downloadTask: Task<Void, Never>?

    /// URLSession used for all YouTube CDN downloads.
    /// httpAdditionalHeaders cannot override User-Agent on iOS — must use URLRequest.setValue.
    private static let cdnSession = URLSession(configuration: .default)

    /// Builds a URLRequest for a YouTube CDN URL with the iOS YouTube User-Agent.
    /// googlevideo.com validates the UA matches the client that signed the URL.
    nonisolated private static func cdnRequest(for url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(InnerTubeClients.iOS.userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    // MARK: - Init

    public init(api: InnerTubeAPI = InnerTubeAPI()) {
        self.api = api
    }

    // MARK: - Public

    public func updateAuthToken(_ token: String?) {
        Task { await api.setAuthToken(token) }
    }

    public func download(video: Video) {
        guard !state.isActive else { return }
        state = .fetching
        downloadTask = Task { await performDownload(video: video) }
    }

    public func reset() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .idle
    }

    // MARK: - Private implementation

    private func performDownload(video: Video) async {
        do {
            // Attempt 1: Web client — returns muxed itag 18/22 MP4 for most public videos.
            // Attempt 2: Authenticated TV client — for membership/age-restricted videos.
            // Attempt 3: iOS client HLS export via AVAssetExportSession — universal fallback.
            guard await requestPhotoAddAccess() else {
                state = .failed("Photo library access is required to save the video")
                return
            }

            if let tempURL = await tryDirectDownload(videoId: video.id) {
                // YouTube's muxed MP4 often has the moov atom at the end (non-fast-start),
                // which causes PHPhotosErrorDomain 3302. Passthrough-remux rewrites the
                // container with moov-at-front without re-encoding any codec data.
                downloadLog.notice("[download] remuxing for Photos compatibility")
                let photosURL = try await passthroughRemux(inputURL: tempURL, videoId: video.id, suffix: "muxed")
                try? FileManager.default.removeItem(at: tempURL)
                state = .saving
                try await saveToPhotoLibrary(fileURL: photosURL)
                try? FileManager.default.removeItem(at: photosURL)
                downloadLog.notice("[download] ✅ saved to Photos \(video.id, privacy: .public)")
                state = .done
                return
            }

            // All direct download attempts failed — merge best adaptive video+audio streams.
            // AVAssetExportSession cannot export networked HLS; instead we download the
            // best video-only and audio-only MP4 adaptive streams and merge them locally.
            downloadLog.notice("[download] direct download failed, trying adaptive merge fallback")
            let iosInfo = try await api.fetchPlayerInfo(videoId: video.id)
            downloadLog.notice("[download] adaptive fallback formats=\(iosInfo.formats.count, privacy: .public)")
            for (i, fmt) in iosInfo.formats.enumerated() {
                downloadLog.notice("[download]   [\(i, privacy: .public)] mime=\(fmt.mimeType, privacy: .public) label=\(fmt.label, privacy: .public) hasURL=\(fmt.url != nil, privacy: .public) bitrate=\(fmt.bitrate ?? 0, privacy: .public)")
            }
            guard let videoURL = iosInfo.bestAdaptiveVideoURL,
                  let audioURL = iosInfo.bestAdaptiveAudioURL else {
                downloadLog.error("[download] ❌ no adaptive video/audio streams found")
                state = .failed("No downloadable stream found for this video")
                return
            }
            downloadLog.notice("[download] merging adaptive videoURL prefix=\(videoURL.absoluteString.prefix(60), privacy: .public)")
            downloadLog.notice("[download] merging adaptive audioURL prefix=\(audioURL.absoluteString.prefix(60), privacy: .public)")
            state = .downloading(progress: 0)
            let mergedURL = try await mergeAdaptiveStreams(videoURL: videoURL, audioURL: audioURL, videoId: video.id)
            state = .saving
            try await saveToPhotoLibrary(fileURL: mergedURL)
            try? FileManager.default.removeItem(at: mergedURL)
            downloadLog.notice("[download] ✅ adaptive merge saved to Photos \(video.id, privacy: .public)")
            state = .done
        } catch is CancellationError {
            state = .idle
        } catch {
            downloadLog.error("[download] ❌ failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Tries Web client then authenticated TV client for a direct muxed MP4 download.
    /// Returns the temp file URL on success, nil if no muxed stream could be found.
    private func tryDirectDownload(videoId: String) async -> URL? {
        let candidates: [(String, () async throws -> PlayerInfo)] = [
            ("Web", { [self] in try await api.fetchPlayerInfoForDownload(videoId: videoId) }),
            ("TV-auth", { [self] in try await api.fetchPlayerInfoAuthenticated(videoId: videoId) }),
        ]
        for (label, fetch) in candidates {
            guard let info = try? await fetch() else {
                downloadLog.notice("[download] \(label, privacy: .public) client failed or UNPLAYABLE, trying next")
                continue
            }
            downloadLog.notice("[download] \(label, privacy: .public) formats=\(info.formats.count, privacy: .public) hlsURL=\(info.hlsURL != nil, privacy: .public)")
            for (i, fmt) in info.formats.enumerated() {
                downloadLog.notice("[download]   [\(i, privacy: .public)] mime=\(fmt.mimeType, privacy: .public) label=\(fmt.label, privacy: .public) hasURL=\(fmt.url != nil, privacy: .public) bitrate=\(fmt.bitrate ?? 0, privacy: .public)")
            }
            guard let muxedURL = info.bestMuxedDownloadURL else {
                downloadLog.notice("[download] \(label, privacy: .public) — no muxed MP4, trying next")
                continue
            }
            downloadLog.notice("[download] \(label, privacy: .public) ✅ muxed URL found, downloading")
            state = .downloading(progress: 0)
            if let tempURL = try? await downloadToTemp(url: muxedURL, videoId: videoId) {
                let size = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? 0
                downloadLog.notice("[download] \(label, privacy: .public) download complete bytes=\(size, privacy: .public)")
                guard size > 0 else {
                    downloadLog.notice("[download] \(label, privacy: .public) — 0 bytes, YouTube rejected URL, trying next")
                    try? FileManager.default.removeItem(at: tempURL)
                    continue
                }
                return tempURL
            }
        }
        return nil
    }

    /// Remuxes an MP4 file into a new container using passthrough (no re-encoding).
    /// Fixes PHPhotosErrorDomain 3302 caused by moov-at-end MP4 containers from YouTube.
    private nonisolated func passthroughRemux(inputURL: URL, videoId: String, suffix: String) async throws -> URL {
        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(videoId)-\(suffix)-remux.mp4")
        try? FileManager.default.removeItem(at: destURL)
        let asset = AVURLAsset(url: inputURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw URLError(.badServerResponse)
        }
        session.outputURL = destURL
        session.outputFileType = .mp4
        await session.export()
        if let error = session.error {
            downloadLog.error("[download] passthrough remux error: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0
        downloadLog.notice("[download] passthrough remux done bytes=\(size, privacy: .public)")
        return destURL
    }

    /// Downloads best adaptive video-only and audio-only MP4 streams concurrently,
    /// then merges them into a single MP4 using AVAssetWriter for true passthrough
    /// (sample-level copy, no re-encode of codec data).
    private nonisolated func mergeAdaptiveStreams(videoURL: URL, audioURL: URL, videoId: String) async throws -> URL {
        // Download both streams concurrently with explicit iOS UA per-request
        let videoReq = VideoDownloadService.cdnRequest(for: videoURL)
        let audioReq = VideoDownloadService.cdnRequest(for: audioURL)
        async let videoTemp = VideoDownloadService.cdnSession.download(for: videoReq)
        async let audioTemp = VideoDownloadService.cdnSession.download(for: audioReq)
        let (videoResult, audioResult) = try await (videoTemp, audioTemp)

        let videoStatus = (videoResult.1 as? HTTPURLResponse)?.statusCode ?? 0
        let audioStatus = (audioResult.1 as? HTTPURLResponse)?.statusCode ?? 0
        let videoFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(videoId)-vid.mp4")
        let audioFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(videoId)-aud.mp4")
        try? FileManager.default.removeItem(at: videoFile)
        try? FileManager.default.removeItem(at: audioFile)
        try FileManager.default.moveItem(at: videoResult.0, to: videoFile)
        try FileManager.default.moveItem(at: audioResult.0, to: audioFile)

        let videoSize = (try? FileManager.default.attributesOfItem(atPath: videoFile.path)[.size] as? Int) ?? 0
        let audioSize = (try? FileManager.default.attributesOfItem(atPath: audioFile.path)[.size] as? Int) ?? 0
        downloadLog.notice("[download] adaptive downloaded videoStatus=\(videoStatus, privacy: .public) video=\(videoSize, privacy: .public)B audioStatus=\(audioStatus, privacy: .public) audio=\(audioSize, privacy: .public)B")

        defer {
            try? FileManager.default.removeItem(at: videoFile)
            try? FileManager.default.removeItem(at: audioFile)
        }

        guard videoSize > 0, audioSize > 0 else {
            throw URLError(.zeroByteResource)
        }

        let destURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(videoId)-merged.mp4")
        try? FileManager.default.removeItem(at: destURL)

        // Use AVAssetWriter for true passthrough mux — reads compressed samples directly
        // from the source tracks and writes them to the new container without decoding.
        let videoAsset = AVURLAsset(url: videoFile)
        let audioAsset = AVURLAsset(url: audioFile)

        let videoTrackSrc = try await videoAsset.loadTracks(withMediaType: .video).first
        let audioTrackSrc = try await audioAsset.loadTracks(withMediaType: .audio).first
        guard let videoTrackSrc, let audioTrackSrc else {
            throw URLError(.badServerResponse)
        }

        let videoFmt = try await videoTrackSrc.load(.formatDescriptions).first as! CMFormatDescription
        let audioFmt = try await audioTrackSrc.load(.formatDescriptions).first as! CMFormatDescription
        let duration  = try await videoAsset.load(.duration)

        let writer = try AVAssetWriter(outputURL: destURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFmt)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFmt)
        videoInput.expectsMediaDataInRealTime = false
        audioInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        writer.add(audioInput)

        let videoReader = try AVAssetReader(asset: videoAsset)
        let audioReader = try AVAssetReader(asset: audioAsset)
        let videoOut  = AVAssetReaderTrackOutput(track: videoTrackSrc, outputSettings: nil)
        let audioOut  = AVAssetReaderTrackOutput(track: audioTrackSrc, outputSettings: nil)
        videoOut.alwaysCopiesSampleData = false
        audioOut.alwaysCopiesSampleData = false
        videoReader.add(videoOut)
        audioReader.add(audioOut)

        writer.startWriting()
        videoReader.startReading()
        audioReader.startReading()
        writer.startSession(atSourceTime: .zero)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "com.smarttube.merge", qos: .userInitiated)

            group.enter()
            videoInput.requestMediaDataWhenReady(on: queue) {
                while videoInput.isReadyForMoreMediaData {
                    if let buf = videoOut.copyNextSampleBuffer() {
                        videoInput.append(buf)
                    } else {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            group.enter()
            audioInput.requestMediaDataWhenReady(on: queue) {
                while audioInput.isReadyForMoreMediaData {
                    if let buf = audioOut.copyNextSampleBuffer() {
                        audioInput.append(buf)
                    } else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            group.notify(queue: queue) {
                writer.finishWriting {
                    if let err = writer.error {
                        cont.resume(throwing: err)
                    } else {
                        cont.resume()
                    }
                }
            }
        }

        let mergedSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0
        downloadLog.notice("[download] adaptive merge done bytes=\(mergedSize, privacy: .public)")
        _ = duration // suppress unused warning
        return destURL
    }

    private func requestPhotoAddAccess() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch current {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return granted == .authorized || granted == .limited
        default:
            return false
        }
    }

    private func downloadToTemp(url: URL, videoId: String) async throws -> URL {
        let req = VideoDownloadService.cdnRequest(for: url)
        let (tempURL, response) = try await VideoDownloadService.cdnSession.download(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let size = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? 0
        downloadLog.notice("[download] downloadToTemp status=\(status, privacy: .public) bytes=\(size, privacy: .public)")
        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(videoId).mp4")
        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        return destURL
    }

    // nonisolated so the closures passed to performChanges carry no @MainActor
    // isolation — Photos calls them on its own serial queue and would crash if
    // the closures were actor-isolated (libdispatch queue assertion).
    private nonisolated func saveToPhotoLibrary(fileURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            }, completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: URLError(.unknown))
                }
            })
        }
    }
}
