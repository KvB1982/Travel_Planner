# iOS- und iPadOS-App

Native App in Swift und SwiftUI für iPhone und iPad. Sie spricht ausschließlich mit der API aus `../backend`, beschrieben in [docs/API.md](../docs/API.md).

## Aufbau

| Ordner | Inhalt |
|---|---|
| `TravelPlanner.xcodeproj` | Xcode-Projekt mit zwei Targets: App und Share Extension |
| `TravelPlanner/` | Die App: Anmeldung, Reisen, Angebote, Steckbrief, Auslesen auf dem Gerät |
| `ShareExtension/` | Teilen-Menü: Link (aus Safari samt Seiteninhalt) in eine Reise legen |
| `TravelPlannerKit/` | Swift-Paket für beide Targets: Datenmodell, API-Client, Sitzung, Beispieldaten, Tests |
| `Config/` | Entitlements und die Info.plist der Extension |

Neue Dateien in `TravelPlanner/` und `ShareExtension/` gehören automatisch zum jeweiligen Target, die Projektdatei muss dafür nicht angefasst werden.

## Einmalig auf einem neuen Mac

```bash
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
xcodebuild -downloadPlatform iOS
```

## Bauen und testen

Die Logik lässt sich ohne Simulator prüfen:

```bash
cd ios/TravelPlannerKit && swift test
```

Die App: `TravelPlanner.xcodeproj` in Xcode öffnen, Schema „TravelPlanner“ und einen Simulator wählen, starten. Über „Erst einmal mit Beispieldaten ansehen“ läuft sie ohne Server.

Für ein echtes Gerät und TestFlight muss in Xcode bei beiden Targets unter „Signing & Capabilities“ das Team gewählt werden. Die App Group `group.com.von-bleichert.travelplanner` verbindet App und Extension: Darüber liest die Extension Serveradresse und Anmeldung.

## Anmeldung

- **Mit Einladung:** Link der Form `https://server/einladung/<token>` einfügen. Die Serveradresse wird aus dem Link gelesen.
- **Erstes Konto:** Serveradresse und `BOOTSTRAP_SECRET` des Servers eingeben. Geht nur einmal.

## Auslesen auf dem Gerät

FeWo-direkt und Casamundo sperren den Abruf vom Server. Solche Angebote kommen mit `importStatus: "partial"` an. Im Steckbrief öffnet „Auf diesem Gerät auslesen“ das Inserat in einer Web-Ansicht, „Übernehmen“ schickt den geladenen Seiteninhalt an `POST /candidates/:id/capture`. Beim Teilen aus Safari liefert `GetPage.js` den Seiteninhalt gleich mit, dann entfällt dieser Schritt.

## Bilder

Der Steckbrief zeigt alle Bilder eines Angebots als Leiste zum Durchwischen, ein Tipp öffnet das Vollbild in voller Qualität mit Zoom. Erwartet wird in `GET /candidates/:id` ein Feld `photos` mit `id`, `url` (Original), `thumbUrl`, `width`, `height`, `caption`. Fehlt es, erscheint nur das Titelbild. Adressen dürfen absolut sein oder mit `/` beginnen. Den Anmelde-Token schickt die App nur an Bildadressen auf dem eigenen Server mit, nie an fremde Hosts. Geladene Bilder bleiben auf dem Gerät zwischengespeichert.

## Bewertungen

Liefert `GET /candidates/:id` die Felder `reviewSummary` (`summary`, `positives`, `negatives`, `basedOn`) und `reviews` (Liste der Einzelbewertungen), zeigt der Steckbrief die Zusammenfassung mit Gelobtem und Kritisiertem und öffnet auf Wunsch die Einzelbewertungen, bei fremdsprachigen mit Übersetzung und Original. Die Zusammenfassung ist als automatisch erstellt gekennzeichnet.

## Löschen und Aktualisieren

