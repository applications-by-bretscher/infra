# Bestehende App auf die Plattform umziehen

Anleitung für Apps, die heute **roh auf dem Server** laufen (systemd-Dienst, `npm
start`, PM2, eigener Port in der Apache-Config) und in die containerisierte
Plattform überführt werden sollen.

Wer eine **neue** App anlegt, braucht [`new-app-guide.md`](new-app-guide.md) — dort
entfällt alles ab Phase 3. Wer wissen will, *warum* die Plattform so gebaut ist:
[`deployment-architecture.md`](deployment-architecture.md).

> **Jeder Befehl ist mit dem Server beschriftet, auf dem er ausgeführt wird.**
> `lokal` = Arbeitsplatz · `hades` = öffentlich, Apache + Runner · `argos` = Docker.

---

## Grundprinzip: erst danebenstellen, spät umschalten

Der Umzug ist kein Big Bang. Die neue Umgebung wird **vollständig aufgebaut und
getestet, während die alte weiterläuft**. Umgeschaltet wird ganz am Schluss mit
einer einzigen Änderung — der Apache-Config auf hades. Und genau diese eine
Änderung ist in 30 Sekunden rückgängig gemacht.

```
Phase 1–2   alte App läuft │ neue App wird daneben aufgebaut
Phase 3     alte App läuft │ neue App mit Prod-Kopie getestet
Phase 4     ── kurzes Wartungsfenster: Daten kopieren, umschalten ──
Phase 5     alte App gestoppt (nicht gelöscht!) │ neue App bedient die Nutzer
```

Nur Phase 4 ist für Nutzer spürbar — typisch 10–20 Minuten, im Wesentlichen die
Dauer des Datenbank-Dumps.

---

## Phasenübersicht

| Phase | Wo | Downtime | Ergebnis |
|---|---|---|---|
| 0 Bestandsaufnahme | argos, hades | – | Du weisst, was die App braucht |
| 1 Repo containerisieren | lokal | – | Dockerfiles, Compose, Snippets im Git |
| 2 Umgebung aufbauen | argos, hades | – | Staging läuft, Prod-Stack bereit |
| 3 Generalprobe | argos | – | Staging läuft mit Kopie der Prod-Daten |
| 4 **Umschalten** | argos, hades | **ja** | Nutzer landen auf den Containern |
| 5 Nachlauf | – | – | Beobachten, dann aufräumen |

---

# Phase 0 — Bestandsaufnahme

Bevor irgendetwas gebaut wird: herausfinden, woraus die App tatsächlich besteht.
Der häufigste Umzugsfehler ist **vergessener Zustand** — Dateien, die niemand auf
der Rechnung hatte.

### 🖥️ argos — was läuft und wo liegen die Daten?

```bash
systemctl list-units --type=service --state=running | grep -i <app>
```

```bash
systemctl cat <app>-backend.service
```

Aus der Unit-Datei ablesen: `WorkingDirectory`, `EnvironmentFile`, `ExecStart`,
unter welchem Benutzer sie läuft.

Welche Ports belegt die App heute?

```bash
sudo ss -tlnp | grep -E 'node|nginx|python'
```

**Und jetzt der wichtige Teil — welche Verzeichnisse schreibt sie?**

```bash
sudo du -sh /pfad/zur/app/* | sort -h | tail -20
```

Alles, was nicht aus dem Git-Repo stammt, ist Zustand und muss mitwandern:
Uploads, generierte Vorschaubilder, Logs, SQLite-Dateien, Session-Stores,
Zertifikate. Schreib es auf.

> **Faustregel:** Was ein `git status` im App-Verzeichnis als *untracked* zeigt
> und nicht `node_modules` heisst, ist ein Kandidat.

### 🖥️ hades — wie ist die App heute erreichbar?

```bash
sudo apache2ctl -S | grep -i <app>
```

```bash
sudo cat /etc/apache2/sites-available/<app>-le-ssl.conf
```

Notiere: **alle** `ProxyPass`-Ziele (oft mehr als zwei — WebSockets und einzelne
Assets haben gerne Sonderregeln), das Zertifikat und sämtliche `ServerAlias`.

