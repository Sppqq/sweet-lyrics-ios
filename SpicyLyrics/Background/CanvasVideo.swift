import AVFoundation
import SwiftUI
import UIKit

/// A song's Canvas: its short video looping without sound behind the lyrics, filling the screen.
/// Paused with the song; the app's audio session mixes with others, so it never stops the music.
struct CanvasVideoView: UIViewRepresentable {
    let url: URL
    var playing = true
    /// The first frame is on screen (true) or a new video is loading (false).
    var onReady: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> CanvasPlayerView { CanvasPlayerView() }

    func updateUIView(_ view: CanvasPlayerView, context: Context) {
        view.onReady = onReady
        view.load(url)
        view.setPlaying(playing)
    }

    static func dismantleUIView(_ view: CanvasPlayerView, coordinator: ()) {
        view.stop()
    }
}

final class CanvasPlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var url: URL?
    private var playing = true
    private var readyObservation: NSKeyValueObservation?
    var onReady: (Bool) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspectFill
        // Fades in once the first frame is ready, over the cover underneath.
        alpha = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(_ url: URL) {
        guard url != self.url else { return }
        self.url = url
        stop()
        alpha = 0
        // Called from SwiftUI's update: report it after, not during.
        DispatchQueue.main.async { [weak self] in self?.onReady(false) }
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: item)
        playerLayer.player = player
        self.player = player
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                UIView.animate(withDuration: 0.8) { self?.alpha = 1 } completion: { finished in
                    if finished { self?.onReady(true) }
                }
            }
        }
        if playing { player.play() }
    }

    func setPlaying(_ playing: Bool) {
        self.playing = playing
        if playing { player?.play() } else { player?.pause() }
    }

    func stop() {
        readyObservation = nil
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        playerLayer.player = nil
    }
}
