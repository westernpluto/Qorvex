import SwiftUI
import AVKit

struct MediaViewer: View {
    let item: ViewerItem
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var zoomed = false
    @State private var drag: CGSize = .zero
    @State private var chrome = true

    init(item: ViewerItem) {
        self.item = item
        _index = State(initialValue: item.index)
    }

    private var current: GalleryEntry { item.entries[min(index, item.entries.count - 1)] }

    private var dragProgress: Double { Double(abs(drag.height)) }

    var body: some View {
        ZStack {
            Color.black.opacity(1.0 - min(0.7, dragProgress / 500.0)).ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(item.entries.enumerated()), id: \.offset) { i, entry in
                    ViewerPage(entry: entry, zoomed: $zoomed)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: drag.height)
            .scaleEffect(CGFloat(1.0 - min(0.15, dragProgress / 2000.0)))
            .simultaneousGesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { v in
                        guard !zoomed, abs(v.translation.height) > abs(v.translation.width) else { return }
                        drag = CGSize(width: 0, height: v.translation.height)
                    }
                    .onEnded { v in
                        if !zoomed, abs(v.translation.height) > 120 || abs(v.predictedEndTranslation.height) > 400 { dismiss() }
                        else { withAnimation(.spring(duration: 0.3)) { drag = .zero } }
                    }
            )
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() } }

            if chrome {
                VStack {
                    HStack(spacing: 12) {
                        CircleButton(system: "xmark") { dismiss() }
                        Spacer()
                        if item.entries.count > 1 {
                            Text("\(index + 1) of \(item.entries.count)")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        Spacer()
                        Menu {
                            ShareLink(item: current.full) { Label("Share", systemImage: "square.and.arrow.up") }
                            Button { save() } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                            Button { UIPasteboard.general.url = current.full; Presenter.shared.show("Link copied") } label: { Label("Copy Link", systemImage: "link") }
                            Button { UIApplication.shared.open(current.full) } label: { Label("Open in Safari", systemImage: "safari") }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 16, weight: .bold))
                                .frame(width: 38, height: 38)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    Spacer()
                    if let cap = current.caption, !cap.isEmpty {
                        Text(cap)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .padding(16)
                    } else if !item.title.isEmpty {
                        Text(item.title)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(2)
                            .padding(.horizontal, 20).padding(.bottom, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden(!chrome)
        .preferredColorScheme(.dark)
    }

    private func save() {
        Task {
            guard let img = await ImageLoader.shared.load(current.full) else { Presenter.shared.show("Couldn't load image"); return }
            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
            Haptics.success()
            Presenter.shared.show("Saved to Photos")
        }
    }
}

private struct ViewerPage: View {
    let entry: GalleryEntry
    @Binding var zoomed: Bool
    @State private var image: UIImage?
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        Group {
            if let mp4 = entry.mp4 {
                Group {
                    if let player { PlayerLayerView(player: player, gravity: .resizeAspect) } else { ProgressView().tint(.white) }
                }
                .onAppear {
                    let q = AVQueuePlayer()
                    q.isMuted = true
                    looper = AVPlayerLooper(player: q, templateItem: AVPlayerItem(url: mp4))
                    player = q
                    q.play()
                }
                .onDisappear { player?.pause(); player = nil; looper = nil }
            } else if let image {
                ZoomableImage(image: image, zoomed: $zoomed)
            } else {
                ZStack {
                    if let preview = ImageLoader.shared.cached(entry.url) {
                        Image(uiImage: preview).resizable().scaledToFit()
                    }
                    ProgressView().tint(.white)
                }
            }
        }
        .ignoresSafeArea()
        .task(id: entry.id) {
            guard entry.mp4 == nil else { return }
            image = await ImageLoader.shared.load(entry.full)
            if image == nil { image = await ImageLoader.shared.load(entry.url) }
        }
    }
}

struct CircleButton: View {
    let system: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .bold))
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }
}