---

# Phase 1 — Repo containerisieren

Passiert komplett **lokal**, ohne den Server zu berühren. Vorlagen liegen in
[`templates/`](../templates/).

### 🖥️ lokal

```bash
git checkout -b docker-migration
```

Zu erstellen:

| Datei | Zweck |
|---|---|
| `backend/Dockerfile` | Multi-Stage: `base` → `deps` (dev) → `build` → `runtime` |
| `backend/docker-entrypoint.sh` | wartet auf die DB, führt Migrationen aus, startet die App |
| `frontend/Dockerfile` | baut das Bundle, serviert es mit nginx |
| `frontend/nginx.conf` | SPA-Fallback auf `index.html` |
| `compose.yaml` | Basis — gilt für alle Umgebungen |
| `compose.dev.yaml` | lokal: Bind-Mounts, HMR, eigene DB, Host-Ports |
| `compose.server.yaml` | Server: `edge`-Netz, Aliase, **keine** Host-Ports |
| `deployment/caddy/*.caddy` | Routing je Umgebung |
| `.github/workflows/deploy.yml` | ~15 Zeilen, ruft den zentralen Workflow |

Drei Regeln, die auf dem Server sonst weh tun:

**Keine Host-Ports auf dem Server.** Nur der Edge-Router hat einen (8080). Der
Stack hängt am Netz `edge` mit eindeutigen Aliassen:

```yaml
networks:
  edge:
    aliases: [ "${APP_NAME}-${ENVIRONMENT}-backend" ]
```

**Image-Namen enthalten die Umgebung**, sonst überschreiben Staging und Prod
gegenseitig ihre Images:

```yaml
image: ${APP_NAME:?APP_NAME fehlt}-${ENVIRONMENT:?ENVIRONMENT fehlt}-backend:${IMAGE_TAG:-latest}
```

**Der Entrypoint gehört in die `base`-Stage**, damit der Dev-Container ihn auch
bekommt — sonst laufen lokal keine Migrationen.

Lokal testen, bis alles läuft:

```bash
docker compose -f compose.yaml -f compose.dev.yaml up --build
```

Dann pushen — `development` **und** `main` müssen den Docker-Stand enthalten,
sonst deployt Phase 2 den alten Code.

---

# Phase 2 — Umgebung auf dem Server aufbauen

Ab hier wird der Server angefasst, aber **nichts Bestehendes verändert**. Die alte
App läuft die ganze Zeit weiter.

### 🖥️ argos — Datenbank und Benutzer anlegen

```bash
openssl rand -hex 24
```

> Nicht `openssl rand -base64`. Das Passwort landet in einer URL, und `/ @ : +`
> zerlegen sie. Details in [`database.md`](database.md).

```bash
ROOT_PW=$(grep -m1 '^MYSQL_ROOT_PASSWORD=' /srv/infra/.env | cut -d= -f2- | tr -d '"')
```

```bash
docker compose -f /srv/infra/compose.yaml exec -e MYSQL_PWD="$ROOT_PW" mysql \
  mysql -uroot -e "
    CREATE DATABASE <app>_staging CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
    CREATE DATABASE <app>            CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
    CREATE USER '<app>'@'%' IDENTIFIED BY 'DAS_HEX_PASSWORT';
    GRANT ALL PRIVILEGES ON <app>.*         TO '<app>'@'%';
    GRANT ALL PRIVILEGES ON <app>_staging.* TO '<app>'@'%';
    FLUSH PRIVILEGES;"
```

> Kein `GRANT ALL ON *.*` — sonst liest eine kompromittierte App die Daten aller
> anderen Apps mit.

### 🖥️ argos — Verzeichnisse und Konfiguration

Als Benutzer `jan`, **nicht als root** (siehe Stolpersteine):

```bash
mkdir -p /srv/apps/<app>/{production,staging,backups}
```

```bash
git clone git@github-<app>:applications-by-bretscher/<app>.git /srv/apps/<app>/production
```

```bash
git clone git@github-<app>:applications-by-bretscher/<app>.git /srv/apps/<app>/staging
```

```bash
cd /srv/apps/<app>/staging && git checkout development
```

