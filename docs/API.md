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
| PATCH | `/candidates/:id/profile` | Steckbrief von Hand korrigieren. Nur die geänderten Felder senden. |
| POST | `/candidates/:id/capture` | Auf dem Gerät ausgelesenen Seiteninhalt nachreichen: `html`. |
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
