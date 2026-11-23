import LinkPresentation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// What goes out when an invitation is shared. A mail gets a short text with the link behind the words
/// "Einladung annehmen"; everything else gets the bare address, which Messages and the like show as a card.
final class InviteItem: NSObject, UIActivityItemSource {
    let url: URL
    static let subject = "Einladung zum Reiseplaner"

    init(url: URL) { self.url = url }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { url }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        activityType == .mail ? Self.mailBody(url) : url
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        Self.subject
    }

    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        activityType == .mail ? UTType.html.identifier : UTType.url.identifier
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = Self.subject
        metadata.originalURL = url
        metadata.url = url
        return metadata
    }

    /// The mail as HTML. The address itself appears nowhere in the text, only behind the button.
    static func mailBody(_ url: URL) -> String {
        let address = url.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return """
        <p>Hallo,</p>
        <p>ich lade dich in unseren Reiseplaner ein. Dort sammeln wir Unterkünfte, stimmen ab und planen die Reise gemeinsam.</p>
        <p><a href="\(address)" style="display:inline-block;padding:10px 18px;background:#0f7c8a;color:#ffffff;border-radius:10px;text-decoration:none;font-weight:600">Einladung annehmen</a></p>
        <p style="color:#666666;font-size:13px">Tippe auf dem iPhone oder iPad darauf. Die Einladung gilt 14 Tage und für eine Person.</p>
        """
    }
}

/// A button that opens the system's sharing for an invitation.
struct InviteShareButton: View {
    let url: URL

    var body: some View {
        Button("Einladung senden", systemImage: "square.and.arrow.up") { present() }
    }

    private func present() {
        let sheet = UIActivityViewController(activityItems: [InviteItem(url: url)], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        // On the iPad the sharing needs a place to point at.
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        sheet.popoverPresentationController?.permittedArrowDirections = []
        top.present(sheet, animated: true)
    }
}
