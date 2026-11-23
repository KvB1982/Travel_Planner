# Schnittstelle des Backends

Stand: Version 0.1. Alle Anfragen und Antworten sind JSON. Bis auf die Anmeldung braucht jede Anfrage den Kopf `Authorization: Bearer <token>`.

Fehler haben immer die Form `{"error": {"code": "...", "message": "..."}}`. Die Meldung ist auf Deutsch und kann in der App angezeigt werden.

| Status | Bedeutung |
|---|---|
| 400 | Eingabe ungültig |
| 401 | Nicht angemeldet |
| 403 | Angemeldet, aber ohne Berechtigung |
| 404 | Nicht vorhanden oder nicht Mitglied der Reise |
| 410 | Einladung abgelaufen oder verbraucht |
| 422 | Link nicht lesbar |
| 429 | Zu viele Anfragen |

## Rollen

| Rolle | Darf |
|---|---|
| `organizer` | alles, zusätzlich Einladungen erstellen und die Reise ändern |
| `member` | Angebote importieren und bearbeiten, abstimmen, kommentieren |
| `guest` | ansehen, abstimmen, kommentieren |

## Anmeldung

| Methode | Pfad | Zweck |
|---|---|---|
| POST | `/auth/bootstrap` | Erstes Konto anlegen. Körper: `secret`, `name`. Funktioniert nur einmal. |
| GET | `/auth/invites/:token` | Zeigt, zu welcher Reise eine Einladung führt. |
| POST | `/auth/invites/:token/accept` | Einladung annehmen. Körper: `name` (nur ohne Anmeldung nötig). Antwort enthält `token` für neue Konten. |
| GET | `/me` | Eigenes Konto. |
| POST | `/auth/logout` | Aktuelle Sitzung beenden. |

### Mit Apple anmelden

Die Apple-ID öffnet ein bestehendes Konto auf jedem Gerät, sie legt keines an. Neue Personen kommen weiter nur per Einladung dazu und verknüpfen danach ihre Apple-ID.

| Methode | Pfad | Zweck |
|---|---|---|
| PUT | `/me/apple` | Angemeldet: Apple-ID mit dem eigenen Konto verknüpfen. Körper: `identityToken`, optional `nonce`. Antwort `{ user }` mit `apple: true`. 409 `apple_in_use`, wenn sie schon zu einem anderen Konto gehört. |
| POST | `/auth/apple` | Ohne Anmeldung: Sitzung für das verknüpfte Konto. Körper: `identityToken`, optional `nonce`, `deviceName`. Antwort 201 `{ token, user }`. 404 `apple_not_linked`, wenn die Apple-ID zu keinem Konto gehört. |
| DELETE | `/me/apple` | Verknüpfung lösen. |

- `identityToken` ist das Token aus `ASAuthorizationAppleIDCredential.identityToken` als Text. Der Server prüft Signatur, Aussteller, Ablauf und dass es für die Bundle-ID der App ausgestellt ist (`APPLE_CLIENT_IDS`, Vorgabe `com.von-bleichert.travelplanner`).
- `nonce`: Wer beim Anfordern eine Nonce setzt, schickt hier den ungehashten Wert mit; im Token steht dann dessen SHA-256 als Hex.
- Fehler: 401 `apple_token_invalid`, 503 `apple_unavailable` (Apples Schlüssel nicht abrufbar).
- `GET /me` nennt unter `user.apple`, ob eine Apple-ID verknüpft ist.

Geplant, aber noch nicht umgesetzt: die Anmeldung per E-Mail-Link für das Web.

## Reisen

| Methode | Pfad | Zweck |
|---|---|---|
| POST | `/trips` | Reise anlegen. Körper: `title`, `region`, `adults`, `children`, `pets`, `budgetTotalCents`, `voteDeadline`, `dateOptions[]`. |
| GET | `/trips` | Eigene Reisen mit Anzahl der Angebote und Favoriten. |
| GET | `/trips/:id` | Reise mit Mitgliedern und Zeiträumen. |
| PATCH | `/trips/:id` | Reise ändern, auch `status` (`planning`, `decided`, `booked`, `archived`). |
| POST | `/trips/:id/date-options` | Zeitraum hinzufügen: `label`, `startDate`, `endDate`. |
| DELETE | `/trips/:id/date-options/:optionId` | Zeitraum entfernen. |
| POST | `/trips/:id/invites` | Einladungslink erstellen: `role`, `maxUses`, `expiresInDays`. Der Link wird nur einmal angezeigt. |
| GET | `/trips/:id/activity` | Chronik der letzten 100 Ereignisse. |

## Angebote

Ein Angebot innerhalb einer Reise heißt in der Schnittstelle `candidate`.

| Methode | Pfad | Zweck |
|---|---|---|
| POST | `/trips/:id/imports` | Link teilen. Körper: `url`, optional `html`. |
| GET | `/trips/:id/candidates` | Liste mit Kerndaten, aktuellem Preis, Stimmen und eigener Stimme. |
| GET | `/candidates/:id` | Vollständiger Steckbrief, Quellen, Preisverlauf, Stimmen, Kommentare, dazu `photos`. |
| PATCH | `/candidates/:id` | `status` (`new`, `shortlist`, `favorite`, `rejected`, `booked`), `rejectionReason`, `notes`, `tags`. |
| DELETE | `/candidates/:id` | Angebot aus der Reise entfernen, samt Stimmen, Kommentaren und den für diese Reise erfassten Preisen. Antwort 204. Mitglieder und Organisatoren, keine Gäste. Derselbe Link kann danach neu geteilt werden. |
| PATCH | `/candidates/:id/profile` | Steckbrief von Hand korrigieren. Nur die geänderten Felder senden. |
| POST | `/candidates/:id/capture` | Auf dem Gerät ausgelesenen Seiteninhalt nachreichen: `html`. |
| POST | `/candidates/:id/refresh` | Angebot erneut vom Server abrufen und auswerten (ohne Inhalt). Antwort 202, danach wie beim Import auf `importStatus` warten. 429, wenn der letzte Abruf weniger als eine Minute her ist. |
| PUT | `/candidates/:id/vote` | Abstimmen: `verdict` (`yes`, `maybe`, `no`), `veto`. |
| DELETE | `/candidates/:id/vote` | Eigene Stimme samt Veto zurücknehmen. 204, auch wenn es keine gab. Erlaubt ist es jedem, der abstimmen darf. |
| POST | `/candidates/:id/comments` | Kommentar: `body`. |
| POST | `/candidates/:id/prices` | Preis von Hand festhalten: `totalCents`, `startDate`, `endDate`, `persons`, `breakdown[]`. |

### Ablauf eines Imports

1. Die App sendet den Link an `/trips/:id/imports`. Die Antwort kommt sofort, das Angebot ist für alle sichtbar und hat `importStatus: "pending"`.
2. Der Server löst Kurzlinks auf, erkennt Plattform und Objekt und liest Zeitraum, Personen und gegebenenfalls den Preis aus dem Link.
3. Der Server ruft die Seite ab, und zwar mit Zeitraum und Personenzahl der Reise, nicht mit denen aus dem geteilten Link.
4. Danach ist der `importStatus`:

| Status | Bedeutung | Was die App tun sollte |
|---|---|---|
| `ready` | Steckbrief gefüllt | nichts |
| `partial` | Nur ein Teil ist bekannt. `importNote` nennt den Grund. | Bei gesperrter Plattform die Seite in der App öffnen und den Inhalt an `/capture` senden |
| `failed` | Auslesen fehlgeschlagen | Angaben von Hand ergänzen lassen |

Wird beim Teilen aus Safari der Seiteninhalt als `html` mitgeschickt, entfällt der Abruf durch den Server.

Derselbe Link ein zweites Mal ergibt Status 200 mit `duplicate: true` und der vorhandenen `candidateId`.

### Steckbrief

Der Steckbrief steht unter `listing.profile`. Die vollständige Struktur ist in `backend/src/import/profile.ts` definiert. Wichtige Regeln:

