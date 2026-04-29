import Foundation
import AVFoundation
import UIKit

/// Pre-extracts frames from a clip URL (YouTube/Spotify Canvas/...) so
/// `MPMediaItemAnimatedArtwork` can vend them by time on the Lock Screen.
@MainActor
final class AnimatedArtworkExtractor {
    static let shared = AnimatedArtworkExtractor()

    struct Frames {
        let images: [UIImage]
        let duration: CMTime
    }

    private var cache: [String: Frames] = [:]
    private var inFlight: [String: Task<Frames?, Never>] = [:]

    func frames(for url: URL, frameCount: Int = 30) async -> Frames? {
        let key = url.absoluteString
        if let cached = cache[key] { return cached }
        if let task = inFlight[key] { return await task.value }

        let task = Task<Frames?, Never> {
            await Self.extract(url: url, count: frameCount)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result = result {
            cache[key] = result
        }
        return result
    }

    private static func extract(url: URL, count: Int) async -> Frames? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)

        let duration: CMTime
        if #available(iOS 16.0, *) {
            do {
                duration = try await asset.load(.duration)
            } catch {
                return nil
            }
        } else {
            duration = asset.duration
        }
        let totalSeconds = CMTimeGetSeconds(duration)
        guard totalSeconds.isFinite, totalSeconds > 0 else { return nil }

        let cappedSeconds = min(totalSeconds, 12)
        let step = cappedSeconds / Double(max(count, 1))
        var images: [UIImage] = []
        images.reserveCapacity(count)

        for i in 0..<count {
            let t = CMTime(seconds: Double(i) * step, preferredTimescale: 600)
            if let cg = try? generator.copyCGImage(at: t, actualTime: nil) {
                images.append(UIImage(cgImage: cg))
            }
        }
        guard !images.isEmpty else { return nil }
        return Frames(
            images: images,
            duration: CMTime(seconds: cappedSeconds, preferredTimescale: 600)
        )
    }
}
