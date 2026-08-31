import Foundation
import AVFoundation

/// Plays the original recording without taking ownership of it.
///
/// A transcript stores only the file path. Missing files are an ordinary
/// state: recordings are intentionally deleted after the meetings they came
/// from, and the transcript remains useful without playback.
@MainActor
final class AudioPlaybackService: ObservableObject {

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorMessage: String?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private(set) var loadedURLs: [URL] = []

    deinit {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func load(_ url: URL) {
        load([url])
    }

    /// Loads one source, or a microphone/system pair that starts together.
    /// AVPlayer receives one composition, so play, pause and seeking remain
    /// sample-synchronised from the UI's point of view.
    func load(_ urls: [URL]) {
        guard !urls.isEmpty, loadedURLs != urls else { return }
        unload()

        let item: AVPlayerItem
        if urls.count == 1 {
            item = AVPlayerItem(url: urls[0])
        } else {
            let composition = AVMutableComposition()
            for url in urls {
                let asset = AVURLAsset(url: url)
                guard let source = asset.tracks(withMediaType: .audio).first,
                      let destination = composition.addMutableTrack(withMediaType: .audio,
                                                                     preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try? destination.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration),
                                                 of: source,
                                                 at: .zero)
            }
            item = AVPlayerItem(asset: composition)
        }
        let player = AVPlayer(playerItem: item)
        self.player = player
        loadedURLs = urls
        errorMessage = nil

        let asset = item.asset
        Task { [weak self] in
            guard let self else { return }
            do {
                let time = try await asset.load(.duration)
                let seconds = CMTimeGetSeconds(time)
                guard self.loadedURLs == urls else { return }
                self.duration = seconds.isFinite && seconds > 0 ? seconds : 0
            } catch {
                guard self.loadedURLs == urls else { return }
                self.errorMessage = "Could not read the audio duration: \(error.localizedDescription)"
            }
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                self.currentTime = seconds.isFinite ? max(0, seconds) : 0
                self.isPlaying = player.timeControlStatus == .playing
                if self.duration == 0 {
                    let itemDuration = CMTimeGetSeconds(item.duration)
                    if itemDuration.isFinite && itemDuration > 0 { self.duration = itemDuration }
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.currentTime = self?.duration ?? 0
            }
        }
    }

    func unload() {
        player?.pause()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        loadedURLs = []
        isPlaying = false
        currentTime = 0
        duration = 0
        errorMessage = nil
    }

    func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0 && currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    func play(from seconds: Double) {
        seek(to: seconds)
        player?.play()
        isPlaying = player != nil
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let upper = duration > 0 ? duration : seconds
        let destination = min(max(seconds, 0), upper)
        player.seek(to: CMTime(seconds: destination, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero)
        currentTime = destination
    }
}