- `null` bedeutet „nicht bekannt". Es wird nichts geschätzt.
- `uncertain` listet die Feldpfade, deren Wert aus Fließtext stammt oder widersprüchlich war, zum Beispiel `livingAreaSqm` oder `amenities.grill`. Die App markiert diese Felder. Eine Korrektur von Hand entfernt die Markierung.
- `warnings` enthält Hinweise für die Reisegruppe, etwa widersprüchliche Gästezahlen oder ein Preis für eine andere Personenzahl.
- `fillPercent` am Angebot zeigt, wie vollständig der Steckbrief ist.
- `kind` ist `vacation_home`, `hotel` oder `package`. Nur bei Hotels und Pauschalreisen ist `packageTrip` gefüllt.

### Preise

Jeder Preis ist ein eigener Eintrag mit Zeitpunkt, Zeitraum, Personenzahl und Herkunft (`capture`: `import`, `device`, `manual`, `auto`). In der Liste erscheint bevorzugt der neueste Preis, der für diese Reise erfasst wurde (`forThisTrip: true`).

## Bilder

`GET /candidates/:id` liefert `photos` in der Reihenfolge der Anzeige, das erste ist das Titelbild:

```json
{ "id": "9f2c1a0b3d4e5f67", "url": "https://…/bild.jpg", "thumbUrl": null, "width": null, "height": null, "caption": null }
```

- `url` ist die Adresse des Originals in voller Qualität beim Bilddienst der Plattform. Die App lädt von dort und speichert auf dem Gerät zwischen.
- `thumbUrl` ist eine kleinere Fassung (rund 720 px), wo der Bilddienst der Plattform das anbietet (derzeit Airbnb), sonst `null`. Dann verkleinert die App das Original selbst.
- `id` bleibt für dieselbe Bildadresse gleich und taugt als Cache-Schlüssel.
- Die Liste ist leer bei Angeboten, die vor dieser Funktion importiert wurden, oder wenn die Seite keine Bilder preisgab. Dann gilt `coverImageUrl`.
- Die Bildadressen werden beim Import aus den Seitendaten gelesen (JSON-LD, Seitenzustand, bei Geräte-Erfassung auch die Bilder im HTML). Die App muss sie bei `/capture` nicht getrennt schicken.
- Die Bilder liegen bisher nicht auf dem eigenen Server. Eine eigene Bildablage mit Vorschaubildern ist als nächster Schritt vorgesehen; die Felder bleiben dabei gleich, nur die Adressen zeigen dann auf die API.

Die Liste `GET /trips/:id/candidates` enthält weiter `coverImageUrl` und zusätzlich `photoCount`.

- Beim Auslesen auf dem Gerät: Bilder im Block `tp-captured-images` übernimmt der Server nur dann vollständig, wenn mindestens drei davon `data-gallery="1"` tragen oder die Seite selbst weniger als drei Bilder in ihren Daten hat. Sonst dienen sie nur als größere Fassung der Bilder, die die Seite ohnehin nennt. Die App markiert deshalb die Bilder der Galerie des Angebots.

## Bewertungen

`GET /candidates/:id` liefert zusätzlich `reviews`, entweder `null` oder:

```json
"reviews": {
  "summary": "Zwei bis drei Sätze …",
  "positives": ["Pool", "Lage"],
  "negatives": ["Liegen kosten extra"],
  "basedOn": 20,
  "generatedAt": "2026-11-15T18:02:11.000Z",
  "items": [ { "id": "3b1f…", "author": "Jörg", "date": "2026-08-14", "rating": 8.5, "scale": 10, "title": null, "text": "…", "platform": "check24" } ]
}
```

- `reviews` ist `null`, wenn weder einzelne Bewertungen noch eine Zusammenfassung vorliegen, etwa bei Angeboten, die vor dieser Funktion importiert wurden. "Aktualisieren" oder erneutes Auslesen auf dem Gerät füllt das Feld.
- `summary`, `positives` und `negatives` schreibt die KI aus den Bewertungen der Seite, auf Deutsch, auch wenn die Bewertungen in anderen Sprachen sind. `positives` und `negatives` haben je höchstens vier Stichpunkte. `summary` kann `null` sein. `basedOn` ist die Zahl der zugrunde liegenden Bewertungen, `generatedAt` der Zeitpunkt des Auslesens.
- `items` sind die einzelnen Bewertungen im Wortlaut der Seite, höchstens 40, neueste zuerst, wenn alle ein ISO-Datum haben, sonst in der Reihenfolge der Seite. `rating` steht in der Skala der Plattform; `scale` ist `null`, wenn die Seite sie nicht nennt, dann gilt `profile.rating.scale`. `date` ist ein ISO-Datum (`JJJJ-MM-TT`), wo die Seite eines liefert, sonst ihr Wortlaut ("August 2026") oder `null`. `author` ist der Anzeigename von der Seite oder `null`. `items` kann leer sein, obwohl es eine Zusammenfassung gibt: Einzelne Bewertungen kommen nur aus den Daten der Seite, die Zusammenfassung auch aus dem sichtbaren Text.
- Beim Auslesen auf dem Gerät lohnt es, die Bewertungsliste vorher aufzuklappen.
- Die Gesamtnote steht weiter in `profile.rating` (`value`, `scale`, `count`).

## Hinweise ausblenden

Hinweise gehören zum Angebot (`listing.profile.warnings`) und werden bei jedem Auslesen neu geschrieben. Ausblenden merkt sich deshalb die Reise, nicht das Angebot:

- `PATCH /candidates/:id` mit `{"hiddenWarnings": ["Wortlaut des Hinweises", …]}` ersetzt die Liste der ausgeblendeten Hinweise (höchstens 40). `[]` blendet alles wieder ein. Gilt für alle Mitglieder der Reise, ab Rolle Mitglied.
- `GET /candidates/:id` liefert `warnings: [{ "text": "…", "hidden": false }]` mit allen Hinweisen in der Reihenfolge des Steckbriefs. `listing.profile.warnings` bleibt die ungefilterte Liste.
- `GET /trips/:tripId/candidates` liefert je Angebot `listing.warningCount`, die Zahl der noch sichtbaren Hinweise.
- Ausgeblendet wird nach Wortlaut. Schreibt die KI einen Hinweis beim Aktualisieren anders, erscheint er wieder. Hinweise nicht über `PATCH …/profile` löschen: das nächste Auslesen bringt sie zurück.

## Vergleich

`GET /trips/:tripId/compare?ids=<id>,<id>,…` stellt Angebote einer Reise nebeneinander. Ohne `ids` alle, die nicht abgelehnt sind. Höchstens zwölf; `404`, wenn eine Id nicht zur Reise gehört.

```json
{
  "candidates": [ { "id": "…", "listing": { … }, "price": { … }, "votes": { … }, "bestCount": 7, "summary": "…", "highlights": ["…"], "warnings": ["…"], "reviewSummary": { "summary": "…", "positives": [], "negatives": [] } } ],
  "criteria": [ { "key": "price.total", "label": "Gesamtpreis", "group": "price", "format": "eur", "better": "lower", "values": [3000, 4200], "best": ["<id>"] } ]
}
```

- `candidates` hat die Felder der Liste, dazu Kurztext, Höhepunkte, sichtbare Hinweise und die Zusammenfassung der Bewertungen (`null`, wenn es keine gibt). Reihenfolge wie in `ids`.
- `criteria` ist eine Zeile je Kriterium, `values` läuft parallel zu `candidates`. `null` heißt unbekannt. Zeilen ohne einen einzigen Wert fehlen, ebenso Ausstattung, die kein Angebot hat.
- `group`: `price`, `space`, `rating`, `location`, `amenities`, `rules`, `votes`. `format`: `eur`, `number`, `sqm`, `meters`, `km`, `rating` (auf eine Skala von 10 umgerechnet), `boolean`, `text`.
- `better` ist `higher`, `lower`, `true` oder `null` (nicht wertbar). `best` nennt die Angebote, die in der Zeile vorn liegen; leer, wenn weniger als zwei Werte bekannt oder alle gleich sind.
- Preise zählen nur, wenn sie als Gesamtpreis für den Zeitraum dieser Reise vorliegen (`price.forThisTrip`), sonst steht `null` in den Preiszeilen.
- `bestCount` zählt, in wie vielen Zeilen ein Angebot vorn liegt. Das ist ungewichtet und nur eine erste Orientierung.

