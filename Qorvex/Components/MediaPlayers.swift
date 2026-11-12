import SwiftUI
import AVKit
import SafariServices

// MARK: - Inline looping video (feed)

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        v.backgroundColor = .black
        return v
    }
    func updateUIView(_ v: PlayerUIView, context: Context) {
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
    }
}

/// Muted, looping, autoplaying video that only plays while on screen.
struct InlineVideo: View {
    let info: VideoInfo
    var detail = false
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var muted = true
    @State private var playing = false

    var body: some View {
        ZStack {
            if let poster = info.poster { RemoteImage(url: poster) } else { Color.black }
            if let player {
                PlayerLayerView(player: player, gravity: detail ? .resizeAspect : .resizeAspectFill)
                    .opacity(playing ? 1 : 0.001)
            }
            if !playing && AppSettings.shared.autoplay == .never {
                Image(systemName: "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 8) {
                if let d = info.duration, d > 0, !info.isGif {
                    Text(String(format: "%d:%02d", d / 60, d % 60))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                if !info.isGif {
                    Button {
                        muted.toggle()
                        player?.isMuted = muted
                        if !muted { try? AVAudioSession.sharedInstance().setCategory(.playback) }
                        Haptics.tap()
                    } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.caption.weight(.bold))
                            .frame(width: 30, height: 30)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(.white)
            .padding(10)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = info.playURL { Presenter.shared.video = VideoItem(url: url) }
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private func start() {
        guard let url = info.playURL else { return }
        if player == nil {
            let item = AVPlayerItem(url: url)
            item.preferredPeakBitRate = AppSettings.shared.dataSaver ? 800_000 : 0
            let q = AVQueuePlayer()
            q.isMuted = true
            q.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: q, templateItem: item)
            player = q
        }
        guard AppSettings.shared.autoplay == .always else { return }
        player?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation(.easeIn(duration: 0.2)) { playing = true } }
    }

    private func stop() {
        player?.pause()
        playing = false
        player = nil
        looper = nil
    }
}

// MARK: - Fullscreen native player

struct FullscreenPlayer: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        let vc = AVPlayerViewController()
        let p = AVPlayer(url: url)
        p.isMuted = false
        vc.player = p
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        p.play()
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: ()) { vc.player?.pause() }
}

// MARK: - In-app browser

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let cfg = SFSafariViewController.Configuration()
        cfg.entersReaderIfAvailable = AppSettings.shared.readerMode
        cfg.barCollapsingEnabled = true
        let vc = SFSafariViewController(url: url, configuration: cfg)
        vc.preferredControlTintColor = UIColor(AppSettings.shared.accent.color)
        vc.dismissButtonStyle = .close
        return vc
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

// MARK: - Zoomable image (UIScrollView for real pinch/double-tap zoom)

struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.delegate = context.coordinator
        sv.maximumZoomScale = 6
        sv.minimumZoomScale = 1
        sv.bouncesZoom = true
        sv.showsVerticalScrollIndicator = false
        sv.showsHorizontalScrollIndicator = false
        sv.contentInsetAdjustmentBehavior = .never
        sv.backgroundColor = .clear
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.isUserInteractionEnabled = true
        iv.translatesAutoresizingMaskIntoConstraints = false
        sv.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.widthAnchor.constraint(equalTo: sv.frameLayoutGuide.widthAnchor),
            iv.heightAnchor.constraint(equalTo: sv.frameLayoutGuide.heightAnchor),
            iv.leadingAnchor.constraint(equalTo: sv.contentLayoutGuide.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: sv.contentLayoutGuide.trailingAnchor),
            iv.topAnchor.constraint(equalTo: sv.contentLayoutGuide.topAnchor),
            iv.bottomAnchor.constraint(equalTo: sv.contentLayoutGuide.bottomAnchor),
        ])
        context.coordinator.imageView = iv
        let dbl = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        sv.addGestureRecognizer(dbl)
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.imageView?.image !== image { context.coordinator.imageView?.image = image }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableImage
        weak var imageView: UIImageView?
        init(_ p: ZoomableImage) { parent = p }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func scrollViewDidZoom(_ sv: UIScrollView) {
            let z = sv.zoomScale > 1.01
            if z != parent.zoomed { DispatchQueue.main.async { self.parent.zoomed = z } }
        }
        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = g.view as? UIScrollView else { return }
            if sv.zoomScale > 1 { sv.setZoomScale(1, animated: true); return }
            let p = g.location(in: imageView)
            let w = sv.bounds.width / 2.5, h = sv.bounds.height / 2.5
            sv.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
        }
    }
}
