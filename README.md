# Travel Planner

Ferienhaus-Planer für Familie und Freunde: Angebote von beliebigen Plattformen per Link sammeln, in einen einheitlichen Steckbrief übersetzen, vergleichen und gemeinsam abstimmen. Für iPhone und iPad, mit eigenem Server.

- **Konzept:** [docs/Konzept.md](docs/Konzept.md)
- **Schnittstelle:** [docs/API.md](docs/API.md)

## Aufbau

| Ordner | Inhalt | Stand |
|---|---|---|
| `backend/` | API in TypeScript (Fastify), PostgreSQL über Drizzle, Import-Pipeline | lauffähig, getestet |
| `ios/` | Native App in Swift und SwiftUI | noch nicht begonnen |
| `docs/` | Konzept und Schnittstellenbeschreibung | |
| `docker-compose.yml` | Stack aus API und Datenbank für den Server | |

## Backend lokal starten

Voraussetzungen: Node.js 22 oder neuer und eine PostgreSQL-Datenbank.

```bash
cd backend
npm ci
export DATABASE_URL=postgres://travel:travel@localhost:5432/travel
export BOOTSTRAP_SECRET=ein-langes-zufaelliges-geheimnis
npm run dev
```

Beim Start werden die Datenbanktabellen automatisch angelegt und aktualisiert.

Ohne `ANTHROPIC_API_KEY` läuft der Import ohne KI: Übernommen wird dann nur, was die Seite strukturiert liefert. Mit Schlüssel übersetzt ein Sprachmodell zusätzlich den sichtbaren Text in den Steckbrief.

## Tests

```bash
cd backend
npm run typecheck
npm test
```

Die Tests brauchen keine Datenbank und kein Netz. Sie laufen gegen eine PostgreSQL-Engine im Prozess (PGlite) mit denselben Migrationen wie im Betrieb.

## Auf dem Server betreiben

```bash
cp .env.example .env    # ausfüllen
docker compose up -d --build
```

Die API lauscht nur auf `127.0.0.1:3000`. Nach außen wird sie über Tailscale Funnel oder einen Reverse Proxy veröffentlicht, siehe Konzept Abschnitt 8.3. Die Datenbank ist von außen nicht erreichbar.

**Erstes Konto anlegen:** einmalig mit dem Geheimnis aus `.env`. Danach `BOOTSTRAP_SECRET` leeren und den Stack neu starten. Alle weiteren Personen kommen per Einladungslink dazu.

```bash
curl -X POST https://<adresse>/auth/bootstrap \
  -H 'content-type: application/json' \
  -d '{"secret":"<BOOTSTRAP_SECRET>","name":"Kristian"}'
```

## Datenbank ändern

Das Schema steht in `backend/src/db/schema.ts`. Nach einer Änderung erzeugt `npm run db:generate` eine neue Migration unter `backend/drizzle/`, die beim nächsten Start eingespielt wird.