## Dasselbe Objekt auf anderen Plattformen

Ein Angebot kann mehrere Quellen haben. Die erste ist der Link, mit dem es geteilt wurde; sie bestimmt Titel, Text, Hinweise, Bilder und den Preis im Steckbrief. Weitere Quellen füllen nur Lücken im Steckbrief und bringen eigene Bewertungen und Preise mit.

**Suchen**

- `POST /candidates/:id/sources/search` startet die Suche im Netz (`202`, `{ "status": "running" }`). `503 search_unavailable` ohne KI-Schlüssel, `429 too_soon` innerhalb von zehn Minuten nach der letzten Suche. Jede Suche kostet Geld, deshalb nur auf Knopfdruck.
- Das Ergebnis steht in `GET /candidates/:id` unter `otherPlatforms`:

```json
"otherPlatforms": {
  "available": true,
  "status": "idle | running | done | failed",
  "searchedAt": "2026-11-15T22:50:00.000Z",
  "note": "Auf anderen Plattformen wurde nichts Neues gefunden.",
  "suggestions": [ { "id": "…", "url": "https://…", "platform": "airbnb", "title": "…", "reason": "Gleicher Ort, drei Schlafzimmer, Pool.", "confidence": "high | medium | low", "status": "proposed | accepted | rejected" } ]
}
```

- Solange `status` `running` ist, die Detailansicht alle paar Sekunden neu laden; eine Suche dauert etwa 20 bis 60 Sekunden.
- Treffer sind Vorschläge. Ob es wirklich dasselbe Haus ist, bestätigt ein Mensch: Link öffnen lassen, dann
  `POST /candidates/:id/suggestions/:suggestionId` mit `{ "decision": "accept" }` oder `{ "decision": "reject" }`. `accept` hängt die Seite als weitere Quelle an und liest sie (`202`, mit `sourceId`). Optional `html` mitgeben, wenn die App die Seite schon auf dem Gerät gelesen hat.

**Von Hand**

- `POST /candidates/:id/sources` mit `{ "url": "…", "html": "…optional" }` hängt einen Link als weitere Quelle an (`202`; `200`, wenn er schon dranhängt; `409 already_listed`, wenn der Link bereits ein eigenes Angebot ist).
- `DELETE /candidates/:id/sources/:sourceId` nimmt eine weitere Quelle wieder weg, samt ihren Preisen und Bewertungen (`204`). Die erste Quelle lässt sich nicht entfernen (`409 primary_source`). Angaben, die die Quelle in den Steckbrief gefüllt hat, bleiben stehen.

**Quellen in der Detailansicht**

`sources` ist nach Alter sortiert, die erste ist die führende:

```json
{ "id": "…", "platform": "casamundo", "url": "…", "canonicalUrl": "…", "primary": false, "read": false, "needsDevice": true, "title": null, "rating": null, "reviewCount": null, "lastFetchedAt": "…" }
```

- `needsDevice: true` heißt: Die Plattform hat den Server abgewiesen. Die App öffnet `url` im Hintergrund und schickt die Seite an `POST /candidates/:id/capture` mit `{ "html": "…", "sourceId": "<id der Quelle>" }`. Ohne `sourceId` gilt die Seite wie bisher der führenden Quelle.
- `rating` ist die Note dieser Plattform (`value`, `scale`, `count`), `title` der Titel dort, `reviewCount` die Zahl der dort gelesenen Einzelbewertungen. Alle drei sind `null`, solange die Quelle nicht gelesen ist.
- `prices[].listingSourceId` sagt, von welcher Quelle ein Preis stammt. So lassen sich Preise je Plattform nebeneinanderstellen.
- `reviews.items[].platform` nennt die Herkunft jeder Bewertung. `reviews.summary` läuft über alle Plattformen, sobald mehr als eine Bewertungen geliefert hat.

## Bewertungen vom Gerät

Beim Auslesen auf dem Gerät kann die Seite einen versteckten Block `<div id="tp-captured-reviews" hidden>` mit einem `<div data-review>` je Bewertung enthalten (Fließtext, höchstens 150 Einträge zu je 3000 Zeichen; was darüber hinausgeht, verwirft der Server). Der Server nutzt ihn für die Zusammenfassung und, wenn die Seitendaten selbst keine einzelnen Bewertungen enthalten, für `reviews.items`. Die KI sortiert aus, was keine Gästebewertung ist, und trennt Name, Datum und Note ab; der Text wird wörtlich aus dem Block geschnitten. Das geschieht in eigenen kleinen Aufrufen zu je 20 Blöcken, getrennt vom Steckbrief. Schlägt ein Aufruf fehl, bleiben seine Blöcke unsortiert als Bewertungen erhalten (ohne Name, Datum, Note). Das Protokoll nennt je Auslesen die Zahl der Blöcke (`review blocks N`) und wie viele Bewertungen daraus wurden.

## Ungefähre Lage

Stehen `"lat"` und `"lon"` in `profile.uncertain`, ist die Position nur ungefähr: entweder hat die KI sie aus dem Text abgeleitet, oder die Plattform zeigt bewusst nur die Umgebung (Airbnb, Vrbo). Die App zeichnet dann besser einen Kreis als eine Nadel. Eine von Hand korrigierte Position gilt wieder als genau. Die Liste `GET /trips/:tripId/candidates` liefert dasselbe als `listing.locationApproximate` (boolean).

## Verfügbarkeit und Preise für die ganze Reise prüfen

`POST /trips/:tripId/refresh` (gleichbedeutend `POST /trips/:tripId/check`), ab Rolle Mitglied. Prüft alle nicht abgelehnten Angebote für den ersten Zeitraum und die Personenzahl der Reise. `409 no_dates`, wenn die Reise keinen Zeitraum hat. Antwort `202`:

```json
{ "startDate": "2027-05-15", "endDate": "2027-05-29", "adults": 4, "children": 4,
  "checks": [ { "candidateId": "…", "platform": "airbnb", "mode": "server | device | skipped", "needsDevice": false, "checkUrl": "https://…" } ] }
```

- `mode: "server"`: Der Server liest die Seite im Hintergrund für die Reisedaten. Das Angebot steht solange auf `importStatus: "pending"`; fertig ist es, wenn die Liste wieder `ready`, `partial` oder `failed` zeigt.
- `mode: "device"` (`needsDevice: true`): Die Plattform gibt dem Server nichts oder zu wenig. Die App öffnet `checkUrl` und schickt die Seite an `POST /candidates/:id/capture` mit `{ "html": "…", "forTrip": true }`. `forTrip: true` sagt dem Server, dass die Seite für Zeitraum und Personen der Reise geöffnet war; nur dann gelten Preis und Verfügbarkeit für die Reise.
- `mode: "skipped"`: in der letzten Minute schon gelesen.
- `POST /candidates/:id/refresh` ruft ebenfalls mit Zeitraum und Personen der Reise ab, wo die Plattform das über den Link erlaubt (Airbnb, FeWo-direkt/Vrbo, Booking, Casamundo, Check24, Novasol). Bei Airbnb, FeWo-direkt/Vrbo, Casamundo, Check24 und Novasol rechnet erst die geladene Seite den Preis aus; dort ist `needsDevice` immer `true` und die Reiseprüfung liefert `mode: "device"`. Kennt der Server für eine Plattform keine Linkform mit Reisedaten, liefert die Reiseprüfung `mode: "skipped"` (nicht öffnen), und ein `forTrip: true` wird dort nicht gewertet, damit kein Preis für einen anderen Zeitraum bei der Reise landet. Novasol-Links tragen `start=TT-MM-JJJJ`, `nights`, `adult`, `child`.

In `GET /trips/:tripId/candidates` steht je Angebot:

- `availability`: `"available"`, `"unavailable"` oder `"unknown"`, bezogen auf Zeitraum und Personen der Reise. `unknown`, solange kein Auslesen für die Reisedaten etwas dazu gesagt hat.
- `availabilityCheckedAt`: wann das zuletzt festgestellt wurde, sonst `null`.
- `price.available`: dasselbe als `true`, `false` oder `null` am Preis. Bei `unavailable` bleibt der letzte bekannte Preis in `price` stehen, damit er ausgegraut gezeigt werden kann; im Steckbrief ist `profile.price.totalEur` dann `null`.
- `needsDevice` und `checkUrl`: ob nur das Gerät prüfen kann, und die Seite mit den Reisedaten.

