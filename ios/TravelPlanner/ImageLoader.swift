import ImageIO
import OSLog
import SwiftUI
import TravelPlannerKit
import UIKit

/// Loads pictures once and keeps them: decoded images in memory, downloaded files on disk.
/// Small sizes are decoded straight to the size needed, which keeps swiping through many pictures fast.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private let memory = NSCache<NSString, UIImage>()
    private var running: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 600 << 20)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
        memory.totalCostLimit = 160 << 20
    }

    /// `maxPixel` limits the longer side; nil decodes the picture in full quality.
    func cached(_ address: String, maxPixel: Int?) -> UIImage? {
        memory.object(forKey: key(address, maxPixel))
    }

    func image(_ address: String, maxPixel: Int?, backend: (any TravelBackend)?) async -> UIImage? {
        let key = key(address, maxPixel)
        if let hit = memory.object(forKey: key) { return hit }
        if let task = running[key as String] { return await task.value }
        guard let request = backend?.imageRequest(for: address) else { return nil }
        let session = session
        let task = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            if request.url?.scheme == "demo" { return DemoPicture.draw(request.url, maxPixel: maxPixel) }
            var request = request
            if request.value(forHTTPHeaderField: "Authorization") == nil {
                // Image hosts of the platforms expect a browser; some refuse the bare system identifier.
                request.setValue(Self.browserAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("image/avif,image/webp,image/jpeg,image/png,image/*;q=0.8", forHTTPHeaderField: "Accept")
            }
            // One more try after a short pause covers a dropped connection or a busy image host.
            for attempt in 0..<2 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(700)) }
                do {
                    let (data, response) = try await session.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                    guard (200..<300).contains(status) else {
                        Self.log.error("Bild \(request.url?.absoluteString ?? "?", privacy: .public): Status \(status)")
                        if status == 404 || status == 403 || status == 410 { return nil }
                        continue
                    }
                    if let image = Self.decode(data, maxPixel: maxPixel) { return image }
                    let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "?"
                    Self.log.error("Bild \(request.url?.absoluteString ?? "?", privacy: .public): nicht lesbar, \(data.count) Bytes, Typ \(type, privacy: .public)")
                    return nil
                } catch {
                    Self.log.error("Bild \(request.url?.absoluteString ?? "?", privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            return nil
        }
        running[key as String] = task
        let image = await task.value
        running[key as String] = nil
        if let image {
            let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
            memory.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

    /// Starts loading without waiting, so the neighbours of the visible picture are ready when swiped to.
    func preload(_ address: String, maxPixel: Int?, backend: (any TravelBackend)?) {
        guard cached(address, maxPixel: maxPixel) == nil else { return }
        Task { _ = await image(address, maxPixel: maxPixel, backend: backend) }
    }

    nonisolated private static let log = Logger(subsystem: "com.von-bleichert.travelplanner", category: "Bilder")
    nonisolated private static let browserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private func key(_ address: String, _ maxPixel: Int?) -> NSString {
        "\(maxPixel ?? 0)|\(address)" as NSString
    }

    nonisolated private static func decode(_ data: Data, maxPixel: Int?) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        // Full quality still goes through ImageIO so the pixels are decoded here, off the main thread.
        options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel ?? 12_000
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Stand-in pictures for the sample data, so the gallery can be tried without a server.
enum DemoPicture {
    static func draw(_ url: URL?, maxPixel: Int?) -> UIImage? {
        let number = Int(url?.lastPathComponent ?? "") ?? 0
        let portrait = number % 4 == 3
        let long = CGFloat(min(maxPixel ?? 2400, 2400))
        let size = portrait ? CGSize(width: long * 0.75, height: long) : CGSize(width: long, height: long * 0.75)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let hue = CGFloat((number * 47) % 360) / 360
            let colors = [UIColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1).cgColor,
                          UIColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.55, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            // A fine grid makes sharpness visible when zooming in.
            context.cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.25).cgColor)
            context.cgContext.setLineWidth(max(1, long / 1200))
            let step = long / 16
            var x: CGFloat = 0
            while x < size.width { context.cgContext.move(to: CGPoint(x: x, y: 0)); context.cgContext.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y: CGFloat = 0
            while y < size.height { context.cgContext.move(to: CGPoint(x: 0, y: y)); context.cgContext.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            context.cgContext.strokePath()
            let text = "Beispielbild \(number % 100 + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: long / 14, weight: .semibold), .foregroundColor: UIColor.white]
            let box = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - box.width) / 2, y: (size.height - box.height) / 2), withAttributes: attributes)
        }
    }
}

/// A picture from the server or a platform, shown as soon as it is there.
struct RemoteImage: View {
    @Environment(AppModel.self) private var model
    let address: String?
    /// Longer side in pixels to decode to; nil for full quality.
    var maxPixel: Int? = 600
    var contentMode: ContentMode = .fill
    /// Shown until the picture arrives, for example the thumbnail under a full-quality picture.
    var placeholderAddress: String?
    var placeholderMaxPixel: Int? = 600

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let shown = image ?? immediate {
                Image(uiImage: shown).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(.quaternary).overlay {
                    if failed || address == nil {
                        Image(systemName: address == nil ? "house" : "photo.badge.exclamationmark").foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .task(id: address) {
            image = nil
            failed = false
            guard let address else { return }
            let loaded = await ImageLoader.shared.image(address, maxPixel: maxPixel, backend: model.backend)
            if Task.isCancelled { return }
            image = loaded
            failed = loaded == nil
        }
    }

    /// Whatever is already in memory: the picture itself or its placeholder.
    private var immediate: UIImage? {
        if let address, let hit = ImageLoader.shared.cached(address, maxPixel: maxPixel) { return hit }
        if let placeholderAddress { return ImageLoader.shared.cached(placeholderAddress, maxPixel: placeholderMaxPixel) }
        return nil
    }
}
