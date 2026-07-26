# Wie das Deployment funktioniert

Hintergrundwissen zum Aufbau. Wer nur eine neue App anhängen will, braucht
[`new-app-guide.md`](new-app-guide.md); wer die Infrastruktur erstmalig aufsetzt,
[`cicd-setup.md`](cicd-setup.md).

## Das Grundproblem und seine Lösung

**argos**, der Docker-Server, ist von aussen nicht erreichbar. Nur **hades** hat eine
öffentliche IP; er terminiert TLS mit Apache und reicht den Verkehr intern weiter.
Ein GitHub-Cloud-Runner kann argos also nicht erreichen.

Die Lösung dreht die Richtung um: Ein **self-hosted Runner** auf hades meldet sich von
sich aus bei GitHub (ausgehendes HTTPS) und fragt nach Arbeit. GitHub braucht damit
überhaupt keinen Zugang nach innen. Ein selbstgebauter Webhook-Listener wird
überflüssig — inklusive seiner Fehlerquellen (abgestürzter Dienst, Signaturprüfung,
fehlende Logs, kein Statusfeedback).

```
Internet
   │  443 (TLS)
   ▼
hades ── Apache: TLS + eine Regel pro Domain ──┐
   │                                            │ http, Host-Header bleibt erhalten
   │  ssh (Deploy)                              ▼
   │                                     argos:8080  Caddy (Edge-Router, KEIN TLS)
   │                                            │
   ├── self-hosted Runner ──────ssh──────▶      ├── /srv/apps/<app>/production
   │                                            ├── /srv/apps/<app>/staging
   ▲                                            └── /srv/apps/<app>/backups
   └─ meldet sich AUSGEHEND bei GitHub
```

## Warum zusätzlich Caddy auf argos

Vorher standen die Ports fest in der Apache-Config (`argos:3003` fürs Frontend,
`argos:3004` fürs Backend, dazu Sonderregeln für WebSockets und einzelne Assets).
Jede neue App hätte neue Ports und neue Regeln auf hades gebraucht — Portbuchhaltung
von Hand, verteilt über zwei Server.

Mit dem Edge-Router spricht hades **immer** `argos:8080` an. Caddy entscheidet anhand
des Host-Headers (den Apache mit `ProxyPreserveHost On` unverändert durchreicht),
welche App und welche Umgebung gemeint ist, und trennt `/api` vom Rest.

Der Gewinn: Der VirtualHost auf hades ist für jede App identisch bis auf `ServerName`
und Zertifikat. Und die app-spezifische Routing-Logik liegt versioniert im App-Repo
statt handgepflegt auf einem Server.

**Caddy macht bewusst kein TLS.** Das erledigt Apache auf hades. Deshalb beginnen alle
Snippets mit `http://` — sonst würde Caddy versuchen, selbst ein Zertifikat zu holen,
was nie funktionieren kann (Port 80 aus dem Internet erreicht argos nicht direkt).

## Aufgabenteilung

| Ebene | Zuständig für | Warum dort |
|-------|---------------|------------|
| App-Workflow (`.github/workflows/deploy.yml`) | *Was* wird wohin deployt | Pro Repo unterschiedlich, ~15 Zeilen |
| Zentraler Workflow (`applications-by-bretscher/infra`) | SSH-Verbindung zum Server | Einmal gepflegt, gilt für alle Apps |
| `deploy.sh` (auf dem Server) | Die gesamte Deploy-Logik | Auch ohne GitHub von Hand ausführbar |

Der Workflow ist bewusst „dumm": er startet nur `deploy.sh`. Das ist der wichtigste
Design-Entscheid — fällt GitHub aus oder streikt der Runner, kannst du dich auf den
Server verbinden und exakt denselben Deploy von Hand auslösen.

## Wie Caddy die richtige App findet

Jede App/Umgebung tritt dem Docker-Netzwerk `edge` bei und bekommt dort einen
**eindeutigen Alias**: `<app>-<env>-backend` bzw. `-frontend`. Genau diesen Namen
spricht das Caddy-Snippet als Upstream an.

> Die Aliase müssen eindeutig sein. Hiessen zwei Stacks auf dem `edge`-Netz beide
> `backend`, wäre nicht vorhersagbar, wen Caddy erreicht. Ein 502 vom Edge-Router
> bedeutet fast immer: Alias im Snippet ≠ Alias in `compose.<env>.yaml`.

Für Domains ohne Snippet gibt es einen Auffangblock, der **404** liefert. Ohne ihn
würde Caddy eine leere `200` zurückgeben — das sieht wie Erfolg aus und würde ein
fehlendes Snippet verschleiern (auch gegenüber dem Smoke-Test im Deploy).

## Zwei Proxies: Folgen für die Client-IP

Vor dem Backend stehen jetzt zwei Reverse-Proxies (Apache, dann Caddy). Express muss
das wissen, sonst hält es die Caddy-IP für die Client-IP:

```js
app.set('trust proxy', Number(process.env.TRUST_PROXY_HOPS || 1));
```