Grenzen: Ob ein Zeitraum frei ist, steht bei den meisten Plattformen nur in der gerenderten Seite. Der Server-Abruf sieht bei Airbnb und FeWo-direkt wenig Text und oft keinen Gesamtpreis; verlässlich ist dort das Auslesen auf dem Gerät. Bleibt nach dem Server-Lauf `availability` auf `unknown`, lohnt der Gerätelauf über `checkUrl`.

### Prüflauf: was ein capture mit `forTrip: true` ändert

- Übernommen werden nur Preis und Verfügbarkeit. Titel, Texte, Bilder, Lage und Hinweise bleiben, wie die vollständige Einlesung sie hinterlassen hat. Ausnahme: Das Angebot wurde noch nie vollständig eingelesen.
- Der Betrag muss auf genau dieser Seite stehen. Ein früher gelesener Betrag wird nicht unter dem Reisezeitraum weitergeführt. Findet der Prüflauf weder Betrag noch Aussage zur Verfügbarkeit, gilt der Reisepreis als unbekannt; `price` zeigt dann wieder den Preis aus dem geteilten Link (`forThisTrip: false`).
- Sicherheitsabfragen ("Bot oder Mensch?", "Just a moment…", "Access Denied") verwirft der Server, auch wenn das Gerät sie schickt. Die Antwort bleibt 202, am Angebot ändert sich nichts.

## Angebot verschieben und Merkliste

### `POST /candidates/:id/move`

Body `{ "tripId": "<Zielreise>" }`, ab Rolle Mitglied in beiden Reisen. Antwort 200 `{ "candidateId": "…", "tripId": "…" }`; die `candidateId` bleibt dieselbe.

- Mit umziehen: Steckbrief, Quellen, Bilder, Bewertungen, Notizen, Tags, Kommentare, ausgeblendete Hinweise, Vorschläge anderer Plattformen.
- Bleibt zurück: Stimmen (gelöscht), Status (zurück auf `new`, Ablehnungsgrund geleert). Preise und Verfügbarkeit, die für die alte Reise gelesen wurden, zählen in der neuen nicht; sie sind wieder da, wenn das Angebot zurückzieht. Preise aus dem geteilten Link bleiben sichtbar (`forThisTrip: false`).
- 409 `already_in_trip`: das Inserat gibt es in der Zielreise schon. 404: Zielreise unbekannt oder kein Mitglied.

### Merkliste

Jede Reise trägt `kind: "trip" | "watchlist"`. Jede Person hat genau eine eigene Merkliste; `GET /trips` legt sie beim ersten Aufruf an und liefert sie mit (Titel "Merkliste", ohne Zeiträume, nur die Person selbst). "Auf die Merkliste" ist `move` mit deren `tripId`, zurück genauso. Importieren direkt in die Merkliste geht wie in jede Reise.

Auf der Merkliste antworten mit 409 `watchlist`: `PATCH /trips/:id`, `POST /trips/:id/invites`, `POST /trips/:id/date-options`. `POST /trips/:id/refresh` und `/check` antworten mit 409 `no_dates`. In `candidateCount` und Listen zählt sie wie eine Reise; die App sollte sie getrennt anzeigen.

## Muss- und Wunsch-Kriterien mit Ampel

### `GET /trips/:id/criteria`, `PUT /trips/:id/criteria`

```json
{ "criteria": [ { "id": "…", "key": "bedrooms", "label": null, "level": "must", "target": 4 },
                { "id": "…", "key": "amenities.pool", "label": null, "level": "wish", "target": null },
                { "id": "…", "key": "custom", "label": "Ruhige Lage", "level": "must", "target": null } ],
  "measurable": [ { "key": "bedrooms", "label": "Schlafzimmer", "group": "space", "format": "number", "rule": "min" } ] }
```

- `measurable` ist die Auswahl dessen, was der Server am Steckbrief messen kann: dieselben Zeilen wie im Vergleich. `rule: "min"` heißt mindestens `target`, `"max"` höchstens `target` (Preise in Euro, Entfernungen in Metern bzw. km, Bewertung auf einer Skala bis 10), `"yes"` heißt muss vorhanden sein und braucht kein `target`.
- `key: "custom"` mit `label` ist ein eigenes Kriterium, das nur Menschen beurteilen.
- `PUT` ersetzt die ganze Liste (höchstens 30, ab Rolle Mitglied). Einträge mit ihrer bisherigen `id` behalten die von Hand gesetzten Urteile; die Reihenfolge der Liste bleibt.

### Urteil je Angebot

Jeder Eintrag in `GET /trips/:id/candidates` trägt `criteria` (oder `null`, wenn die Reise keine Kriterien hat):

```json
{ "light": "green | yellow | red", "must": { "met": 2, "missed": 0, "unknown": 1 }, "wish": { "met": 1, "missed": 1, "unknown": 0 } }
```

Rot: ein Muss ist verfehlt. Gelb: ein Muss ist offen oder ein Wunsch nicht erfüllt oder offen. Grün: alles erfüllt.

`GET /candidates/:id` trägt dasselbe unter `criteria`, zusätzlich `results` mit je `id`, `key`, `label`, `level`, `rule`, `format`, `target`, `value`, `status` (`met | missed | unknown`) und `manual`.

Von Hand urteilen: `PATCH /candidates/:id` mit `{ "criteriaChecks": { "<criterionId>": "met" | "missed" } }`. Das Feld ersetzt alle bisherigen Urteile dieses Angebots; ein Urteil von Hand geht dem gemessenen Wert vor. Beim Verschieben in eine andere Reise verfallen die Urteile.

## Mehrere Zeiträume

- Jeder Eintrag der Angebotsliste trägt `periods`: je Zeitraum der Reise `dateOptionId`, `label`, `startDate`, `endDate`, `availability`, `totalCents`, `kind`, `checkedAt`, `checkUrl`.
- `price`, `availability` und `checkUrl` der Liste gelten für den frühesten Zeitraum. Mit `GET /trips/:id/candidates?dateOptionId=…` gelten sie für den genannten.
- `POST /trips/:id/check` und `/refresh` nehmen `{ "dateOptionId": "…" }` (oder denselben Query-Parameter) und prüfen diesen Zeitraum; die Antwort nennt `dateOptionId`. Ohne Angabe wie bisher der früheste.
- `POST /candidates/:id/capture` nimmt neben `forTrip: true` ebenfalls `dateOptionId`, damit der Preis beim richtigen Zeitraum landet.
- Geändert: Ein Preis zählt für die Reise nur noch, wenn er zum gefragten Zeitraum gehört, nicht mehr zu irgendeinem der Zeiträume.

## Tageslimit

Je Person und Tag (UTC) 400 Auswertungen (Import, capture, refresh, Reiseprüfung, weitere Quelle) und 30 Suchen nach demselben Objekt. Danach antworten diese Aufrufe mit 429 `daily_limit` und einer Meldung zum Anzeigen. Lesen, Abstimmen und Kommentieren bleiben möglich.

## Phasen der Reise

Jede Reise trägt `phase` (gespeichert) und `currentPhase` (heute gültig): `framing`, `research`, `decision`, `booking`, `preparation`, `travelling`, `review`, `archived`. Neue und bestehende Reisen stehen auf `research`.

- `currentPhase` rückt von selbst vor: Eine Reise in `booking`, `preparation` oder `travelling` ist ab dem Anreisetag `travelling` und nach dem Abreisetag `review`. Maßgeblich ist der beschlossene Zeitraum, sonst der früheste. Die App öffnet die Oberfläche zu `currentPhase`.
- Von Hand setzen: `PATCH /trips/:id` mit `{ "phase": "…" }` (Organisator), auch zurück. Dabei wird nichts gelöscht.
- `status` (planning, decided, booked, archived) bleibt bestehen und wird bei der Entscheidung mitgeführt.

## Pitch und Entscheidung

### `POST /trips/:id/pitch` (Organisator)

