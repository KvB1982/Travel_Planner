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
    /// Set when the page belongs to a further source of the offer, not the leading one.
    var sourceID: String?

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
                        Text("Stelle Zeitraum und Personen ein. Für alle Bilder und Bewertungen: Blättere die Bildergalerie des Inserats einmal durch und klappe die Bewertungen auf. Dann „Übernehmen“.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Label(page.pictureCount == 1 ? "1 Bild des Inserats erkannt" : "\(page.pictureCount) Bilder des Inserats erkannt", systemImage: "photo.on.rectangle")
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
                try await backend.capture(candidateId: candidateID, html: html, sourceId: sourceID)
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
      // A photo belongs to the advert's own gallery unless it is part of a card that leads to another page
      // (similar adverts, recommendations) or sits in the page's navigation or footer. Anything in an open dialog counts.
      function elsewhere(link) {
        try {
          var target = new URL(link.getAttribute('href'), location.href);
          if (target.protocol !== 'http:' && target.protocol !== 'https:') { return false; }
          return target.origin !== location.origin || target.pathname !== location.pathname;
        } catch (e) { return false; }
      }
      function own(img) {
        try {
          if (img.closest('[role="dialog"], [aria-modal="true"], dialog')) { return true; }
          if (img.closest('nav, footer, header')) { return false; }
          var link = img.closest('a[href]');
          if (link && elsewhere(link)) { return false; }
          // Cards often lay the link over the picture instead of wrapping it: look at the boxes around the
          // picture for a link that leads away. A card is the picture plus a few lines of text, so the search
          // stops once a box is much taller than the picture. Width says nothing: sliders are many pictures wide.
          var box = img.getBoundingClientRect();
          var parent = img.parentElement;
          for (var level = 0; parent && parent !== document.body && level < 10; level++) {
            if (box.height > 0 && parent.getBoundingClientRect().height > box.height * 2.5) { break; }
            var links = parent.querySelectorAll('a[href]');
            for (var i = 0; i < links.length; i++) { if (elsewhere(links[i])) { return false; } }
            parent = parent.parentElement;
          }
          return true;
        } catch (e) { return false; }
      }
      function note(img) {
        try {
          var address = img.currentSrc || img.src;
          if (address && address.indexOf('http') === 0 && img.naturalWidth >= 240 && img.naturalHeight >= 160) {
            seen[address] = seen[address] === true || own(img);
          }
        } catch (e) {}
      }
      document.addEventListener('load', function (event) {
        if (event.target && event.target.tagName === 'IMG') { note(event.target); }
      }, true);
      // The single reviews as shown on the page: the longest run of similar neighbouring blocks of text
      // inside something that talks about reviews. Cards that link to other adverts are not reviews.
      window.__tpReviews = function () {
        try {
          var roots = Array.prototype.slice.call(document.querySelectorAll(
            '[role="dialog"], [aria-modal="true"], dialog[open], section, [id*="review" i], [class*="review" i], [data-testid*="review" i], [id*="bewertung" i], [class*="bewertung" i]'));
          var best = null, bestScore = 0, looked = 0;
          for (var r = 0; r < roots.length && looked < 6000; r++) {
            var root = roots[r];
            if (!/(bewertung|rezension|review)/i.test((root.innerText || '').slice(0, 6000))) { continue; }
            var inDialog = !!root.closest('[role="dialog"], [aria-modal="true"], dialog');
            var parents = [root].concat(Array.prototype.slice.call(root.querySelectorAll('*')));
            for (var p = 0; p < parents.length && looked < 6000; p++, looked++) {
              var parent = parents[p];
              if (parent.children.length < 3) { continue; }
              var texts = [], total = 0, tag = null, same = true;
              for (var c = 0; c < parent.children.length; c++) {
                var child = parent.children[c];
                var text = (child.innerText || '').trim();
                if (text.length < 60 || text.length > 6000) { continue; }
                var links = child.querySelectorAll('a[href]'), away = false;
                for (var l = 0; l < links.length; l++) { if (elsewhere(links[l])) { away = true; break; } }
                if (away) { continue; }
                if (tag && tag !== child.tagName) { same = false; }
                tag = child.tagName;
                texts.push(text.slice(0, 3000));
                total += text.length;
              }
              if (!same || texts.length < 3 || total / texts.length < 120) { continue; }
              var score = texts.length * (inDialog ? 2 : 1);
              if (score > bestScore) { bestScore = score; best = texts; }
            }
          }
          return (best || []).slice(0, 60);
        } catch (e) { return []; }
      };
      window.__tpCollect = function () {
        for (var i = 0; i < document.images.length; i++) { note(document.images[i]); }
        return Object.keys(seen).map(function (address) { return { url: address, gallery: seen[address] === true }; });
      };
    })();
    """

    /// Opens a collapsed list of reviews, so their text is part of the page that gets sent.
    /// Only buttons and links with a short, unmistakable label are pressed, and never links that lead away from the advert.
    private static let expandReviews = """
    var pressed = 0;
    var candidates = document.querySelectorAll('button, [role="button"], a[href]');
    for (var i = 0; i < candidates.length && pressed < 2; i++) {
      var element = candidates[i];
      var label = (element.innerText || element.getAttribute('aria-label') || '').trim();
      if (label.length === 0 || label.length > 60) { continue; }
      if (!/(bewertung|rezension|review)/i.test(label)) { continue; }
      if (!/(alle|mehr|weitere|anzeigen|ansehen|lesen|show|more|all)/i.test(label)) { continue; }
      if (/(schreiben|abgeben|verfassen|write|melden|report)/i.test(label)) { continue; }
      if (element.disabled || element.offsetParent === null) { continue; }
      var link = element.closest('a[href]');
      if (link) {
        // Some sites open the review list through a link that stays within the advert; anything else is left alone.
        var target = new URL(link.getAttribute('href'), location.href);
        if (target.origin !== location.origin || target.pathname.indexOf(location.pathname.replace(/\\/$/, '')) !== 0) { continue; }
      }
      element.click();
      pressed++;
      await new Promise(function (done) { setTimeout(done, 1500); });
    }
    // Review lists load more entries as one scrolls. Scroll the opened list to its end until nothing new arrives.
    var dialogs = document.querySelectorAll('[role="dialog"], [aria-modal="true"], dialog[open]');
    for (var d = 0; d < dialogs.length; d++) {
      if (!/(bewertung|rezension|review)/i.test(dialogs[d].innerText || '')) { continue; }
      var boxes = [dialogs[d]].concat(Array.prototype.slice.call(dialogs[d].querySelectorAll('*')));
      var list = null;
      for (var b = 0; b < boxes.length; b++) {
        var box = boxes[b];
        if (box.scrollHeight > box.clientHeight + 200 && (!list || box.scrollHeight > list.scrollHeight)) {
          var flow = getComputedStyle(box).overflowY;
          if (flow === 'auto' || flow === 'scroll') { list = box; }
        }
      }
      if (!list) { continue; }
      var still = 0;
      for (var round = 0; round < 30 && still < 3; round++) {
        var before = list.scrollHeight;
        list.scrollTop = list.scrollHeight;
        await new Promise(function (done) { setTimeout(done, 500); });
        still = list.scrollHeight === before ? still + 1 : 0;
      }
    }
    return pressed;
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

    struct Picture: Decodable, Equatable {
        var url: String
        var gallery: Bool
    }

    private func pictures() async -> [Picture] {
        let json = try? await webView.evaluateJavaScript("JSON.stringify(window.__tpCollect ? window.__tpCollect() : [])") as? String
        guard let data = json?.data(using: .utf8), let list = try? JSONDecoder().decode([Picture].self, from: data) else { return [] }
        return list
    }

    private func reviewTexts() async -> [String] {
        let json = try? await webView.evaluateJavaScript("JSON.stringify(window.__tpReviews ? window.__tpReviews() : [])") as? String
        guard let data = json?.data(using: .utf8), let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    func refreshPictureCount() async {
        // The count shown is the advert's own photos; pictures of other adverts on the page are not promised.
        pictureCount = await pictures().filter(\.gallery).count
    }

    /// The page as rendered, plus every large picture seen while it was open.
    /// Adverts fill in their content by script after loading, so this waits until the document has
    /// stopped growing; reading at once would return an empty shell.
    func html() async throws -> String {
        _ = try? await webView.callAsyncJavaScript(Self.scrollThrough, contentWorld: .page)
        _ = try? await webView.callAsyncJavaScript(Self.expandReviews, contentWorld: .page)
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
        return Self.append(reviews: await reviewTexts(), to: Self.append(pictures: await pictures(), to: page))
    }

    /// Adds the collected pictures as plain image tags, the form the server already reads pictures from.
    /// `data-gallery="1"` marks the advert's own photos, so the server can leave out those of similar adverts.
    static func append(pictures: [Picture], to page: String) -> String {
        guard !pictures.isEmpty else { return page }
        let tags = pictures.map { picture in
            let escaped = picture.url.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            return picture.gallery ? "<img src=\"\(escaped)\" data-gallery=\"1\">" : "<img src=\"\(escaped)\">"
        }.joined()
        let block = "<div id=\"tp-captured-images\" hidden>\(tags)</div>"
        if let end = page.range(of: "</body>", options: [.backwards, .caseInsensitive]) {
            return page.replacingCharacters(in: end, with: block + "</body>")
        }
        return page + block
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Adds the single reviews as shown on the page, one element each, in the wording of the page.
    /// Author, date and rating are part of that text; the server tells them apart.
    static func append(reviews: [String], to page: String) -> String {
        guard !reviews.isEmpty else { return page }
        let block = "<div id=\"tp-captured-reviews\" hidden>" + reviews.map { "<div data-review>\(escape($0))</div>" }.joined() + "</div>"
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
