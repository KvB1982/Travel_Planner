import SwiftUI
import TravelPlannerKit
import UIKit

enum PhotoSize {
    /// Decoded size of strip pictures and thumbnails, in pixels of the longer side.
    static let strip = 900
    static let thumb = 240
}

extension Photo {
    /// The small version where the server has one, otherwise the picture itself.
    var stripAddress: String { thumbUrl ?? url }
}

/// The pictures of an offer as a strip to swipe through. A tap opens the picture full screen.
/// The strip runs freely with the swipe's own momentum and comes to rest wherever it stops, like any list.
struct PhotoStrip: View {
    @Environment(AppModel.self) private var model
    let photos: [Photo]

    /// The photo at the leading edge of the strip, counted from 0. Only read off the scrolling, never set on it:
    /// a position tied to the strip made it stop at the next photo instead of running on with the swipe.
    @State private var index = 0
    /// A photo to bring to the front, after the full-screen view closed on it.
    @State private var jump: String?
    @State private var viewer: ViewerStart?

    private struct ViewerStart: Identifiable {
        let id: String
    }

    private let height: CGFloat = 240
    private let spacing: CGFloat = 6

    /// Which photo sits at the given distance from the start of the strip.
    private func index(at offset: CGFloat) -> Int {
        var x: CGFloat = 0
        for (number, photo) in photos.enumerated() {
            let width = width(of: photo) + spacing
            if offset < x + width / 2 { return number }
            x += width
        }
        return max(0, photos.count - 1)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: spacing) {
                    ForEach(photos) { photo in
                        Button {
                            viewer = ViewerStart(id: photo.id)
                        } label: {
                            RemoteImage(address: photo.stripAddress, maxPixel: PhotoSize.strip)
                                .frame(width: width(of: photo), height: height)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(label(for: photo))
                        .id(photo.id)
                    }
                }
            }
            .onScrollGeometryChange(for: Int.self) { geometry in
                index(at: geometry.contentOffset.x + geometry.contentInsets.leading)
            } action: { _, now in
                index = now
            }
            .onChange(of: jump) {
                guard let target = jump else { return }
                proxy.scrollTo(target, anchor: .leading)
                jump = nil
            }
        }
        .frame(height: height)
        .overlay(alignment: .bottomTrailing) {
            if photos.count > 1 {
                Label("\(index + 1) / \(photos.count)", systemImage: "photo.on.rectangle")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: index) { preloadAround(index) }
        .onAppear { preloadAround(0) }
        .fullScreenCover(item: $viewer) { start in
            PhotoViewer(photos: photos, startID: start.id) { last in
                jump = last
            }
        }
    }

    private func width(of photo: Photo) -> CGFloat {
        let ratio = min(max(photo.aspectRatio ?? 4.0 / 3.0, 0.6), 1.9)
        return (height * ratio).rounded()
    }

    private func label(for photo: Photo) -> String {
        let index = (photos.firstIndex(of: photo) ?? 0) + 1
        return photo.caption.map { "Bild \(index) von \(photos.count): \($0)" } ?? "Bild \(index) von \(photos.count)"
    }

    private func preloadAround(_ index: Int) {
        for offset in 1...3 where photos.indices.contains(index + offset) {
            ImageLoader.shared.preload(photos[index + offset].stripAddress, maxPixel: PhotoSize.strip, backend: model.backend)
        }
    }
}

/// Full screen: one picture at a time in full quality, pinch or double-tap to zoom, thumbnails below to jump.
struct PhotoViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let photos: [Photo]
    let startID: String
    var onClose: (String) -> Void = { _ in }

    @State private var current: String = ""
    @State private var chromeHidden = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $current) {
                ForEach(photos) { photo in
                    FullPhoto(photo: photo)
                        .tag(photo.id)
                        .ignoresSafeArea()
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } }

            if !chromeHidden {
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            close()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.headline)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("Schließen")
                        Spacer()
                        Text("\(index + 1) von \(photos.count)")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                        Color.clear.frame(width: 44, height: 44)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    Spacer()

                    if let caption = photos[safe: index]?.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.callout)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 8)
                    }
                    if photos.count > 1 { thumbnails }
                }
                .foregroundStyle(.white)
                .transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(chromeHidden)
        .onAppear {
            current = startID
            preloadAround(index)
        }
        .onChange(of: current) { preloadAround(index) }
    }

    private var index: Int {
        photos.firstIndex { $0.id == current } ?? 0
    }

    private func close() {
        onClose(current)
        dismiss()
    }

    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(photos) { photo in
                        Button {
                            current = photo.id
                        } label: {
                            RemoteImage(address: photo.stripAddress, maxPixel: PhotoSize.thumb)
                                .frame(width: 60, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6).strokeBorder(.white, lineWidth: photo.id == current ? 2 : 0)
                                }
                                .opacity(photo.id == current ? 1 : 0.55)
                        }
                        .buttonStyle(.plain)
                        .id(photo.id)
                    }
                }
                .padding(.horizontal)
            }
            .frame(height: 52)
            .padding(.bottom, 8)
            .onChange(of: current) {
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(current, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(startID, anchor: .center) }
        }
    }

    /// The pictures next to the visible one are fetched in full quality ahead of the swipe.
    private func preloadAround(_ index: Int) {
        for offset in [1, -1, 2] where photos.indices.contains(index + offset) {
            ImageLoader.shared.preload(photos[index + offset].url, maxPixel: nil, backend: model.backend)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// One picture in full quality. The strip version is shown at once and replaced when the original has loaded.
private struct FullPhoto: View {
    @Environment(AppModel.self) private var model
    let photo: Photo

    @State private var full: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image = full ?? ImageLoader.shared.cached(photo.url, maxPixel: nil) ?? preview {
                ZoomableImage(image: image)
            } else if failed {
                ContentUnavailableView("Bild nicht geladen", systemImage: "photo.badge.exclamationmark")
            } else {
                ProgressView().controlSize(.large)
            }
            if full == nil && !failed && preview != nil {
                ProgressView()
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 20)
                    .padding(.bottom, 90)
            }
        }
        .task(id: photo.id) {
            let loaded = await ImageLoader.shared.image(photo.url, maxPixel: nil, backend: model.backend)
            if Task.isCancelled { return }
            full = loaded
            failed = loaded == nil
        }
    }

    private var preview: UIImage? {
        ImageLoader.shared.cached(photo.stripAddress, maxPixel: PhotoSize.strip)
            ?? ImageLoader.shared.cached(photo.stripAddress, maxPixel: PhotoSize.thumb)
    }
}

/// Pinch to zoom up to the picture's real pixels and beyond, double-tap to zoom in and out.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.bouncesZoom = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        let view = context.coordinator.imageView
        view.contentMode = .scaleAspectFit
        view.frame = scroll.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(view)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        context.coordinator.scroll = scroll
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let view = context.coordinator.imageView
        guard view.image !== image else { return }
        // Swapping the preview for the original keeps the current zoom.
        view.image = image
        let fitted = max(image.size.width / max(scroll.bounds.width, 1), image.size.height / max(scroll.bounds.height, 1))
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = max(4, fitted * 2)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        weak var scroll: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let scale = min(3, scroll.maximumZoomScale)
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}