Body `{ "candidateIds": ["…", "…"], "voteDeadline": "2027-01-10T18:00:00Z" }`, zwei bis acht Finalisten. Setzt `finalist` an den Angeboten (alle anderen verlieren es) und die Phase auf `decision`. Einzelne Angebote lassen sich auch über `PATCH /candidates/:id` mit `{ "finalist": true | false }` aufnehmen oder herausnehmen. Jeder Listeneintrag trägt `finalist`.

### `PUT /trips/:id/ranking` (alle, auch Gäste)

Body `{ "order": ["<bester>", "<zweiter>", …] }`: die eigene Rangfolge der Finalisten, darf unvollständig sein. Punkte: bei n Finalisten bekommt der erste Platz n, jeder weitere einen weniger, nicht genannte 0.

### `GET /trips/:id/pitch`

```json
{ "phase": "decision", "voteDeadline": null, "decided": null, "maxPoints": 8,
  "finalists": [ { "place": 1, "points": 7, "firstPlaces": 2, "candidate": { "…wie in der Angebotsliste…" },
                   "summary": "…", "highlights": ["…"], "warnings": ["…"], "reviewSummary": { "summary": "…", "positives": [], "negatives": [] } } ],
  "rankings": [ { "userId": "…", "name": "…", "order": ["…"], "updatedAt": "…" } ],
  "myRanking": ["…"],
  "missing": [ { "userId": "…", "name": "…" } ] }
```

- Reihenfolge: Angebote mit Veto stehen hinter denen ohne, dann nach Punkten, bei Gleichstand nach ersten Plätzen. Vetos kommen weiter aus `PUT /candidates/:id/vote`.
- `candidate` enthält Preis, Verfügbarkeit, Ampel und Stimmen wie in der Liste. Zusammen mit `summary`, `highlights`, `warnings` und `reviewSummary` ist das die Entscheidungsvorlage.
- `missing` nennt, wer noch keine Rangfolge abgegeben hat.
- Die drei Aufrufe oben und die beiden folgenden antworten alle mit diesem Objekt.

### `POST /trips/:id/decision`, `DELETE /trips/:id/decision` (Organisator)

Body `{ "candidateId": "…", "dateOptionId": "…" }` (Zeitraum optional, sonst der früheste). Hält Gewinner und Zeitraum an der Reise fest (`decidedCandidateId`, `decidedDateOptionId`, `decidedAt`), setzt die Phase auf `booking` und den Status auf `decided`. Die übrigen Angebote bleiben unverändert; verschieben auf die Merkliste geht mit `move`. `DELETE` nimmt die Entscheidung zurück, die Reise steht wieder auf `decision`.

## Gemeinsame Kasse und Abrechnung

Kosten werden zwischen den **Haushalten** der Reise geteilt. Ein Haushalt kann Personen ohne App enthalten (Kinder, Partner).

### Haushalte

- `POST /trips/:id/parties/suggest`: legt als Startpunkt je Mitglied einen Haushalt an (409 `already_set_up`, wenn es schon welche gibt).
- `PUT /trips/:id/parties` mit `{ "parties": [ { "id": "…", "name": "Familie A", "adults": 2, "children": 2, "memberIds": ["<userId>"] } ] }` ersetzt die Liste. Einträge mit ihrer `id` behalten ihre Ausgaben. Ab Rolle Mitglied.

### Ausgaben

`POST /trips/:id/expenses` (alle, auch Gäste), `PATCH /expenses/:id`, `DELETE /expenses/:id` (Gäste nur eigene):

```json
{ "title": "Einkauf", "amountCents": 8450, "paidBy": "<partyId>", "spentOn": "2027-05-16", "category": "Lebensmittel",
  "mode": null, "among": [], "weights": {}, "note": null }
```

- `mode` leer: die Aufteilung der Reise (`splitMode`, Standard `equal`: jeder Haushalt gleich viel). `heads`: nach Köpfen, Kinder zählen mit `childWeight` der Reise (Standard 1, zum Beispiel 0.5). `custom`: nach `weights` je Haushalt, etwa die Zahl der Teilnehmenden (Frauen-Event: `{ "<A>": 1, "<B>": 1 }`).
- `among`: nur diese Haushalte teilen; leer heißt alle.
- `splitMode` und `childWeight` setzt `PATCH /trips/:id`.
- 409 `no_parties`, solange keine Haushalte angelegt sind.

### `GET /trips/:id/ledger`

```json
{ "splitMode": "equal", "childWeight": 1, "myPartyId": "…", "totalCents": 38000,
  "parties": [ { "id": "…", "name": "Familie A", "adults": 2, "children": 2, "memberIds": ["…"], "paidCents": 30000, "shareCents": 14000, "balanceCents": 16000 } ],
  "expenses": [ { "id": "…", "title": "…", "amountCents": 8000, "paidBy": "…", "mode": "custom", "among": [], "weights": {}, "spentOn": "…", "unsplit": false } ],
  "payments": [ { "id": "…", "fromParty": "…", "toParty": "…", "amountCents": 10000 } ],
  "transfers": [ { "from": "<partyId>", "to": "<partyId>", "amountCents": 6000 } ] }
```

- `balanceCents` positiv: bekommt Geld zurück; negativ: schuldet noch.
- `transfers` ist der Vorschlag mit möglichst wenigen Ausgleichszahlungen, bereits geleistete `payments` sind abgezogen.
- `unsplit: true` an einer Ausgabe heißt: Sie lässt sich nicht verteilen (Haushalt entfernt) und ist nicht eingerechnet.
- Alle schreibenden Aufrufe liefern das Kassenblatt unter `ledger` mit zurück.

### Ausgleich abhaken

`POST /trips/:id/payments` mit `{ "fromParty": "…", "toParty": "…", "amountCents": 6000 }` (ab Mitglied), `DELETE /trips/:id/payments/:paymentId`.

## Buchung: Buchungen, Zahlungsplan, Fristen, Dokumente

Die App bucht nicht. Sie hält fest, was gebucht wurde.

### Buchungen

`GET /trips/:id/bookings` liefert die Übersicht:

```json
{ "bookings": [ { "id": "…", "kind": "accommodation", "title": "…", "provider": "Novasol", "reference": "NOV-123", "candidateId": "…",
                  "status": "planned | booked | cancelled", "startsAt": "2027-05-15T16:00", "endsAt": "2027-05-29T10:00", "place": "…",
                  "totalCents": 578200, "depositCents": 40000, "depositReturnedOn": null, "freeCancellationUntil": "2027-03-01",
                  "bookedByParty": "<partyId>", "notes": null,
                  "payments": [ { "id": "…", "label": "Anzahlung", "amountCents": 150000, "dueOn": "2027-01-15", "paidOn": null, "paidByParty": null, "refundable": false } ],
                  "documents": [ { "id": "…", "title": "Bestätigung", "kind": null, "contentType": "application/pdf", "sizeBytes": 81234, "createdAt": "…" } ] } ],
  "documents": [ "…Unterlagen ohne Buchung, gleiche Form…" ],
  "deadlines": [ { "type": "payment | cancellation | start", "on": "2027-01-15", "bookingId": "…", "paymentId": "…", "label": "Anzahlung: …", "amountCents": 150000, "overdue": false } ],
  "totals": { "bookedCents": 578200, "plannedCents": 578200, "paidCents": 0, "openCents": 578200, "depositsOutCents": 0 } }
```

- `kind`: `accommodation`, `flight`, `car`, `ferry`, `train`, `insurance`, `activity`, `other`.
- `POST /trips/:id/bookings` (ab Mitglied). Mit `candidateId` übernimmt der Server Titel und Ort aus dem Angebot. `PATCH /bookings/:id`, `DELETE /bookings/:id`.
- Wird eine Unterkunft mit `status: "booked"` gespeichert, rückt die Reise auf Phase `preparation` und Status `booked`.
- Zeiten sind Ortszeit wie auf der Bestätigung, als `JJJJ-MM-TT` oder `JJJJ-MM-TTThh:mm`.
- Zahlungsplan: `POST /bookings/:id/payments` mit `label`, `amountCents`, `dueOn`, optional `paidOn`, `paidByParty`, `refundable` (Kaution: `true`). `PATCH /booking-payments/:id` (bezahlt abhaken: `paidOn` und `paidByParty` setzen), `DELETE /booking-payments/:id`.
- `deadlines` nennt offene Zahlungen, Stornofristen und Beginn jeder Buchung, früheste zuerst; `overdue` für verpasste Zahlungen und Fristen.
- Alle schreibenden Aufrufe liefern die Übersicht unter `overview` mit zurück.
- Verbindung zur Kasse: Bezahlte Raten mit `paidByParty` zählen im Kassenblatt als geteilte Kosten nach der Aufteilung der Reise (`ledger.bookingPayments`), ohne sie ein zweites Mal einzugeben. Kautionen (`refundable`) zählen nicht.

