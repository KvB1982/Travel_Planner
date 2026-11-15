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

Angebote lassen sich in der Liste per Wischen oder im Menü des Steckbriefs löschen, jeweils mit Rückfrage. Unter „Quellen“ ruft „Aktualisieren“ das Inserat über den Server neu ab, „Auf diesem Gerät aktualisieren“ liest es in der App neu aus. Dabei merkt sich die App alle Fotos, die die Seite lädt, und hängt sie als `tp-captured-images` an das gesendete HTML.

## Vergleich und Hinweise

„Vergleichen“ in der Angebotsliste stellt die Angebote einer Reise nebeneinander: Preis, Stimmen, Bewertungen, Größe, Lage, Ausstattung, Regeln. Der jeweils beste bekannte Wert ist markiert, „Nur Unterschiede zeigen“ blendet gleiche Zeilen aus, über „Auswahl“ lassen sich Angebote ab- und zuwählen. Preise für einen anderen Zeitraum stehen in Klammern und zählen nicht. Die Logik liegt in `TravelPlannerKit/Comparison.swift` und rechnet aus den Steckbriefen; der Server bietet mit `GET /trips/:id/compare` dasselbe an, die App nutzt es noch nicht.

Hinweise im Steckbrief sind eingeklappt. Einzelne lassen sich per Wischen ausblenden (`PATCH /candidates/:id` mit `hiddenWarnings`), das gilt für die ganze Reise und lässt sich zurücknehmen.

## Dasselbe Haus auf anderen Plattformen

Im Steckbrief startet „Auf anderen Plattformen suchen“ die Suche des Servers (`POST /candidates/:id/sources/search`, kostenpflichtig, daher nur auf Knopfdruck). Treffer erscheinen als Vorschläge mit Begründung und werden einzeln bestätigt oder abgelehnt; Links lassen sich auch von Hand hinzufügen. Jede Quelle zeigt Plattform, Note und Lesestand und lässt sich einzeln auf dem Gerät auslesen (`sourceId` beim Capture). Beim Auslesen schickt die App die aufgeklappten Einzelbewertungen im Wortlaut als `tp-captured-reviews` mit.

## Noch nicht enthalten

Karte, Schnellabstimmung per Wischen, Aktivitäten, Steckbrief von Hand korrigieren, Preis von Hand eintragen, lokaler Zwischenspeicher (SwiftData), Push, „Mit Apple anmelden“.