Angebote lassen sich in der Liste per Wischen oder im Menü des Steckbriefs löschen, jeweils mit Rückfrage. Unter „Quellen“ ruft „Aktualisieren“ das Inserat über den Server neu ab, „Auf diesem Gerät aktualisieren“ liest es in der App neu aus. Beim Übernehmen blättert die App die Bildergalerie des Inserats selbst durch (Galerie-Dialog, Wisch-Karussell oder seitlich scrollende Bildreihe), klappt die Bewertungen auf und hängt alle geladenen Fotos als `tp-captured-images` und die Einzelbewertungen als `tp-captured-reviews` an das gesendete HTML. Findet sie deutlich weniger Fotos, als das Inserat hat, fragt sie vor dem Senden nach. Zum Testen an einem echten Inserat: Debug-Build mit Beispieldaten und `-demoLink <Adresse>` starten.

## Vergleich und Hinweise

„Vergleichen“ in der Angebotsliste stellt die Angebote einer Reise nebeneinander: Preis, Stimmen, Bewertungen, Größe, Lage, Ausstattung, Regeln. Der jeweils beste bekannte Wert ist markiert, „Nur Unterschiede zeigen“ blendet gleiche Zeilen aus, über „Auswahl“ lassen sich Angebote ab- und zuwählen. Preise für einen anderen Zeitraum stehen in Klammern und zählen nicht. Die Logik liegt in `TravelPlannerKit/Comparison.swift` und rechnet aus den Steckbriefen; der Server bietet mit `GET /trips/:id/compare` dasselbe an, die App nutzt es noch nicht.

Hinweise im Steckbrief sind eingeklappt. Einzelne lassen sich per Wischen ausblenden (`PATCH /candidates/:id` mit `hiddenWarnings`), das gilt für die ganze Reise und lässt sich zurücknehmen.

## Dasselbe Haus auf anderen Plattformen

Im Steckbrief startet „Auf anderen Plattformen suchen“ die Suche des Servers (`POST /candidates/:id/sources/search`, kostenpflichtig, daher nur auf Knopfdruck). Treffer erscheinen als Vorschläge mit Begründung und werden einzeln bestätigt oder abgelehnt; Links lassen sich auch von Hand hinzufügen. Jede Quelle zeigt Plattform, Note und Lesestand und lässt sich einzeln auf dem Gerät auslesen (`sourceId` beim Capture). Beim Auslesen schickt die App die aufgeklappten Einzelbewertungen im Wortlaut als `tp-captured-reviews` mit.

## Karten

Mit Apple Karten (MapKit, ohne Schlüssel und ohne Kosten). Der Steckbrief zeigt die Lage mit einem Ausschnitt von rund 30 km; ein Tipp öffnet die große Karte mit Satellitenansicht, festen Ausschnitten (Haus, Umgebung, Region) und dem Absprung zu Apple Karten oder Google Maps. Fehlen Koordinaten, sucht die App den Ortsnamen und zeigt einen Kreis als ungefähre Lage. „Karte“ in der Angebotsliste zeigt alle Angebote der Reise mit Preis; ein Tipp wählt aus, „Öffnen“ springt zum Steckbrief.

## Kriterien, Zeiträume, Sortieren

Über „…“ und „Kriterien“ legt die Reise Muss- und Wunsch-Kriterien fest (`GET`/`PUT /trips/:id/criteria`). Jedes Angebot zeigt dazu eine Ampel in der Liste und im Steckbrief die Ergebnisse je Kriterium, die sich von Hand überstimmen lassen (`criteriaChecks`). Hat eine Reise mehrere Zeiträume, schaltet ein Umschalter in der Angebotsliste um, worauf sich Preise, Verfügbarkeit und Prüflauf beziehen (`dateOptionId`). Das Menü mit den zwei Pfeilen sortiert nach Preis, Bewertung, Kriterien oder Stimmen und blendet nicht verfügbare Angebote aus. Außerdem gibt es einen Präsentationsmodus (Abspielsymbol): Angebote im Vollbild durchblättern, Wischen stimmt ab.

## Noch nicht enthalten

Schnellabstimmung per Wischen, Aktivitäten, Steckbrief von Hand korrigieren, Preis von Hand eintragen, lokaler Zwischenspeicher (SwiftData), Push, „Mit Apple anmelden“.