### Dokumente

- Hochladen: `POST /trips/:id/documents?title=…&kind=…&bookingId=…`. Der Körper ist die Datei selbst, der `Content-Type` ihr Typ: `application/pdf`, `image/jpeg`, `image/png`, `image/heic`, `image/heif`, `image/webp`, `text/plain`. Höchstens 20 MB. Sonst 415 `unsupported_file`. Ab Rolle Mitglied.
- Abrufen: `GET /documents/:id/file` mit Anmeldung (alle Mitglieder der Reise, auch Gäste). Nicht zwischenspeichern außer für die Offline-Ansicht der App.
- `PATCH /documents/:id` (`title`, `kind`, `bookingId`), `DELETE /documents/:id`.
- Die Dateien liegen in der VM in einem eigenen Volume und werden nachts mit der Datenbank gesichert und auf die Storage Box gespiegelt, jeweils unverschlüsselt. Für Ausweiskopien und Ähnliches bitte erst nutzen, wenn die Verschlüsselung geklärt ist.

## Listen: Packen, Einkauf, Aufgaben

`GET /trips/:id/checklists`:

```json
{ "lists": [ { "list": "packing", "total": 12, "done": 3,
               "items": [ { "id": "…", "list": "packing", "title": "Badesachen", "quantity": null, "assignedTo": null, "assignedParty": null,
                            "dueOn": null, "done": false, "doneBy": null, "doneAt": null, "private": false, "position": 0, "createdBy": "…" } ] } ],
  "templates": [ { "key": "beach", "label": "Strand und Pool", "list": "packing", "count": 10 } ] }
```

- Die Listen `packing`, `shopping` und `todo` gibt es immer; jeder andere Name unter `list` legt eine eigene Liste an.
- `POST /trips/:id/checklist-items` (alle, auch Gäste), `PATCH /checklist-items/:id`, `DELETE /checklist-items/:id`. Abhaken ist `{ "done": true }`.
- `private: true` macht einen Eintrag zur persönlichen Liste: nur wer ihn angelegt hat, sieht ihn.
- `assignedTo` (Mitglied) oder `assignedParty` (Haushalt) für "wer bringt was mit" und Aufgaben, `dueOn` für Fristen.
- Vorlagen: `POST /trips/:id/checklists/template` mit `{ "template": "beach", "private": false }`. Vorhandene Einträge gleichen Namens bleiben, die Antwort nennt `added`. Vorlagen: `basics`, `beach`, `ski`, `toddler`, `dog`, `home` (Aufgaben vor der Abreise), `firstDay` (Einkauf für den ersten Tag).
- Alle schreibenden Aufrufe liefern die Listen unter `checklists` mit zurück.

## Vorbereitung: Anreise, Zimmer, Aktivitäten

`GET /trips/:id/plan`:

```json
{ "legs": [ { "id": "…", "partyId": "…", "direction": "outbound", "mode": "car", "fromPlace": "München", "toPlace": "Zadar",
              "departAt": "2027-08-20T06:00", "arriveAt": null, "stops": [ { "place": "Ljubljana", "note": "Übernachtung" } ],
              "bookingId": null, "notes": null, "position": 0 } ],
  "rooms": [ { "id": "…", "name": "Schlafzimmer 1", "beds": "1 Doppelbett", "partyId": null, "occupants": ["Oma", "Opa"], "notes": null, "position": 0 } ],
  "activities": [ { "id": "…", "title": "Bootstour Kornaten", "place": null, "url": null, "status": "idea", "startsAt": null, "endsAt": null,
                    "costCents": 4500, "costNote": "pro Person", "bookingId": null, "notes": null, "createdBy": "…",
                    "responses": [ { "userId": "…", "name": "Tante", "answer": "maybe" } ],
                    "tally": { "yes": 1, "maybe": 1, "no": 0 }, "myAnswer": "yes" } ] }
```

- Anreise: `POST /trips/:id/legs`, `PATCH /legs/:id`, `DELETE /legs/:id`. `direction` ist `outbound`, `return` oder `during`, `mode` ist `car`, `flight`, `train`, `ferry`, `bus` oder `other`. `partyId` ist der Haushalt aus der Kasse, `bookingId` verknüpft einen Flug oder eine Fähre aus den Buchungen. Zeiten sind Ortszeit als `2027-08-20` oder `2027-08-20T06:00`.
- Zimmer: `POST /trips/:id/rooms` (Pflicht `name`), `PATCH /rooms/:id`, `DELETE /rooms/:id`. `occupants` sind frei geschriebene Namen, `partyId` ordnet das Zimmer einem Haushalt zu.
- `POST /trips/:id/rooms/suggest` legt die Zimmer so an, wie der Steckbrief des entschiedenen Angebots sie nennt. Fehler 409: `already_set_up` (es gibt schon Zimmer), `no_decision`, `nothing_known`.
- Aktivitäten: `POST /trips/:id/activities` (Pflicht `title`, auch Gäste), `PATCH /activities/:id`, `DELETE /activities/:id`. `status` ist `idea`, `planned`, `done` oder `cancelled`. Mit `startsAt` stehen sie in der Reihenfolge des Kalenders, Ideen ohne Termin danach.
- Zu- und Absage: `PUT /activities/:id/response` mit `{ "answer": "yes" | "maybe" | "no" | null }`, jeder für sich, `null` nimmt die Antwort zurück.
- Alle schreibenden Aufrufe liefern den ganzen Plan unter `plan` mit zurück, dazu den Eintrag unter `leg`, `room` oder `activity`. Im PATCH reichen die geänderten Felder, geleerte als `null`.

## Unterwegs: Hausmappe und Heute

`GET /trips/:id/house`:

```json
{ "house": { "address": null, "lat": null, "lon": null, "checkInFrom": null, "checkOutUntil": null, "keyInfo": "Schlüsselkasten 4711",
             "wifiName": "Villa", "wifiPassword": "…", "contactName": null, "contactPhone": null, "rules": null, "waste": null,
             "emergency": null, "notes": null, "updatedBy": "…", "updatedAt": "…" },
  "suggestions": { "title": "…", "address": "Sukošan, Dalmatien, Kroatien", "lat": 44.05, "lon": 15.31, "checkInFrom": "16:00", "checkOutUntil": "10:00",
                   "arrival": "2027-08-21T16:00", "departure": "2027-08-28T10:00", "bookingId": "…", "reference": "NOV-123" } }
```

- `house` ist, was die Gruppe eingetragen hat. `suggestions` ist, was Steckbrief und Unterkunftsbuchung schon wissen. Die App zeigt für leere Felder den Vorschlag und bietet "übernehmen" an.
- `PUT /trips/:id/house` (Mitglieder, keine Gäste): nur die gesendeten Felder ändern sich, `null` leert eines. Antwort wie GET.
- Lesen dürfen alle Mitglieder der Reise, auch Gäste. Schlüsselcode und WLAN-Passwort liegen wie alles andere hinter der Anmeldung.
- `GET /trips/:id/today?date=2027-08-21` (Datum am Reiseort, ohne Angabe das Datum des Servers) liefert `date`, `arrivalDay`, `departureDay`, `legs` und `activities` dieses Tages (wie im Plan, abgesagte fehlen), `bookings`, die an dem Tag beginnen oder enden (`begins`, `ends`), `ideas` (Zahl der Ideen ohne Termin) sowie `house` und `suggestions`. Gedacht als Startseite der Phase Unterwegs und zum Vorhalten für offline.

## Offline geschriebene Einträge

