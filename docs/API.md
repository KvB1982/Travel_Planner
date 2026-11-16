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

Geplant, aber noch nicht umgesetzt: „Mit Apple anmelden" und die Anmeldung per E-Mail-Link für das Web.

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