Dann je Umgebung `.env` und `backend/.env` anlegen. Die alten Werte aus der
`EnvironmentFile` der systemd-Unit übernehmen und **diese drei anpassen**:

```ini
DATABASE_URL="mysql://<app>:HEX_PASSWORT@mysql:3306/<app>_staging"
TRUST_PROXY_HOPS=2
FRONTEND_URL=https://staging.<app>.ch
```

> `TRUST_PROXY_HOPS=2`, weil jetzt zwei Proxies davorstehen. Bei `1` sehen
> Rate-Limiting und Logs für **alle** Nutzer dieselbe IP.

### 🖥️ argos — Caddy-Snippet aktivieren

```bash
cp /srv/apps/<app>/production/deployment/caddy/*.caddy /srv/infra/caddy/conf.d/
```

```bash
docker compose -f /srv/infra/compose.yaml exec caddy caddy reload --config /etc/caddy/Caddyfile
```

### 🖥️ hades — DNS und Zertifikat

Neue Subdomain für Staging, danach das Zertifikat erweitern (Details in
[`cicd-setup.md`](cicd-setup.md)).

### 🖥️ hades — VirtualHost für Staging

Neue Datei, **die produktive lässt du unangetastet**:

```bash
sudo nano /etc/apache2/sites-available/<app>-staging-le-ssl.conf
```

Vorlage: [`templates/apache-vhost-hades.conf`](../templates/apache-vhost-hades.conf).
Für jede App identisch bis auf `ServerName` und Zertifikatspfad.

```bash
sudo a2ensite <app>-staging-le-ssl && sudo apache2ctl configtest && sudo systemctl reload apache2
```

### Erster Deploy

GitHub → Actions → *Deploy* → Run workflow → `staging`. Oder direkt:

### 🖥️ argos

```bash
cd /srv/apps/<app>/staging && /srv/infra/bin/deploy.sh staging
```

Ab hier ist `https://staging.<app>.ch` erreichbar — die Produktion läuft
unverändert weiter.

---

# Phase 3 — Generalprobe mit echten Daten

Ein leeres Staging beweist wenig. Der Test, der zählt: **läuft die neue Version
mit den echten Produktionsdaten?**

### 🖥️ argos (oder wo die alte DB liegt) — Dump ziehen

```bash
mysqldump -h ALTER_DB_HOST -u BENUTZER -p --single-transaction --routines --events \
  ALTE_DB | gzip > ~/prod-kopie.sql.gz
```

### 🖥️ argos — in Staging einspielen

```bash
ROOT_PW=$(grep -m1 '^MYSQL_ROOT_PASSWORD=' /srv/infra/.env | cut -d= -f2- | tr -d '"')
```

```bash
gunzip -c ~/prod-kopie.sql.gz | docker compose -f /srv/infra/compose.yaml exec -T \
  -e MYSQL_PWD="$ROOT_PW" mysql mysql -uroot <app>_staging
```

Dann deployen und die **Migrationen** beobachten — das ist der eigentliche Test:

```bash
cd /srv/apps/<app>/staging && /srv/infra/bin/deploy.sh staging
```

Auf `https://staging.<app>.ch` durchklicken: Login, Upload, die eine komplizierte
Funktion, die immer kaputtgeht. Erst wenn das sitzt, geht es weiter.

---

# Phase 4 — Umschalten

Ab hier läuft die Uhr. Vorher einmal in Ruhe durchlesen; die Befehle so
vorbereiten, dass sie nur noch abgeschickt werden müssen.

**Reihenfolge ist wichtig:** erst Dateien (dauert am längsten, unkritisch), dann
alte Dienste stoppen, dann DB (muss frisch sein), dann umschalten.

### 1 · 🖥️ argos — Dateien migrieren *(vor dem Wartungsfenster möglich)*

Docker-Volumes starten leer. Alles aus Phase 0 muss aktiv hineinkopiert werden.

```bash
docker volume create <app>_uploads_data
```

```bash
docker run --rm -v <app>_uploads_data:/ziel -v /alter/pfad/uploads:/quelle:ro \
  alpine sh -c "cp -a /quelle/. /ziel/ && ls /ziel | head"
```

