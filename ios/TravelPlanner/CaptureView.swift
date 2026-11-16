import OSLog
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
    /// The page is opened for the dates and party of the trip: its price and availability count for the trip.
    var forTrip = false
    /// Reads and sends on its own once the page has loaded, without browsing photos and reviews.
    /// Used when all offers of a trip are checked one after the other.
    var automatic = false
    /// "2 von 3" during such a run.
    var progressLabel: String?
    /// How many photos the advert is known to have, to warn before a reading that would bring far fewer.
    /// Nil where the server gets the photos from the page itself and the count seen here does not matter.
    var expectedPictures: Int?
    /// Reports how many photos and single reviews went to the server, so the result can be checked against it.
    var onSent: (_ pictures: Int, _ reviews: Int) -> Void = { _, _ in }

    @State private var page = WebPage()
    @State private var sending = false
    @State private var confirmFewPictures = false
    /// The site showed a "bot or human?" question; the automatic run has stopped and waits for the person.
    @State private var gate = false
    /// A reading that is waiting for the answer to "send it although photos are missing?".
    @State private var held: WebPage.Captured?
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
                        Text(automatic && !gate
                             ? "Prüfe Preis und Verfügbarkeit für euren Zeitraum\(progressLabel.map { " (\($0))" } ?? "") … Die Seite wird gleich von selbst gelesen."
                             : sending
                             ? (page.progress ?? "Lese die Seite …") + " Das dauert bis zu einer Minute, bitte nichts antippen."
                             : "Stelle Zeitraum und Personen ein und tippe auf „Übernehmen“. Die App blättert dann selbst durch die Bildergalerie und klappt die Bewertungen auf.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Label("\(page.pictureCount == 1 ? "1 Bild" : "\(page.pictureCount) Bilder") · \(page.reviewCount == 1 ? "1 Bewertung" : "\(page.reviewCount) Bewertungen") bisher geladen",
                              systemImage: "checklist")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(page.pictureCount + page.reviewCount > 0 ? Color.accentColor : Color.secondary)
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
        // The automatic browsing found far fewer photos than the advert has: ask before a poorer set is sent.
        .confirmationDialog("Nur \(held?.pictures ?? 0) von etwa \(expectedPictures ?? 0) Bildern gefunden", isPresented: $confirmFewPictures, titleVisibility: .visible) {
            // No cancel role: the system would hide that button here, and it is the recommended choice.
            Button("Selbst durchblättern, dann erneut") { held = nil }
            Button("Trotzdem übernehmen") {
                if let held { send(held) }
            }
        } message: {
            Text("Die App konnte die Bildergalerie dieser Seite nicht vollständig durchblättern. Öffne die Galerie des Inserats selbst, blättere bis zum Ende und tippe noch einmal auf „Übernehmen“. Der Zähler unten zählt mit.")
        }
        .task {
            guard automatic else { return }
            // Give the page time to load and to fill in its price, then read it without waiting for a tap.
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                if !page.isLoading { break }
            }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled && !sending { capture() }
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
        sending = true
        error = nil
        Task {
            do {
                if await page.isChallenge() {
                    // The person can answer the site's question here; the app does not, and does not send this page.
                    gate = true
                    throw APIError(status: 0, code: "challenge", message: "Die Seite zeigt eine Sicherheitsabfrage statt des Inserats. Bitte beantworte sie hier und tippe danach auf „Übernehmen“. Oder brich ab, dann wird dieses Angebot nicht geprüft.")
                }
                if automatic { await page.waitForPrice() }
                let captured = try await page.capture(quick: automatic)
                if await page.isChallenge() {
                    gate = true
                    throw APIError(status: 0, code: "challenge", message: "Die Seite zeigt eine Sicherheitsabfrage statt des Inserats. Bitte beantworte sie hier und tippe danach auf „Übernehmen“.")
                }
                guard captured.html.count >= 500 else {
                    throw APIError(status: 0, code: "empty_page", message: "Die Seite ist noch leer. Warte kurz und versuche es erneut.")
                }
                if let expectedPictures, expectedPictures >= 8, captured.pictures * 2 < expectedPictures {
                    held = captured
                    sending = false
                    confirmFewPictures = true
                    return
                }
                send(captured)
            } catch {
                self.error = model.message(for: error)
                sending = false
            }
        }
    }

    private func send(_ captured: WebPage.Captured) {
        guard let backend = model.backend else { return }
        sending = true
        held = nil
        Task {
            do {
                try await backend.capture(candidateId: candidateID, html: captured.html, sourceId: sourceID, forTrip: forTrip,
                                          url: page.advertURL ?? source.url)
                model.dataChanged()
                onSent(captured.pictures, captured.reviews)
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
    private static let log = Logger(subsystem: "com.von-bleichert.travelplanner", category: "Auslesen")
    let webView: WKWebView
    var isLoading = false
    /// Large pictures the page has shown so far, including ones a gallery has since swapped out.
    var pictureCount = 0
    /// Single reviews that can be read off the page as it is right now.
    var reviewCount = 0
    /// What the automatic reading is doing at the moment, shown while it runs.
    var progress: String?

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
      // inside something that talks about reviews.
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
                // Reviews link to the guest's profile, so links say nothing here. What gives away a card of
                // another advert is a price per night.
                if (/(€|eur|chf|\\$)\\s?\\d|\\d\\s?(€|eur|chf)/i.test(text) && /(nacht|nächte|night)/i.test(text)) { continue; }
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
          return (best || []).slice(0, 150);
        } catch (e) { return []; }
      };
      window.__tpCollect = function () {
        for (var i = 0; i < document.images.length; i++) { note(document.images[i]); }
        return Object.keys(seen).map(function (address) { return { url: address, gallery: seen[address] === true }; });
      };
    })();
    """

    /// Opens the advert's photo gallery and flips or scrolls through it, so every photo gets loaded once
    /// and the collector sees it. Stops when no new photo has appeared for a while.
    private static let browseGallery = """
    function count() { try { return window.__tpCollect().filter(function (p) { return p.gallery; }).length; } catch (e) { return 0; } }
    function wait(ms) { return new Promise(function (done) { setTimeout(done, ms); }); }
    function visible(el) { var r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 && !el.disabled; }
    function staysHere(el) {
      var link = el.closest('a[href]');
      if (!link) { return true; }
      try {
        var target = new URL(link.getAttribute('href'), location.href);
        return target.origin === location.origin && target.pathname.indexOf(location.pathname.replace(/\\/$/, '')) === 0;
      } catch (e) { return false; }
    }
    function label(el) { return ((el.innerText || '') + ' ' + (el.getAttribute('aria-label') || '') + ' ' + (el.getAttribute('title') || '')).trim(); }

    // Sliders listen to fingers, not to click(): send what a finger would send, in every dialect.
    function fire(el, type, x, y) {
      try {
        if (type.indexOf('touch') === 0) {
          if (typeof Touch === 'undefined' || typeof TouchEvent === 'undefined') { return; }
          var touch = new Touch({ identifier: 1, target: el, clientX: x, clientY: y, pageX: x + window.scrollX, pageY: y + window.scrollY, screenX: x, screenY: y });
          var list = type === 'touchend' ? [] : [touch];
          el.dispatchEvent(new TouchEvent(type, { bubbles: true, cancelable: true, touches: list, targetTouches: list, changedTouches: [touch] }));
        } else if (type.indexOf('pointer') === 0) {
          el.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, pointerId: 1, pointerType: 'touch', isPrimary: true, buttons: type === 'pointerup' ? 0 : 1 }));
        } else {
          el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, buttons: type === 'mouseup' || type === 'click' ? 0 : 1 }));
        }
      } catch (e) {}
    }
    function tap(el) {
      var r = el.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
      ['pointerdown', 'touchstart', 'mousedown', 'pointerup', 'touchend', 'mouseup', 'click'].forEach(function (type) { fire(el, type, x, y); });
    }
    async function swipeLeft(el) {
      var r = el.getBoundingClientRect(), y = r.top + r.height / 2, from = r.left + r.width * 0.85, to = r.left + r.width * 0.1;
      ['pointerdown', 'touchstart', 'mousedown'].forEach(function (type) { fire(el, type, from, y); });
      for (var step = 1; step <= 6; step++) {
        var x = from + (to - from) * step / 6;
        ['pointermove', 'touchmove', 'mousemove'].forEach(function (type) { fire(el, type, x, y); });
        await wait(16);
      }
      ['pointerup', 'touchend', 'mouseup'].forEach(function (type) { fire(el, type, to, y); });
    }

    var before = count();
    // 1. Open the gallery: a control that names the photos, otherwise the first large photo of the advert.
    var opener = null;
    var controls = document.querySelectorAll('button, [role="button"], a[href]');
    for (var i = 0; i < controls.length && !opener; i++) {
      var text = label(controls[i]);
      if (text.length === 0 || text.length > 60 || !visible(controls[i]) || !staysHere(controls[i])) { continue; }
      if (/(fotos|bilder|photos|images|galerie|gallery)/i.test(text) && /(alle|all|anzeigen|ansehen|show|view|mehr|more|\\+\\s?\\d|\\d)/i.test(text)) { opener = controls[i]; }
    }
    // Some sites only say "Alle anzeigen" on the button that sits on the first photo. The same words open
    // other lists further down (amenities), so only a button on or right under that photo counts.
    var hero = null;
    for (var h = 0; h < document.images.length && !hero; h++) {
      var hb = document.images[h].getBoundingClientRect();
      if (hb.width >= 240 && hb.height >= 160 && !document.images[h].closest('nav, header, footer')) { hero = document.images[h]; }
    }
    if (!opener && hero) {
      var heroBox = hero.getBoundingClientRect();
      for (var a = 0; a < controls.length && !opener; a++) {
        var words = label(controls[a]);
        if (!/^(alle|all|show all|view all)(\\s+(anzeigen|ansehen|zeigen))?$/i.test(words) || !visible(controls[a]) || !staysHere(controls[a])) { continue; }
        var cb = controls[a].getBoundingClientRect();
        if (cb.top >= heroBox.top - 20 && cb.top <= heroBox.bottom + 60) { opener = controls[a]; }
      }
    }
    if (!opener) {
      for (var j = 0; j < document.images.length && !opener; j++) {
        var img = document.images[j];
        var box = img.getBoundingClientRect();
        if (box.width >= 240 && box.height >= 160 && box.top + window.scrollY < 1200 && staysHere(img) && !img.closest('nav, header, footer')) { opener = img; }
      }
    }
    // What the page offers, for the log: this is how a site the search does not fit gets understood.
    var seen = [];
    for (var k = 0; k < controls.length && seen.length < 25; k++) {
      var t = label(controls[k]);
      if (t.length > 0 && t.length <= 80 && /(foto|bild|galer|photo|image|pictur)/i.test(t)) { seen.push(controls[k].tagName + ':' + t.replace(/\\s+/g, ' ')); }
    }
    var how = opener ? (opener.tagName + ':' + label(opener).slice(0, 60)) : 'none';
    if (!opener) { return JSON.stringify({ opened: false, how: how, seen: seen, before: before, after: before }); }
    opener.scrollIntoView({ block: 'center' });
    if (opener.tagName === 'IMG') { tap(opener); } else { opener.click(); }
    await wait(1800);

    // 2. Flip and scroll until nothing new arrives.
    var still = 0, last = count();
    for (var round = 0; round < 200 && still < 8; round++) {
      // The gallery is the layer over the page with the most pictures: a dialog, or on sites that do not
      // mark it as one, a box that covers the screen. A cookie banner is such a layer too, but has no pictures.
      var scope = document, most = 0;
      var layers = Array.prototype.slice.call(document.querySelectorAll('[role="dialog"], [aria-modal="true"], dialog[open]'));
      if (round % 5 === 0 || !window.__tpLayers) {
        window.__tpLayers = [];
        var all = document.querySelectorAll('body *');
        for (var f = 0; f < all.length; f++) {
          var position = getComputedStyle(all[f]).position;
          if (position !== 'fixed' && position !== 'absolute') { continue; }
          var area = all[f].getBoundingClientRect();
          if (area.width >= window.innerWidth * 0.9 && area.height >= window.innerHeight * 0.8) { window.__tpLayers.push(all[f]); }
        }
      }
      layers = layers.concat(window.__tpLayers);
      for (var d = 0; d < layers.length; d++) {
        var pictures = layers[d].querySelectorAll('img, picture').length;
        if (pictures > most) { most = pictures; scope = layers[d]; }
      }
      var next = null;
      var buttons = scope.querySelectorAll('button, [role="button"]');
      for (var b = 0; b < buttons.length && !next; b++) {
        var name = label(buttons[b]);
        if (name.length > 30 || !visible(buttons[b]) || /(monat|month|seite|page|woche|week)/i.test(name)) { continue; }
        // A whole word only: "Weitere Ausstattung anzeigen" is not a next button.
        var forward = /(^|\\s)(nächste[sr]?|naechste[sr]?|weiter|next|vorwärts|forward)(\\s|$)/i.test(name);
        var aboutPhotos = /(bild|foto|photo|image|slide)/i.test(name);
        // Outside a gallery dialog only controls that name the photos are pressed.
        if (forward && (scope !== document || aboutPhotos)) { next = buttons[b]; }
      }
      if (next) { next.click(); }
      // Galleries that are one long list: move every scrollable box inside on by a screen.
      var boxes = scope === document ? [document.scrollingElement] : [scope].concat(Array.prototype.slice.call(scope.querySelectorAll('*')));
      for (var s = 0; s < boxes.length; s++) {
        var el = boxes[s];
        if (!el) { continue; }
        if (el.scrollHeight > el.clientHeight + 100) { el.scrollTop += Math.max(300, el.clientHeight * 0.9); }
        if (el.scrollWidth > el.clientWidth + 100 && scope !== document) { el.scrollLeft += Math.max(200, el.clientWidth * 0.9); }
      }
      await wait(next ? 350 : 500);
      var now = count();
      still = now === last ? still + 1 : 0;
      last = now;
    }

    // No gallery layer came up and nothing new loaded: the photos sit in a slider on the page itself.
    // Swipe it along until it stops bringing new photos.
    var swiped = 0;
    if (hero && count() === before) {
      hero.scrollIntoView({ block: 'center' });
      await wait(300);
      // Sliders built on plain sideways scrolling: move every such box that holds the first photo, or photos at all.
      var rows = [];
      for (var anc = hero.parentElement, depth = 0; anc && depth < 10; anc = anc.parentElement, depth++) {
        if (anc.scrollWidth > anc.clientWidth + 50) { rows.push(anc); }
      }
      var boxesWide = document.querySelectorAll('body *');
      for (var w = 0; w < boxesWide.length && rows.length < 8; w++) {
        if (boxesWide[w].scrollWidth > boxesWide[w].clientWidth + 100 && boxesWide[w].querySelectorAll('img').length >= 3 && rows.indexOf(boxesWide[w]) < 0) { rows.push(boxesWide[w]); }
      }
      var idle = 0, known = count();
      for (var pass = 0; rows.length > 0 && pass < 150 && idle < 6; pass++, swiped++) {
        for (var q = 0; q < rows.length; q++) { rows[q].scrollLeft += Math.max(200, rows[q].clientWidth * 0.9); }
        await wait(400);
        var total = count();
        idle = total === known ? idle + 1 : 0;
        known = total;
      }
      seen.push('ROWS ' + rows.length + ' after ' + count());
      var quiet = 0, had = count();
      for (; swiped < 150 && quiet < 6; swiped++) {
        var top = document.elementFromPoint(window.innerWidth / 2, hero.getBoundingClientRect().top + hero.getBoundingClientRect().height / 2) || hero;
        await swipeLeft(top);
        await wait(450);
        var got = count();
        quiet = got === had ? quiet + 1 : 0;
        had = got;
      }
    }

    // 3. Close it again where that is a plain button; a gallery on a page of its own is left by going back.
    var closers = document.querySelectorAll('[role="dialog"] button, [aria-modal="true"] button, dialog[open] button');
    for (var c = 0; c < closers.length; c++) {
      if (/(schließen|schliessen|close|zurück|back)/i.test(label(closers[c])) && visible(closers[c])) { closers[c].click(); break; }
    }
    await wait(400);
    return JSON.stringify({ opened: true, how: how, seen: seen, rounds: round, swiped: swiped, before: before, after: count(),
      dialogs: document.querySelectorAll('[role="dialog"], [aria-modal="true"], dialog[open]').length, url: location.href });
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
      for (var round = 0; round < 80 && still < 3; round++) {
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

    /// The address of the advert as first reached, after the site's own redirects.
    private(set) var advertURL: String?

    func load(_ url: URL) {
        advertURL = nil
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
        reviewCount = await reviewTexts().count
    }

    /// Waits until the document has stopped growing. Adverts fill in their content by script after loading;
    /// reading at once would return an empty shell.
    private func settle() async {
        var last = -1
        var stable = 0
        for _ in 0..<16 {
            let state = (try? await webView.evaluateJavaScript("document.readyState + '|' + document.documentElement.outerHTML.length") as? String) ?? ""
            let parts = state.split(separator: "|")
            let length = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
            // Small changes (timers, counters) are ignored; a still-rendering page grows by far more.
            stable = parts.first == "complete" && last >= 0 && abs(length - last) < 2_000 ? stable + 1 : 0
            last = length
            if stable >= 2 { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// A page that asks "bot or human?" or refuses access instead of showing the advert.
    /// Such a page must never be sent as if it were the advert.
    func isChallenge() async -> Bool {
        let script = """
        (function () {
          var title = (document.title || '').toLowerCase();
          var text = (document.body ? document.body.innerText : '').trim();
          var words = /(bot oder mensch|bot or (not|human)|mensch oder bot|bist du ein (mensch|roboter)|are you (a )?(human|robot)|kein roboter|not a robot|captcha|just a moment|einen moment|access (to this page has been )?denied|zugriff verweigert|ungewöhnliche(n)? (aktivität|zugriff)|unusual (traffic|activity)|sicherheitsüberprüfung|security check|verify (you are|that you)|press (and|&) hold|gedrückt halten)/i;
          if (words.test(title)) { return true; }
          // A real advert has plenty of text; a gate has a few lines.
          return text.length < 1500 && words.test(text);
        })()
        """
        return ((try? await webView.evaluateJavaScript(script) as? Bool) ?? false) == true
    }

    /// For a price check: waits until the page shows a price for the stay or says the dates are taken.
    /// Adverts fill that in a few seconds after loading; gives up after a quarter of a minute.
    func waitForPrice() async {
        let script = """
        (function () {
          var text = document.body ? document.body.innerText : '';
          var price = /\\d[\\d.,]*\\s?(€|eur)[^\\n]{0,40}(nächte|nacht|nights?|gesamt|insgesamt|total)|(nächte|nacht|nights?|gesamt|insgesamt|total)[^\\n]{0,40}\\d[\\d.,]*\\s?(€|eur)|(€|eur)\\s?\\d[\\d.,]*[^\\n]{0,40}(nächte|nacht|nights?|gesamt|insgesamt|total)/i;
          var taken = /(nicht verfügbar|nicht mehr verfügbar|ausgebucht|belegt|not available|unavailable|sold out|keine verfügbarkeit|leider vergeben)/i;
          return price.test(text) || taken.test(text);
        })()
        """
        for _ in 0..<30 {
            if ((try? await webView.evaluateJavaScript(script) as? Bool) ?? false) == true { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func outerHTML() async throws -> String {
        try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""
    }

    struct Captured {
        var html: String
        var pictures: Int
        var reviews: Int
    }

    private func merge(_ more: [Picture], into all: inout [Picture]) {
        for photo in more {
            if let index = all.firstIndex(where: { $0.url == photo.url }) {
                all[index].gallery = all[index].gallery || photo.gallery
            } else {
                all.append(photo)
            }
        }
    }

    /// Runs one of the page scripts. If it led to a page of its own (a gallery or a review list with its
    /// own address), returns to the advert afterwards and reports false.
    private func run(_ script: String) async -> (stayed: Bool, pictures: [Picture], reviews: [String]) {
        let mark = UUID().uuidString
        _ = try? await webView.evaluateJavaScript("window.__tpDocument = '\(mark)'; true")
        let outcome = try? await webView.callAsyncJavaScript(script, contentWorld: .page)
        Self.log.info("Auslesen: \(String(describing: outcome ?? "–"), privacy: .public)")
        await settle()
        let found = (pictures: await pictures(), reviews: await reviewTexts())
        let same = ((try? await webView.evaluateJavaScript("window.__tpDocument || ''") as? String) ?? "") == mark
        if !same, webView.canGoBack {
            webView.goBack()
            try? await Task.sleep(for: .milliseconds(800))
            await settle()
        }
        return (same, found.pictures, found.reviews)
    }

    /// The page as rendered, plus every photo of the gallery and the single reviews.
    ///
    /// The advert itself is read first. Gallery and reviews are opened afterwards, because on some sites
    /// either leads to a page of its own: the advert must not be lost to it.
    /// `quick` reads only the page itself, for a price and availability check: no gallery, no reviews.
    func capture(quick: Bool = false) async throws -> Captured {
        _ = try? await webView.callAsyncJavaScript(Self.scrollThrough, contentWorld: .page)
        await settle()
        let advert = try await outerHTML()
        var photos = await pictures()
        if quick {
            return Captured(html: Self.append(pictures: photos, to: advert), pictures: photos.filter(\.gallery).count, reviews: 0)
        }

        progress = "Blättere die Bildergalerie durch …"
        let gallery = await run(Self.browseGallery)
        merge(gallery.pictures, into: &photos)

        progress = "Klappe die Bewertungen auf …"
        let reviews = await run(Self.expandReviews)
        merge(reviews.pictures, into: &photos)
        progress = nil

        // Never left the advert: the page as it is now holds everything, including the opened reviews.
        let page = gallery.stayed && reviews.stayed ? ((try? await outerHTML()) ?? advert) : advert
        return Captured(html: Self.append(reviews: reviews.reviews, to: Self.append(pictures: photos, to: page)),
                        pictures: photos.filter(\.gallery).count, reviews: reviews.reviews.count)
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
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        if advertURL == nil { advertURL = webView.url?.absoluteString }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { isLoading = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { isLoading = false }
}

private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
