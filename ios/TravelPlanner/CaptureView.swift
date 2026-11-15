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
                        Text("Stelle Zeitraum und Personen ein. Für alle Bilder: Öffne die Bildergalerie des Inserats und blättere einmal durch. Dann „Übernehmen“.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Label(page.pictureCount == 1 ? "1 Bild erkannt" : "\(page.pictureCount) Bilder erkannt", systemImage: "photo.on.rectangle")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(page.pictureCount > 0 ? Color.accentColor : Color.secondary)
                            .contentTransition(.numericText())
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
        .task {
            // Shows the count growing while the gallery is flipped through.
            while !Task.isCancelled {
                await page.refreshPictureCount()
                try? await Task.sleep(for: .seconds(1))
            }
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
    /// Large pictures the page has shown so far, including ones a gallery has since swapped out.
    var pictureCount = 0

    /// Remembers every picture of photo size as it loads (phone pages serve small versions, so the bar is low;
    /// icons and tracking pixels stay below it). Galleries keep only a few pictures in the page at a time,
    /// so the page content alone would miss most of them.
    private static let collector = """
    (function () {
      if (window.__tpImages) { return; }
      var seen = window.__tpImages = {};
      function note(img) {
        try {
          var address = img.currentSrc || img.src;
          if (address && address.indexOf('http') === 0 && img.naturalWidth >= 240 && img.naturalHeight >= 160) { seen[address] = true; }
        } catch (e) {}
      }
      document.addEventListener('load', function (event) {
        if (event.target && event.target.tagName === 'IMG') { note(event.target); }
      }, true);
      window.__tpCollect = function () {
        for (var i = 0; i < document.images.length; i++) { note(document.images[i]); }
        return Object.keys(seen);
      };
    })();
    """

    /// Walks down the page once so pictures that load on scroll are fetched, then returns to the top.
    private static let scrollThrough = """
    var start = window.scrollY;
    var step = Math.max(400, window.innerHeight * 0.9);
    for (var i = 0; i < 40; i++) {
      var before = window.scrollY;
      window.scrollBy(0, step);
      await new Promise(function (done) { setTimeout(done, 180); });
      if (window.scrollY === before) { break; }
    }
    window.scrollTo(0, start);
    await new Promise(function (done) { setTimeout(done, 300); });
    return true;
    """

    override init() {
        let configuration = WKWebViewConfiguration()
        // Cookies stay on the device between captures, so a consent banner only has to be answered once.
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.collector, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func load(_ url: URL) {
        isLoading = true
        webView.load(URLRequest(url: url))
    }

    private func pictures() async -> [String] {
        let json = try? await webView.evaluateJavaScript("JSON.stringify(window.__tpCollect ? window.__tpCollect() : [])") as? String
        guard let data = json?.data(using: .utf8), let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    func refreshPictureCount() async {
        pictureCount = await pictures().count
    }

    /// The page as rendered, plus every large picture seen while it was open.
    /// Adverts fill in their content by script after loading, so this waits until the document has
    /// stopped growing; reading at once would return an empty shell.
    func html() async throws -> String {
        _ = try? await webView.callAsyncJavaScript(Self.scrollThrough, contentWorld: .page)
        var last = -1
        var stable = 0
        for _ in 0..<16 {
            let state = try await webView.evaluateJavaScript("document.readyState + '|' + document.documentElement.outerHTML.length") as? String ?? ""
            let parts = state.split(separator: "|")
            let length = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
            // Small changes (timers, counters) are ignored; a still-rendering page grows by far more.
            stable = parts.first == "complete" && last >= 0 && abs(length - last) < 2_000 ? stable + 1 : 0
            last = length
            if stable >= 2 { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        let page = try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""
        return Self.append(pictures: await pictures(), to: page)
    }

    /// Adds the collected pictures as plain image tags, the form the server already reads pictures from.
    static func append(pictures: [String], to page: String) -> String {
        guard !pictures.isEmpty else { return page }
        let tags = pictures.map { address in
            let escaped = address.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            return "<img src=\"\(escaped)\">"
        }.joined()
        let block = "<div id=\"tp-captured-images\" hidden>\(tags)</div>"
        if let end = page.range(of: "</body>", options: [.backwards, .caseInsensitive]) {
            return page.replacingCharacters(in: end, with: block + "</body>")
        }
        return page + block
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