Prüfen, dass die Zahl stimmt:

```bash
docker run --rm -v <app>_uploads_data:/v alpine sh -c "find /v -type f | wc -l"
```

```bash
find /alter/pfad/uploads -type f | wc -l
```

> Diesen Schritt ruhig **einen Tag vorher** machen und im Wartungsfenster nur noch
> die Differenz nachziehen (`cp -a` erneut, überschreibt gleiche Dateien).

### 2 · 🖥️ argos — alte Dienste stoppen

**Nur stoppen, nicht `disable`.** Ab hier sind Nutzer betroffen.

```bash
sudo systemctl stop <app>-backend <app>-frontend
```

Der Stopp muss vor dem Dump passieren — sonst schreibt die alte App weiter, und
die letzten Änderungen fehlen in der neuen DB.

### 3 · 🖥️ argos — frischen Dump ziehen und einspielen

```bash
mysqldump -h ALTER_DB_HOST -u BENUTZER -p --single-transaction --routines --events \
  ALTE_DB | gzip > ~/prod-final-$(date +%Y%m%d-%H%M).sql.gz
```

```bash
ls -lh ~/prod-final-*.sql.gz
```

> Den **echten Dateinamen** aus dieser Ausgabe in den nächsten Befehl einsetzen.
> Ein Platzhalter, der versehentlich stehenbleibt, lässt den Import nach dem
> `DROP DATABASE` fehlschlagen — mit leerer Datenbank als Ergebnis.

```bash
ROOT_PW=$(grep -m1 '^MYSQL_ROOT_PASSWORD=' /srv/infra/.env | cut -d= -f2- | tr -d '"')
```

```bash
docker compose -f /srv/infra/compose.yaml exec -e MYSQL_PWD="$ROOT_PW" mysql \
  mysql -uroot -e "DROP DATABASE IF EXISTS <app>;
                   CREATE DATABASE <app> CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"
```

```bash
gunzip -c ~/prod-final-DEIN-ZEITSTEMPEL.sql.gz | docker compose -f /srv/infra/compose.yaml \
  exec -T -e MYSQL_PWD="$ROOT_PW" mysql mysql -uroot <app>
```

**Rechte nach dem `DROP` neu vergeben** — sie hingen an der gelöschten Datenbank:

```bash
docker compose -f /srv/infra/compose.yaml exec -e MYSQL_PWD="$ROOT_PW" mysql \
  mysql -uroot -e "GRANT ALL PRIVILEGES ON <app>.* TO '<app>'@'%'; FLUSH PRIVILEGES;"
```

Gegenprüfen, dass wirklich Daten da sind:

```bash
docker compose -f /srv/infra/compose.yaml exec -e MYSQL_PWD="$ROOT_PW" mysql \
  mysql -uroot -e "SELECT COUNT(*) FROM <app>.users;"
```

### 4 · 🖥️ argos — Produktions-Stack starten

```bash
cd /srv/apps/<app>/production && ENVIRONMENT=production docker compose -p <app> \
  -f compose.yaml -f compose.server.yaml up -d
```

Intern testen, **bevor** Nutzer draufgeleitet werden:

```bash
curl -i -H "Host: <app>.ch" http://localhost:8080/ | head -3
```

`200` — weiter. `404` — Caddy-Snippet fehlt. `502` — Alias stimmt nicht.

### 5 · 🖥️ hades — umschalten

Der eigentliche Moment. Erst sichern:

```bash
sudo cp /etc/apache2/sites-available/<app>-le-ssl.conf ~/<app>-le-ssl.conf.backup
```

```bash
sudo nano /etc/apache2/sites-available/<app>-le-ssl.conf
```

Alle `ProxyPass` / `ProxyPassReverse` / `RewriteRule` mit alten Ports ersetzen:

```apache
    ProxyPreserveHost On
    RequestHeader set X-Forwarded-Proto "https"

    RewriteEngine On
    RewriteCond %{HTTP:Upgrade} websocket [NC]
    RewriteCond %{HTTP:Connection} upgrade [NC]
    RewriteRule ^/?(.*) ws://argos.net.letsbuild.ch:8080/$1 [P,L]

    ProxyPass        / http://argos.net.letsbuild.ch:8080/
    ProxyPassReverse / http://argos.net.letsbuild.ch:8080/
    ProxyTimeout 300
```

