import SwiftUI
import TravelPlannerKit
import WebKit

/// Opens an advert inside the app and hands the loaded page to the server.
/// Needed for platforms that refuse requests from the server (FeWo-direkt, Casamundo):
/// here the page loads like in any browser, on the user's own device.
struct CaptureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: ListingSource
    let candidateID: String

    @State private var page = WebPage()
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if page.isLoading { ProgressView().progressViewStyle(.linear) }
                WebViewContainer(webView: page.webView)
                VStack(spacing: 8) {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                    } else {
                        Text("Warte, bis das Inserat vollständig zu sehen ist. Stimmen Zeitraum und Personenzahl, tippe auf „Übernehmen“.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button {
                        capture()
                    } label: {
                        if sending { ProgressView() } else { Text("Übernehmen").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(sending || page.isLoading)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle(Format.platformName(source.platform))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Neu laden", systemImage: "arrow.clockwise") { page.webView.reload() }
                }
            }
        }
        .onAppear {
            if let url = URL(string: source.url) { page.load(url) }
        }
    }

    private func capture() {
        guard let backend = model.backend else { return }
        sending = true
        error = nil
        Task {
            do {
                let html = try await page.html()
                guard html.count >= 500 else {
                    throw APIError(status: 0, code: "empty_page", message: "Die Seite ist noch leer. Warte kurz und versuche es erneut.")
                }
                try await backend.capture(candidateId: candidateID, html: html)
                model.dataChanged()
                dismiss()
            } catch {
                self.error = model.message(for: error)
            }
            sending = false
        }
    }
}

@MainActor
@Observable
final class WebPage: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var isLoading = false

    override init() {
        let configuration = WKWebViewConfiguration()
        // Cookies stay on the device between captures, so a consent banner only has to be answered once.
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func load(_ url: URL) {
        isLoading = true
        webView.load(URLRequest(url: url))
    }

    func html() async throws -> String {
        let result = try await webView.evaluateJavaScript("document.documentElement.outerHTML")
        return result as? String ?? ""
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { isLoading = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isLoading = false }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { isLoading = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { isLoading = false }
}

private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
