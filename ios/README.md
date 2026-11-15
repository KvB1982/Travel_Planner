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

## Noch nicht enthalten

Vergleich, Karte, Schnellabstimmung per Wischen, Aktivitäten, Steckbrief von Hand korrigieren, Preis von Hand eintragen, lokaler Zwischenspeicher (SwiftData), Push, „Mit Apple anmelden“.