Auf dem Server gehört also `TRUST_PROXY_HOPS=2` in die `010_backend/.env`. Steht dort
`1`, sehen Rate-Limiting, Audit-Logs und Geo-Analytics für **alle** Nutzer dieselbe
IP — das Rate-Limit würde dann faktisch alle gemeinsam sperren. Ein zu hoher Wert ist
umgekehrt auch falsch: dann liesse sich die IP vom Client fälschen.

Aus demselben Grund setzt jedes Caddy-Snippet `header_up X-Forwarded-Proto https`.
Caddy empfängt von Apache nur HTTP und würde sonst „http" ans Backend melden — mit der
Folge, dass Secure-Cookies nicht gesetzt werden und Redirect-Schleifen entstehen.

## Ablauf eines Deploys

`deploy.sh <production|staging> [ref]` — die Reihenfolge ist der eigentliche Schutz:

| # | Schritt | Warum an dieser Stelle |
|---|---------|------------------------|
| 1 | Code auschecken | Noch läuft alles unverändert weiter |
| 2 | **DB-Backup** | Vor jeder Migration. Schlägt es fehl, bricht der Deploy ab — ohne Sicherung wird nicht migriert |
| 3 | **Images bauen** | Vor dem Stoppen: ein Build-Fehler lässt die laufende Version völlig unberührt |
| 4 | **Migrationen** | Explizit vor dem Umschalten, damit Fehler auffallen, solange noch die alte Version bedient |
| 5 | Container starten | Erst jetzt wird umgeschaltet |
| 6 | **Health-Check** | Container `healthy` (Healthcheck aus `compose.yaml`) **und** `https://<domain>/` liefert 200 |

Scheitert einer der Schritte 3–6, rollt das Skript automatisch auf den letzten
funktionierenden Image-Tag zurück. Dieser steht in `.deploy-state` und wird erst
nach einem erfolgreichen Health-Check aktualisiert — der gespeicherte Tag ist also
immer eine nachweislich funktionierende Version.

Deshalb tragen die Images den Commit-SHA als Tag: Ein Rollback muss nichts neu bauen
(was selbst fehlschlagen könnte), sondern startet das vorherige Image direkt.

## Was der Rollback *nicht* tut

**Die Datenbank wird nicht automatisch zurückgespielt.** Das wäre gefährlicher als das
Problem: Ein Restore verwirft alles, was seit dem Backup geschrieben wurde — bei einem
Deploy um 20 Uhr also womöglich einen ganzen Abend voller Anmeldungen.

Container-Rollback ist sicher und passiert automatisch. Beim DB-Restore gibt das Skript
den fertigen Befehl samt Backup-Pfad aus und überlässt die Entscheidung dir.

Daraus folgt die wichtigste Gewohnheit: **Migrationen rückwärtskompatibel schreiben.**

```
Release 1:  Spalte hinzufügen, Code schreibt alt UND neu
Release 2:  Code liest nur noch neu
Release 3:  alte Spalte entfernen
```

So läuft die alte Version nach einem Rollback problemlos mit dem neuen Schema weiter —
und der DB-Restore wird zum Notfallwerkzeug statt zum Regelfall.

## Trennung von Prod und Staging

Beide laufen auf demselben Server, teilen aber nichts ausser dem Edge-Proxy:

| | production | staging |
|---|---|---|
| Compose-Projekt | `<app>` | `<app>-staging` |
| Verzeichnis | `/srv/apps/<app>/production` | `/srv/apps/<app>/staging` |
| Branch | `main` | `development` |
| Datenbank | eigene | **eigene** |
| Volumes | eigene | eigene |
| Domain | `<app>.ch` | `staging.<app>.ch` |

Unterschiedliche Compose-Projektnamen sorgen dafür, dass Docker die Stacks komplett
getrennt hält — auch die Volumes. Ein `down -v` auf Staging kann Prod nicht anfassen.

## Konfiguration: was wo hingehört

| Datei | Inhalt | Im Git? |
|-------|--------|---------|
| `.env` | `APP_NAME`, `DOMAIN`, `PUBLIC_API_URL` | nein (nur `.env.example`) |
| `010_backend/.env` | Secrets, `DATABASE_URL` | nein |
| `.deploy-state` | letzter erfolgreicher Image-Tag | nein |
| `compose*.yaml`, `deploy.sh` | Ablauf und Struktur | ja |

Die `.env`-Dateien liegen dauerhaft auf dem Server und werden vom Deploy nicht
angefasst — ein `git reset` kann keine Zugangsdaten löschen.

> `PUBLIC_API_URL` wird zur **Build-Zeit** ins Frontend-Bundle gebacken. Deshalb hat
> Staging ein eigenes Image: dieselben Quellen, andere eingebackene API-URL.

## Grenzen

- **Kein Zero-Downtime.** Beim Umschalten gibt es ein paar Sekunden Unterbrechung.
  Für diesen Anwendungsfall bewusst akzeptiert; Blue-Green wäre deutlich aufwändiger.
- **Ein Server.** Fällt er aus, hilft kein Rollback. Backups liegen auf demselben
  Rechner — für echten Datenschutz gehören sie zusätzlich woanders hin.
- **Migrationen sind der Risikofaktor.** Alles andere ist reversibel.
