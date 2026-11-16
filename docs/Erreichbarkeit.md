# Erreichbarkeit von außen: Vorbereitung

Stand 16.11.2026. Der Server ist heute nur im Tailnet erreichbar (`tailscale serve`). Dieses Blatt beschreibt, was vor dem Öffnen erledigt sein muss und wie das Öffnen und das Zurücknehmen ablaufen. Eingeschaltet wird erst auf ausdrückliche Ansage.

## Was schon passt

- Jede Anfrage außer `/health`, dem ersten Einrichten und dem Einlösen einer Einladung braucht eine Anmeldung. Reisen sind nur für ihre Mitglieder sichtbar; eine fremde Reise sieht aus wie eine, die es nicht gibt.
- Neue Konten entstehen nur über Einladungen mit Ablaufdatum und begrenzter Nutzung. Das erste Einrichten ist verbraucht, sobald es ein Konto gibt.
- Anmelde-Token und Einladungs-Token liegen nur als Prüfsumme in der Datenbank und stehen nicht mehr im Protokoll.
- Begrenzung der Anfragen: 300 je Minute und Adresse, 10 je Minute für Einrichten und Einladungen.
- Die API lauscht in der VM nur lokal; nach außen geht ausschließlich der Tunnel. Am Windows-Host wird kein Port geöffnet.
- Abrufe fremder Seiten prüfen die Zieladresse und folgen keinen Weiterleitungen ins interne Netz.

## Was vorher erledigt sein muss

| Punkt | Stand | Wer |
|---|---|---|
| Kopie der Datenbanksicherung außer Haus (Storage Box) | Skript fertig, Schlüssel erzeugt, wartet auf Zugang | Kristian, dann Claude |
| SSH-Passwort der VM ändern, falls noch nicht geschehen | offen | Kristian |
| `BOOTSTRAP_SECRET` aus der `.env` entfernen (wird nicht mehr gebraucht) | offen | Kristian (tippt selbst) |
| Tageslimit für KI-Aufrufe je Konto (Import, Suche), damit ein gekapertes Konto kein Guthaben verbrennt | erledigt: 400 Auswertungen und 30 Suchen je Person und Tag (`DAILY_READINGS`, `DAILY_SEARCHES`), danach 429 `daily_limit` | Claude |
| Ausgabenlimit im Anthropic-Konto setzen | offen | Kristian |
| Sitzungen einsehen und einzeln abmelden (Gerät verloren) | Abmelden gibt es, Übersicht fehlt in der App | Claude, App |
| "Mit Apple anmelden", damit ein Konto nicht an einem Gerät hängt | offen, braucht Developer-Mitgliedschaft | Claude, App |
| Alte Protokollsicherungen mit dem eingelösten Einladungs-Token löschen | offen | Claude auf Ansage |

Die ersten fünf Punkte sind Pflicht. Die übrigen sind dringend empfohlen, aber kein Hindernis für einen Test mit der Familie.

## Öffnen, Stufe 1: Tailscale Funnel

Ein Befehl in der VM, den Kristian selbst ausführt oder ausdrücklich freigibt:

```
sudo tailscale funnel --bg 3000
```

Die Adresse bleibt `https://reisen.tail39c0d8.ts.net`, also ändert sich in der App nichts. Funnel muss im Tailscale-Adminbereich für das Tailnet erlaubt sein (Access Controls, Attribut `funnel`).

Danach prüfen: `/health` von einem Gerät ohne Tailscale, Anmeldung in der App über Mobilfunk, ein Import.

## Zurücknehmen

```
sudo tailscale funnel --https=443 off
sudo tailscale serve --bg 3000
```

Damit ist der Server wieder nur im Tailnet erreichbar. Daten gehen dabei nicht verloren.

## Stufe 2, nur bei Bedarf

Eigene Adresse `reisen.von-bleichert.com` mit zusätzlicher Hetzner-IP und Caddy vor der VM. Lohnt erst, wenn Funnel zu langsam ist oder die Adresse Gästen ohne App gezeigt werden soll (Gäste-Web).

## Beobachten nach dem Öffnen

- Tägliche Zeile im `backup.log` (lokal und außer Haus).
- Antworten mit 401, 403 und 429 im API-Protokoll: einzelne sind normal, Häufungen von einer Adresse nicht.
- Verbrauch im Anthropic-Konto.