> Die WebSocket-Regel muss **vor** `ProxyPass /` stehen — sonst greift die
> allgemeine Regel zuerst und das Upgrade findet nie statt.

```bash
sudo apache2ctl configtest && sudo systemctl reload apache2
```

### 6 · Verifizieren

```bash
curl -I https://<app>.ch/
```

Danach im Browser: anmelden, eine Datei öffnen, etwas hochladen, WebSocket-Funktion
(Chat/Live-Updates) prüfen.

### Rückweg — wenn etwas nicht stimmt

🖥️ hades:

```bash
sudo cp ~/<app>-le-ssl.conf.backup /etc/apache2/sites-available/<app>-le-ssl.conf && sudo systemctl reload apache2
```

🖥️ argos:

```bash
sudo systemctl start <app>-backend <app>-frontend
```

Zwei Befehle, unter einer Minute. Deshalb wird nichts gelöscht, bevor der Umzug
sich bewährt hat.

---

# Phase 5 — Nachlauf

**Mindestens 1–2 Wochen nichts löschen.** Die alte Installation kostet nur
Plattenplatz und ist der einzige Rückweg, falls sich später zeigt, dass ein Feature
Zustand an einer Stelle hatte, die in Phase 0 niemand gesehen hat.

In dieser Zeit:

```bash
docker compose -p <app> logs -f --tail=100
```

Was danach ansteht — **jeder Punkt einzeln und bewusst**:

| Aufräumen | Befehl |
|---|---|
| Alte Dienste deaktivieren | 🖥️ argos: `sudo systemctl disable <app>-backend <app>-frontend` |
| Alter Webhook-Listener | GitHub → Settings → Webhooks prüfen und entfernen |
| Alte App-Dateien | erst wenn die Volumes nachweislich vollständig sind |
| Alte Datenbank | **zuletzt**, und nur mit geprüftem Dump ausserhalb des Servers |

