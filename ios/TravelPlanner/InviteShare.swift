import LinkPresentation
import MessageUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// What goes out when an invitation is shared through the system's sharing: the bare address, which Messages and
/// the like show as a card. Mail is not offered there: the sharing hands text to Mail as plain text, so a formatted
/// mail has its own button.
final class InviteItem: NSObject, UIActivityItemSource {
    let url: URL
    static let subject = "Einladung zum Reiseplaner"

    init(url: URL) { self.url = url }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { url }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { url }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        Self.subject
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
        <html><body>
        <p>Hallo,</p>
        <p>ich lade dich in unseren Reiseplaner ein. Dort sammeln wir Unterkünfte, stimmen ab und planen die Reise gemeinsam.</p>
        <p><a href="\(address)" style="display:inline-block;padding:10px 18px;background:#0f7c8a;color:#ffffff;border-radius:10px;text-decoration:none;font-weight:600">Einladung annehmen</a></p>
        <p style="color:#666666;font-size:13px">Tippe auf dem iPhone oder iPad darauf. Die Einladung gilt 14 Tage und für eine Person.</p>
        </body></html>
        """
    }
}

/// The top view on screen, to present the system's own sheets from.
@MainActor private func topController() -> UIViewController? {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
          var top = scene.keyWindow?.rootViewController else { return nil }
    while let next = top.presentedViewController { top = next }
    return top
}

/// Closes the mail window when the person has sent or dropped the mail.
private final class MailCloser: NSObject, MFMailComposeViewControllerDelegate {
    static let shared = MailCloser()
    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        controller.dismiss(animated: true)
    }
}

/// A button that opens a ready mail with the invitation behind the words "Einladung annehmen".
/// Only there when the device has Mail set up; otherwise the sharing is the way.
struct InviteMailButton: View {
    let url: URL

    var body: some View {
        if MFMailComposeViewController.canSendMail() {
            Button("Per Mail", systemImage: "envelope") {
                let mail = MFMailComposeViewController()
                mail.mailComposeDelegate = MailCloser.shared
                mail.setSubject(InviteItem.subject)
                mail.setMessageBody(InviteItem.mailBody(url), isHTML: true)
                topController()?.present(mail, animated: true)
            }
        }
    }
}

/// A button that opens the system's sharing for an invitation.
struct InviteShareButton: View {
    let url: URL

    var body: some View {
        Button("Teilen", systemImage: "square.and.arrow.up") { present() }
    }

    private func present() {
        let sheet = UIActivityViewController(activityItems: [InviteItem(url: url)], applicationActivities: nil)
        // Mail has its own button with a formatted text, where the device has Mail set up.
        if MFMailComposeViewController.canSendMail() { sheet.excludedActivityTypes = [.mail] }
        guard let top = topController() else { return }
        // On the iPad the sharing needs a place to point at.
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        sheet.popoverPresentationController?.permittedArrowDirections = []
        top.present(sheet, animated: true)
    }
}