`POST /trips/:id/expenses` und `POST /trips/:id/checklist-items` nehmen ein optionales Feld `clientId` (UUID, vom Gerät vergeben). Ein zweiter Aufruf mit derselben `clientId` in derselben Reise legt nichts Neues an, sondern antwortet mit 200 statt 201 und liefert den bestehenden Eintrag (`expense` oder `item`) samt Kassenblatt (`ledger`) oder Listen (`checklists`). So kann die App Einträge ohne Netz vormerken und später gefahrlos wiederholt senden.

## Abruf ohne Ergebnis

Liest das Gerät eine Seite für den Zeitraum, bevor Preis und Verfügbarkeit geladen sind, kommt ein Abruf ohne Ergebnis heraus. Er überschreibt nichts mehr: `price`, `availability` und `availabilityCheckedAt` zeigen weiter den letzten Abruf, der etwas fand, mit dessen Zeitpunkt. Zusätzlich nennt `emptyCheckAt` (im Listeneintrag und je Eintrag in `periods`) den Zeitpunkt, wenn der jüngste Abruf für den Zeitraum leer blieb, sonst `null`. `capture` antwortet weiter sofort mit 202; solange `importStatus` nicht `ready`, `partial` oder `failed` ist, läuft die Auswertung noch (üblich 20 bis 40 Sekunden).

`fitsParty` im Listeneintrag ist `false`, wenn das Inserat laut Steckbrief weniger Gäste aufnimmt (`maxGuests`), als die Reise Personen hat, `true`, wenn es passt, und `null`, wenn eines von beiden unbekannt ist. Bei `false` zeigen Plattformen statt eines Preises oft nur einen Hinweis zur Gästezahl.

Findet ein Abruf genau dasselbe wie der vorige (gleicher Betrag, gleiche Verfügbarkeit, gleicher Zeitraum), entsteht keine neue Preiszeile. Der Zeitpunkt der Bestätigung steht dann in `availabilityCheckedAt`, in `price.checkedAt` und in `periods[].checkedAt`; `price.capturedAt` bleibt der Zeitpunkt, zu dem der Preis zum ersten Mal so gesehen wurde. Wer auf das Ende eines Abrufs wartet, vergleicht `availabilityCheckedAt`, `price.checkedAt` oder `emptyCheckAt` mit dem Absenden.

## Einladungslink im Browser

Zwei öffentliche Antworten ohne Anmeldung, damit ein Tipp auf den Link die App öffnet:

- `GET /.well-known/apple-app-site-association`: `application/json`, `applinks` für `/einladung/*` und die App aus `APPLE_APP_ID` (Vorgabe `AX2SZQVU9L.com.von-bleichert.travelplanner`).
- `GET /einladung/:token`: kleine deutsche Seite mit dem Knopf „In der App öffnen" (`reiseplaner://einladung/<token>?server=<PUBLIC_BASE_URL>`). Der Token wird weder geprüft noch verbraucht, die Seite sieht für gültige und ungültige gleich aus. Mit `TESTFLIGHT_URL` in der Umgebung nennt sie den Link zum Laden der App. Im Kopf stehen `og:title`, `og:description`, `og:image` (`/app-icon.png`, 512 Pixel) und `apple-touch-icon`, damit Nachrichten-Apps eine Karte zeigen. Der Token steht nicht im Protokoll.

Eingelöst wird weiter nur über die API.

## Check24

Kurzlinks `c.24.de/pr/…` werden aufgelöst und als `check24` geführt (Kennung ist die Hotelnummer). Angebote, die vorher als `other` hereinkamen, stellt der Server beim nächsten `check`, `refresh` oder `capture` selbst um. Preise gibt es nur vom Gerät: `checkUrl` trägt den Zeitraum der Reise als festen Aufenthalt. Die Zimmerbelegung des geteilten Links bleibt dabei erhalten, weil ein Hotel kein Zimmer für die ganze Gruppe hat; `price.persons` nennt deshalb die Personen aus dem Link, nicht die der Reise.

## Bildgrößen

Der Server speichert keine Bilder, nur die Adressen bei den Portalen (`photos[].url`, `thumbUrl`). Airbnb, FeWo-direkt und Novasol (2048 Pixel) und Casamundo (`/large/`) werden auf die größte Fassung umgestellt. Check24 signiert jede Größe einzeln (`size=335c220`, `size=1920x` … als Pfadsegment, je mit eigener Prüfsumme); eine größere Fassung gibt es deshalb nur, wenn ihre Adresse in der Seite oder in `tp-captured-images` steht. Gleiche Bilder in zwei Größen erkennt der Server am Segment `source=` und behält die größere. Karten und Gästefotos fallen aus der Galerie.

## Große Seiten vom Gerät

Eine vom Gerät gelesene Seite (`html` bei Import, `capture`, weiterer Quelle) darf samt Umschlag höchstens 12 MB groß sein; darüber antwortet der Server mit 413 `too_large`. Die App sollte die Seite vor dem Senden ausdünnen. Der Server liest nur: `<meta>`, sichtbaren Text, `<img>` mit Adresse, `<script>` mit `type` `application/json` oder `application/ld+json` (auch mit `id` wie `__NEXT_DATA__`, `js-hotel-data`, `data-deferred-state`) und eingebettete Skripte, die `window.__NAME__ =` zuweisen. Gefahrlos entfernen lassen sich also: `<style>`, `<svg>`, `<template>`, `<iframe>`, `<noscript>`, `<link>`, Kommentare, Skripte mit `src`, eingebettete Skripte ohne `window.__`, sowie `data:`-Adressen in Attributen und `style`-Attribute.

## Gruppen

Eine Gruppe sind Leute, die immer wieder zusammen verreisen. Jede Reise der Gruppe steht allen Mitgliedern offen: Wer der Gruppe beitritt, wird Mitglied aller ihrer Reisen; eine neue Reise in der Gruppe bekommt alle als Mitglieder. Beim Umstellen wurden alle bisherigen Konten und Reisen in eine Gruppe „Unsere Gruppe" gelegt; das älteste Konto verwaltet sie.

Wer eine Gruppe verwaltet (`admin`), verwaltet auch alle ihre Reisen: `role` in `GET /trips` und `GET /trips/:id` ist für diese Person `organizer`, und alles, was dem Organisator vorbehalten ist (ändern, archivieren, löschen, verschieben, einladen, Schlussrunde, Entscheidung), steht ihr offen. Das gilt nicht für die Merkliste der Gruppe und nicht für Gäste. `members[].role` zeigt weiter die eingetragene Rolle. Gibt jemand die Verwaltung ab, endet das Recht für Reisen, die andere angelegt haben.

`GET /groups`:

```json
{ "groups": [ { "id": "…", "name": "Unsere Gruppe", "role": "admin", "createdAt": "…",
                "members": [ { "id": "…", "name": "Kristian", "role": "admin", "joinedAt": "…" } ],
                "trips": [ { "id": "…", "title": "Pfingsten 2027" } ] } ] }
```

- `POST /groups` mit `{ "name" }` legt eine Gruppe an, `PATCH /groups/:id` benennt sie um (nur Verwaltung).
- `POST /groups/:id/invites` (nur Verwaltung) mit optional `maxUses`, `expiresInDays` liefert einmalig `{ token, url, expiresAt, maxUses }`. Der Link funktioniert wie eine Einladung zu einer Reise, führt aber in die Gruppe.
- `DELETE /groups/:id/members/:userId` entfernt jemanden (Verwaltung) oder verlässt die Gruppe (man selbst). Die Reisen der Gruppe gehen mit, außer denen, die die Person selbst angelegt hat. 409 `last_admin`, wenn die Gruppe sonst niemanden hätte, der sie verwaltet.
- `PATCH /groups/:id/members/:userId` mit `{ "role": "admin" | "member" }` gibt die Verwaltung weiter oder teilt sie.
- Alle schreibenden Aufrufe antworten mit `{ groups }`.
- Reisen: `POST /trips` nimmt `groupId`. Ohne Angabe landet die Reise in der Gruppe der Person, wenn sie in genau einer ist; `groupId: null` hält sie privat. `PATCH /trips/:id` mit `groupId` legt eine Reise nachträglich in eine Gruppe. Jede Reise nennt ihre `groupId`.