Und einmalig, falls noch nicht vorhanden — das tägliche DB-Backup einrichten:
[`database.md`](database.md#sicherung).

---

# Stolpersteine

Gesammelt aus tatsächlich durchgeführten Umzügen. Jeder Punkt hat mindestens
einmal Zeit gekostet.

### `$` in `.env`-Werten verschwindet

Compose interpoliert `$VAR`. Aus `SMTP_PASS=glng$AT*d7` wird `glng*d7`, und der
Mailversand scheitert mit „Authentifizierung fehlgeschlagen".

```ini
SMTP_PASS=glng$$AT*d7
```

Prüfen, was tatsächlich ankommt:

```bash
docker compose -p <app> exec backend printenv SMTP_PASS
```

### Beim DB-Import niemals `-p`

```bash
mysql -uroot -p < dump.sql    # scheitert mit "Access denied"
```

Ohne Terminal liest der Passwort-Prompt aus **stdin** — dort steht der Dump. MySQL
nimmt die erste SQL-Zeile als Passwort. Stattdessen `MYSQL_PWD` setzen, dann bleibt
stdin frei.

### Dumps ohne `CREATE DATABASE`

`mysqldump einedb` schreibt **keine** `CREATE DATABASE`/`USE`-Zeile (anders als
GUI-Exporte aus HeidiSQL). Ohne Zieldatenbank im Befehl: „No database selected".
Also vorher anlegen und den Namen mitgeben:

```bash
... | mysql -uroot <app>
```

### Nach `DROP DATABASE` sind die Rechte weg

GRANTs hängen an der Datenbank. Nach dem Neuanlegen kommt die App sonst nicht mehr
rein — `Access denied for user`. Immer neu vergeben.

### Passwörter als hex, nicht base64

`openssl rand -base64` erzeugt `+ / =`. In einer `DATABASE_URL` zerlegt das `/` die
URL, das Passwort wird abgeschnitten. `openssl rand -hex 24` verwenden.

### Als `jan` arbeiten, nicht als `root`

SSH-Aliase (`github-<app>`) stehen in `~jan/.ssh/config`. Als root kommt
`Could not resolve hostname github-<app>`. Ausserdem gehören die erzeugten Dateien
sonst root. **Docker und Deploys immer als `jan`.**

### Bind-Mount zeigt nach `rm -rf` ins Leere

Wird ein gemountetes Verzeichnis auf dem Host gelöscht und neu angelegt, hängt der
Container am alten Inode und sieht die neuen Dateien nicht:

```bash
docker compose -f /srv/infra/compose.yaml up -d --force-recreate caddy
```

### Volumes starten leer

Das ist kein Fehler, sondern der häufigste Datenverlust beim Umzug. Uploads,
generierte Dateien, Zertifikate — alles muss aktiv hineinkopiert werden (Phase 4.1).

### `PUBLIC_API_URL` wird eingebacken

`VITE_API_URL` landet zur **Build-Zeit** im Bundle. Ändern und den Container nur
neu starten reicht nicht — es braucht einen neuen Build. Deshalb hat Staging ein
eigenes Image.

Immer die volle Domain (`https://<app>.ch/api`), nie relativ `/api` — sonst greift
in der WebSocket-Verbindung ein localhost-Fallback.

### Der `development`-Branch muss aktuell sein

Der Staging-Deploy zieht `development`. Steckt der Docker-Umbau nur in einem
Feature-Branch, deployt Phase 2 fröhlich den alten Code — und der Fehler sieht aus
wie ein Container-Problem.

### Organisations-Secrets greifen nicht auf dem Free-Plan

Bei privaten Repos sind Organisations-Secrets kostenpflichtig. Deshalb kommt der
Workflow ohne Secrets aus: Der Runner auf hades nutzt seinen eigenen SSH-Key, der
ohnehin dort liegt.

### Markdown-Links in kopierten Befehlen

Beim Kopieren aus Chat-Oberflächen werden Domains gerne zu
`[www.app.ch](https://www.app.ch)`. In certbot- oder Apache-Befehlen bricht das
alles. Nach dem Einfügen kurz hinschauen.

---

# Checkliste

```
Phase 0
  [ ] systemd-Units gelesen (WorkingDirectory, EnvironmentFile, Ports)
  [ ] Datenverzeichnisse identifiziert und notiert
  [ ] Apache-VirtualHost gelesen, ALLE ProxyPass-Ziele notiert

Phase 1
  [ ] Dockerfiles + Entrypoint, lokal lauffähig
  [ ] compose.yaml / .dev.yaml / .server.yaml
  [ ] Caddy-Snippets je Umgebung
  [ ] Deploy-Workflow
  [ ] auf development UND main gepusht

Phase 2
  [ ] DBs + Benutzer angelegt (hex-Passwort, kein GRANT ON *.*)
  [ ] /srv/apps/<app>/{production,staging} geklont (als jan)
  [ ] .env + backend/.env je Umgebung (TRUST_PROXY_HOPS=2)
  [ ] Caddy-Snippet kopiert und reload
  [ ] DNS + Zertifikat für staging
  [ ] Apache-VirtualHost staging (Prod unangetastet)
  [ ] Staging-Deploy erfolgreich

Phase 3
  [ ] Prod-Kopie in Staging eingespielt
  [ ] Migrationen laufen sauber durch
  [ ] Funktionstest bestanden

Phase 4
  [ ] Dateien in Volumes migriert, Dateizahl verglichen
  [ ] alte Dienste gestoppt (NICHT disabled)
  [ ] frischer Dump gezogen, Grösse geprüft
  [ ] importiert, GRANTs erneuert, Zeilen gezählt
  [ ] Prod-Stack gestartet, curl über Host-Header = 200
  [ ] Apache-Config gesichert
  [ ] Apache umgeschaltet, configtest + reload
  [ ] Browser: Login, Upload, Datei, WebSocket

Phase 5
  [ ] 1–2 Wochen Logs beobachten
  [ ] tägliches DB-Backup eingerichtet und einmal getestet
  [ ] danach einzeln aufräumen — nichts pauschal löschen
```