### Einladungen

- `GET /auth/invites/:token` liefert jetzt `{ trip, group, role }`; eines von `trip` und `group` ist `null`.
- `POST /auth/invites/:token/accept` antwortet zusätzlich mit `groupId` (`tripId` ist bei einer Gruppeneinladung `null`).
- `POST /invites/redeem` (angemeldet) mit `{ "link": "…" }` löst einen erhaltenen Link ein; der ganze Link oder nur sein letzter Teil. Antwort 201 wie `accept`, mit `token: null`. Fehler: 400 `invite_unreadable`, 410 `invite_invalid`.

## Noch nicht vom Gerät gelesen

`GET /me/pending-readings` liefert über alle Reisen der Person die Inserate, die nur ein Gerät lesen kann und die noch kein Gerät gelesen hat, neueste zuerst, höchstens 50:

```json
{ "pending": [ { "candidateId": "…", "tripId": "…", "platform": "airbnb", "title": "…", "url": "https://…", "addedAt": "…" } ] }
```

Die App arbeitet die Liste nach der Anmeldung im Hintergrund ab: Seite öffnen, wie gewohnt an `POST /candidates/:id/capture` senden. Danach fehlt der Eintrag. Im Listeneintrag steht dasselbe als `deviceRead`.

## Flexibler Reisezeitraum

Eine Reise kann statt fester Daten (oder zusätzlich) ein Zeitfenster haben: `flexStart` (frühester Anreisetag), `flexEnd` (spätester Abreisetag), `nightsMin`, `nightsMax`. Setzen bei `POST /trips` oder `PATCH /trips/:id`; `flexStart` und `flexEnd` nur gemeinsam, zum Abschalten beide `null`.

- Jeder Aufenthalt, der im Fenster liegt und so lang ist wie erlaubt, zählt als Preis für die Reise. Wird ein Link mit Daten geteilt, die ins Fenster passen (jemand hat auf der Plattform gewählt, wann das Haus frei ist), gilt genau dieser Aufenthalt, ohne dass ein Zeitraum in der Reise angelegt sein muss.
- Ein anderer Aufenthalt für ein Inserat: `POST /candidates/:id/capture` mit `forTrip: true` und `startDate`, `endDate`. Die Seite dafür nennt `POST /trips/:id/check` mit `startDate`, `endDate` und optional `candidateId` (nur dieses Inserat) unter `checks[].checkUrl`. 400 `outside_window`, wenn die Daten weder im Fenster liegen noch ein Zeitraum der Reise sind.
- Im Listeneintrag steht `stays`: alle Aufenthalte, zu denen etwas bekannt ist, je `{ startDate, endDate, nights, totalCents, perNightCents, available, checkedAt, best }`. `best` ist der buchbare Aufenthalt mit dem niedrigsten Preis je Nacht; ihn zeigt `price` (mit seinen eigenen `startDate`, `endDate`, `nights`). `availability` ist `available`, sobald ein Aufenthalt im Fenster frei ist, und `unavailable` erst, wenn alle angesehenen belegt sind.
- Ohne eigenen Zeitraum fragt der Prüflauf der Reise nach der mittleren Dauer ab dem frühesten Anreisetag. Hat die Reise Zeiträume, bleibt der früheste der Standard; mit `dateOptionId` in der Liste gilt wie bisher nur dieser eine.
- Novasol-Links mit `start=TT-MM-JJJJ&nights=N` werden jetzt als Aufenthalt gelesen.
- `GET /trips/:id` nennt unter `trip.stayVariants` bis zu drei Aufenthalte, nach denen es sich lohnt, alle Inserate zu fragen: mittlere Dauer am Anfang des Fensters, mittlere Dauer am Ende, kürzeste Dauer in der Mitte. Je Variante ein Prüflauf mit `startDate` und `endDate`. Ohne Fenster ist die Liste leer.
- Reisen nennen neben `groupId` auch `groupName`.

### Merkliste der Gruppe

Jede Gruppe hat genau eine gemeinsame Merkliste: eine Reise mit `kind: "watchlist"` und der `groupId` der Gruppe, automatisch angelegt, alle Mitglieder sehen und pflegen sie (Rolle `member`). Sie erscheint in `GET /trips` neben der persönlichen Merkliste (`kind: "watchlist"`, `groupId: null`), beide mit `groupId` und `groupName`. `GET /groups` nennt sie je Gruppe als `watchlistId`; `groups[].trips` enthält nur echte Reisen. Importieren, Verschieben (`POST /candidates/:id/move` mit ihrer Id als `tripId`), Notizen und Löschen funktionieren wie bei jeder Reise; umbenennen, Zeiträume und Einladungen gibt es für Merklisten nicht.

### Mitglieder pflegen

- Hinzufügen: `POST /groups/:id/invites`, Link weitergeben. Offene Links: `GET /groups/:id/invites` liefert `{ invites: [{ id, createdAt, expiresAt, maxUses, usedCount, createdBy }] }` (der Link selbst lässt sich nicht noch einmal anzeigen), zurücknehmen mit `DELETE /groups/:id/invites/:inviteId` (204).
- Entfernen: `DELETE /groups/:id/members/:userId`. Rolle ändern: `PATCH /groups/:id/members/:userId` mit `{ "role" }`. Gruppe umbenennen: `PATCH /groups/:id`.
- Den eigenen Anzeigenamen ändert jede Person selbst: `PATCH /me` mit `{ "name" }`, Antwort `{ user }`. Namen anderer ändert niemand.
- Hinzufügen, Entfernen, Rollen und Links sind der Verwaltung (`admin`) vorbehalten; verlassen kann jede Person die Gruppe selbst.

`PATCH /trips/:id` mit `groupId: null` (oder einer anderen Gruppe) nimmt die Mitglieder der bisherigen Gruppe aus der Reise. Es bleiben, wer die Reise organisiert, und wer den Aufruf macht. Wer zusätzlich einzeln eingeladen war und zur alten Gruppe gehört, verliert den Zugriff ebenfalls und braucht eine neue Einladung.

## Reisen aufräumen

- **Archivieren:** `PATCH /trips/:id` mit `{ "status": "archived" }`, zurückholen mit `{ "status": "planning" }` (Organisation); die Reise bekommt dabei den Status zurück, den sie vor dem Archivieren hatte. Archivierte Reisen bleiben in `GET /trips`, die App zeigt sie eingeklappt.
- **Löschen:** `DELETE /trips/:id` (nur Organisation) entfernt die Reise endgültig mit allem darin: Inserate der Reise, Stimmen, Notizen, Kasse, Buchungen, Dokumente, Listen, Plan. Antwort 204. Mit `?moveCandidatesTo=<tripId>` ziehen die Inserate vorher in eine andere Reise oder Merkliste um (als neu, ohne Stimmen; was dort schon liegt, wird nicht verdoppelt). Merklisten lassen sich nicht löschen (409 `watchlist`).
- **Eindeutige Namen:** In einer Gruppe darf es jeden Reisenamen nur einmal geben, ebenso unter den privaten Reisen einer Person; Groß- und Kleinschreibung und Leerzeichen am Rand zählen nicht, archivierte Reisen zählen mit. `POST /trips` und `PATCH /trips/:id` (Name oder Gruppe) antworten sonst mit 409 `title_taken`. Schon vorhandene Doppelte bleiben, bis eine umbenannt oder gelöscht wird.
- **Reise in eine andere Gruppe:** `PATCH /trips/:id` mit `{ "groupId" }`. Die Mitglieder der alten Gruppe gehen heraus, die der neuen kommen hinein.
- **Inserat in eine andere Reise, auch in einer anderen Gruppe:** `POST /candidates/:id/move` mit `{ "tripId" }`; Ziel kann jede Reise oder Merkliste sein, in der man Mitglied ist. 409 `already_in_trip`.

Offene Einladungen zu einer Reise (nur Organisation): `GET /trips/:id/invites` liefert `{ invites: [{ id, role, createdAt, expiresAt, maxUses, usedCount, createdBy }] }`, `DELETE /trips/:id/invites/:inviteId` (204) nimmt eine zurück. Der Link selbst lässt sich nicht noch einmal anzeigen.
