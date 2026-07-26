# CI/CD einrichten — Anleitung für hades & argos

Einmalige Einrichtung. Danach deployt jeder Push automatisch, und weitere Apps
hängen sich mit wenigen Handgriffen an dieselbe Infrastruktur.

Rechne mit **1–2 Stunden** für den ersten Durchlauf.

---

## Die zwei Server und ihre Rollen

| Server | Rolle | Was neu dazukommt |
|--------|-------|-------------------|
| **hades** | Öffentlich, hat die IP hinter `musig-elgg.ch`. Apache terminiert TLS (certbot). | Pro Domain ein schlanker VirtualHost, der alles an argos weiterreicht |
| **argos** | Intern, nicht von aussen erreichbar. Hier laufen die Docker-Container. | Docker, Edge-Router (Caddy), App-Verzeichnisse |

```
Internet
   │  443 (TLS)
   ▼
hades ── Apache: TLS + eine Regel pro Domain ──┐
   │                                            │ http, Host-Header bleibt erhalten
   │  ssh (Deploy)                              ▼
   │                                     argos:8080  Caddy (Edge-Router)
   │                                            │  routet nach Domain + Pfad
   ├── self-hosted GitHub-Runner ───ssh───▶     ├── musig-elgg PRODUCTION
   │                                            └── musig-elgg STAGING
   ▲
   └─ meldet sich AUSGEHEND bei GitHub – GitHub braucht keinen Zugang nach innen
```

**Warum der Runner auf hades läuft:** GitHub kann argos nicht erreichen. Der Runner
fragt stattdessen von sich aus bei GitHub nach Arbeit und verbindet sich dann intern
per SSH zu argos. Der frühere Webhook-Listener wird damit überflüssig.

**Warum zusätzlich Caddy auf argos:** Heute stehen die Ports fest in der Apache-Config
(`argos:3003`, `argos:3004`, …). Jede neue App bräuchte neue Ports und neue Regeln auf
hades. Mit Caddy spricht hades **immer** `argos:8080` an, und Caddy verteilt anhand der
Domain. Neue App = ein Snippet auf argos, ein fast identischer VirtualHost auf hades.
Caddy macht dabei **kein** TLS — das bleibt bei Apache.

---

## Schritt 1 — GitHub-Organisation

Self-hosted Runner lassen sich bei persönlichen Accounts nur pro Repository
registrieren. Mit einer (kostenlosen) Organisation bedient **ein** Runner alle Apps.

1. Organisation erstellen: <https://github.com/organizations/plan> → Free
2. App-Repos dorthin übertragen: Repo → Settings → General → *Transfer ownership*
3. Dieses Repo (**`infra`**) in der Organisation anlegen und pushen. Es enthält
   den wiederverwendbaren Workflow, den Edge-Router, `bin/deploy.sh`, die
   Vorlagen und diese Doku.
4. `infra` **public** machen (Settings → General → Danger Zone). Wiederverwendbare
   Workflows aus öffentlichen Repos funktionieren ohne Zusatzkonfiguration.
   Alternativ privat lassen und unter Settings → Actions → General → *Access*
   für die Organisation freigeben.
5. In jedem App-Repo den Branch `development` anlegen:
   ```bash
   git switch -c development && git push -u origin development
   ```

> Enthält `infra` Secrets? Nein — der Workflow referenziert sie nur über
> `${{ secrets.* }}`. Die Werte liegen in den Org-Secrets und sind nie sichtbar.

Lokale Clones danach einmalig umbiegen:
```bash
git remote set-url origin git@github.com:applications-by-bretscher/musig_elgg.git
```

---

## Schritt 2 — argos vorbereiten (Docker)

Auf **argos**, als Benutzer mit sudo:

```bash
# Docker Engine + Compose-Plugin (offizielles Repo, nicht die Ubuntu-Version)
sudo apt update
sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Deploy-Benutzer darf Docker steuern (kein sudo im Deploy nötig)
sudo usermod -aG docker $USER
newgrp docker     # oder neu einloggen

docker run --rm hello-world     # Test
```

Netzwerk anlegen, über das der Edge-Router die Apps erreicht:
```bash
docker network create edge
```

---

## Schritt 3 — Edge-Router auf argos

`/srv/infra` ist ein **Klon dieses Repos**. Updates sind damit ein `git pull`,
statt Dateien von Hand zu kopieren.

```bash
sudo mkdir -p /srv/infra && sudo chown -R $USER:$USER /srv/infra
git clone https://github.com/applications-by-bretscher/infra.git /srv/infra
chmod +x /srv/infra/bin/deploy.sh
```

Danach liegt dort:

| Pfad | Zweck |
|---|---|
| `/srv/infra/compose.yaml` | geteilte Dienste: Caddy, MySQL, Adminer, Ollama, Whisper |
| `/srv/infra/caddy/Caddyfile` | Basis-Konfiguration |
| `/srv/infra/caddy/conf.d/` | Routing-Snippets der Apps (kommen aus den App-Repos, nicht versioniert) |
| `/srv/infra/bin/deploy.sh` | zentrales Deploy-Skript für **alle** Apps |
| `/srv/infra/mysql/init/` | SQL, das beim **ersten** Start der Datenbank läuft |

Konfiguration anlegen — ohne sie startet MySQL nicht:
```bash
cp /srv/infra/.env.example /srv/infra/.env
nano /srv/infra/.env        # MYSQL_ROOT_PASSWORD setzen: openssl rand -base64 24
```

Starten und prüfen:
```bash
docker compose -f /srv/infra/compose.yaml up -d
docker compose -f /srv/infra/compose.yaml ps
```

Der erste Start baut Whisper und lädt ~3 GB Modelldaten — das dauert einige
Minuten. Fortschritt: `docker compose -f /srv/infra/compose.yaml logs -f whisper`

```bash
# Erwartung: 404 mit Hinweistext (es läuft ja noch keine App)
curl -i -H "Host: irgendwas.ch" http://localhost:8080/
```

> **Später aktualisieren:** `cd /srv/infra && git pull` — danach bei Änderungen am
> Caddyfile ein `docker compose -f /srv/infra/compose.yaml exec caddy caddy reload
> --config /etc/caddy/Caddyfile`. Änderungen an `bin/deploy.sh` wirken sofort beim
> nächsten Deploy, für alle Apps.

> **Firewall:** Port 8080 darf nur von hades erreichbar sein.
> ```bash
> sudo ufw allow from <IP-VON-HADES> to any port 8080 proto tcp
> ```

---

## Schritt 4 — Datenbanken

Die Datenbanken liegen im zentralen MySQL aus Schritt 3. Details, Backups und
Weboberfläche: [`database.md`](database.md).

Pro App und Umgebung eine eigene Datenbank **und** einen eigenen Benutzer, der
nur auf diese eine Datenbank darf:

```bash
docker compose -f /srv/infra/compose.yaml exec mysql \
  mysql -uroot -p -e "
    CREATE DATABASE IF NOT EXISTS musig_elgg_staging
      CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER IF NOT EXISTS 'musig_elgg_staging'@'%' IDENTIFIED BY 'PASSWORT';
    GRANT ALL PRIVILEGES ON musig_elgg_staging.* TO 'musig_elgg_staging'@'%';
    FLUSH PRIVILEGES;"
```

> Kein `GRANT ALL ON *.*` — sonst könnte eine kompromittierte App die Daten
> aller anderen lesen.

**Produktion bleibt vorerst extern** und zieht später als eigener, geplanter
Schritt um (inklusive Datenmigration und Backup-Konzept). Bis dahin zeigt die
Prod-`DATABASE_URL` weiter auf den bisherigen Server.

### Weboberfläche einrichten

Adminer läuft bereits im infra-Stack. Damit er erreichbar wird:

1. `caddy/conf.d/adminer.caddy` auf die gewünschte Domain anpassen
2. Auf hades den VirtualHost aus `templates/apache-vhost-adminer.conf` anlegen —
   **mit HTTP-Basic-Auth**, siehe Kommentare in der Vorlage
3. `docker compose -f /srv/infra/compose.yaml exec caddy caddy reload --config /etc/caddy/Caddyfile`

---

## Schritt 5 — App-Verzeichnisse auf argos

```bash
sudo mkdir -p /srv/apps/musig-elgg
sudo chown -R $USER:$USER /srv/apps
cd /srv/apps/musig-elgg
mkdir -p backups

git clone -b main        git@github.com:applications-by-bretscher/musig_elgg.git production
git clone -b development git@github.com:applications-by-bretscher/musig_elgg.git staging
```

Jetzt die vier `.env`-Dateien anlegen — **einmalig, sie bleiben dauerhaft liegen**
und werden von keinem Deploy angefasst.

**`/srv/apps/musig-elgg/production/.env`**
```ini
APP_NAME=musig-elgg
DOMAIN=musig-elgg.ch
PUBLIC_API_URL=https://musig-elgg.ch/api
```

**`/srv/apps/musig-elgg/staging/.env`**
```ini
APP_NAME=musig-elgg
DOMAIN=staging.musig-elgg.ch
PUBLIC_API_URL=https://staging.musig-elgg.ch/api
```

**`production/backend/.env`** und **`staging/backend/.env`** aus
`backend/.env.example` erzeugen. Unterschiede pro Umgebung:

| Variable | production | staging |
|---|---|---|
| `DATABASE_URL` | …`/musig_elgg` | …`/musig_elgg_staging` |
| `CORS_ORIGIN` | `https://musig-elgg.ch` | `https://staging.musig-elgg.ch` |
| `FRONTEND_URL` | `https://musig-elgg.ch` | `https://staging.musig-elgg.ch` |
| `JWT_SECRET` | eigener Wert | **anderer** Wert |
| `TRUST_PROXY_HOPS` | `2` | `2` |

> **`TRUST_PROXY_HOPS=2` ist wichtig.** Vor dem Backend stehen zwei Proxies
> (Apache auf hades, Caddy auf argos). Steht hier `1`, sieht das Backend die
> Caddy-IP statt der echten Client-IP — dann greift das Rate-Limiting für alle
> Nutzer gemeinsam und Audit-Logs werden wertlos.

> **`FRONTEND_URL` nicht vergessen**, sonst enthalten Passwort-Reset-Mails
> `localhost`-Links. Das Backend warnt beim Start, wenn sie in Produktion fehlt.

---

## Schritt 6 — Runner auf hades

Auf **hades**, denn nur er erreicht GitHub. Er braucht kein Docker — nur SSH.

Token holen: Organisation → Settings → Actions → Runners → *New runner* → Linux.
Dort stehen die aktuelle Version und ein Token.

```bash
sudo useradd -m -s /bin/bash gh-runner
sudo -iu gh-runner

mkdir actions-runner && cd actions-runner
# Version/URL von der GitHub-Seite übernehmen:
curl -o runner.tar.gz -L https://github.com/actions/runner/releases/download/v2.XXX.X/actions-runner-linux-x64-2.XXX.X.tar.gz
tar xzf runner.tar.gz
./config.sh --url https://github.com/applications-by-bretscher --token <TOKEN> --labels self-hosted --unattended
exit
```

Als Dienst einrichten, damit er Neustarts überlebt:
```bash
cd /home/gh-runner/actions-runner
sudo ./svc.sh install gh-runner
sudo ./svc.sh start
sudo ./svc.sh status
```

In der Organisation unter Settings → Actions → Runners muss er jetzt als **Idle** stehen.

---

## Schritt 7 — SSH von hades nach argos

Als Runner-Benutzer auf **hades**:
```bash
sudo -iu gh-runner
ssh-keygen -t ed25519 -f ~/.ssh/id_deploy -N "" -C "gh-runner@hades"
cat ~/.ssh/id_deploy.pub
```

Den ausgegebenen Public-Key auf **argos** eintragen:
```bash
# auf argos, als Deploy-Benutzer:
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "<PUBLIC-KEY>" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Verbindung testen (bestätigt gleichzeitig den Hostkey):
```bash
# auf hades, als gh-runner:
ssh -i ~/.ssh/id_deploy jan@argos.net.letsbuild.ch 'docker ps'
```

Dann in der Organisation unter Settings → Secrets and variables → Actions anlegen:

| Secret | Inhalt |
|---|---|
| `DOCKER_HOST_SSH_KEY` | kompletter Inhalt von `~/.ssh/id_deploy` (privater Key) |
| `DOCKER_HOST` | `argos.net.letsbuild.ch` |
| `DOCKER_HOST_USER` | Deploy-Benutzer auf argos |

---

## Schritt 8 — DNS

`staging.musig-elgg.ch` auf **dieselbe** öffentliche IP wie `musig-elgg.ch` zeigen
lassen (also auf hades). Prüfen:
```bash
dig +short musig-elgg.ch staging.musig-elgg.ch
```

---

## Schritt 9 — Apache auf hades umstellen

Einmalig die nötigen Module aktivieren:
```bash
sudo a2enmod proxy proxy_http proxy_wstunnel headers rewrite ssl
```

Für **jede** Domain einen VirtualHost aus der Vorlage
`templates/apache-vhost-hades.conf` anlegen — ersetze `<DOMAIN>`,
`<ARGOS>` (`argos.net.letsbuild.ch`) und `<PORT>` (`8080`):

```bash
sudo nano /etc/apache2/sites-available/musig-elgg.conf          # DOMAIN=musig-elgg.ch
sudo nano /etc/apache2/sites-available/musig-elgg-staging.conf  # DOMAIN=staging.musig-elgg.ch
```

Zertifikat für die neue Staging-Domain holen und aktivieren:
```bash
sudo certbot --apache -d staging.musig-elgg.ch

sudo a2ensite musig-elgg.conf musig-elgg-staging.conf
sudo apache2ctl configtest
sudo systemctl reload apache2
```

> **Die alte Config aufheben, nicht löschen.** Erst wenn der neue Deploy nachweislich
> läuft, den alten VirtualHost mit den fest verdrahteten Ports (`3003`/`3004`)
> deaktivieren: `sudo a2dissite <alt>.conf && sudo systemctl reload apache2`.
> Der neue VirtualHost ersetzt ihn vollständig — die Sonderregeln für WebSockets
> und Assets übernimmt jetzt Caddy auf argos.

---

## Schritt 10 — Erster Deploy

**Immer zuerst Staging**, und den ersten Lauf von Hand, damit du die Ausgabe siehst:

```bash
# auf argos
cd /srv/apps/musig-elgg/staging
/srv/infra/bin/deploy.sh staging --dry-run    # zeigt nur, was passieren würde
/srv/infra/bin/deploy.sh staging              # echter Lauf
```

Erwartete Ausgabe: Backup geschrieben → Images gebaut → Migrationen angewendet →
Container gestartet → `Backend ist healthy` → `Interner Smoke-Test bestanden`.

Dann im Browser `https://staging.musig-elgg.ch` prüfen — inklusive Login (testet
Cookies und `X-Forwarded-Proto`) und Chat (testet die WebSocket-Kette).

Läuft das, dasselbe für Produktion:
```bash
cd /srv/apps/musig-elgg/production
/srv/infra/bin/deploy.sh production
```

Zuletzt über GitHub testen: Actions → **Deploy** → *Run workflow* → Umgebung + Branch.

---

## Schritt 11 — Den Rollback beweisen

Der wichtigste Test des ganzen Umbaus. Auf `development` absichtlich eine kaputte
Migration committen (z.B. eine Migration, die eine bereits existierende Tabelle
erneut anlegt) und deployen.

**Erwartet:** Der Deploy bricht ab, rollt automatisch zurück, der Workflow wird rot —
und `https://staging.musig-elgg.ch` **läuft unverändert weiter**.

Erst wenn das funktioniert, ist das Sicherheitsnetz bewiesen. Danach den Test-Commit
wieder entfernen.

---

## Täglicher Ablauf

| Aktion | Ergebnis |
|---|---|
| Push/Merge auf `development` | Staging wird deployt |
| Push/Merge auf `main` | Produktion wird deployt |
| Actions → Deploy → *Run workflow* | frei wählbare Umgebung + Branch |

Pro Umgebung läuft immer nur ein Deploy gleichzeitig.

---

## Was passiert, wenn etwas schiefgeht

`deploy.sh` arbeitet in dieser Reihenfolge — jeder Schritt darf gefahrlos scheitern:

1. **Code holen** – nichts läuft noch
2. **DB-Backup** → `/srv/apps/musig-elgg/backups/` (letzte 10 pro Umgebung).
   Schlägt es fehl, bricht der Deploy ab: ohne Sicherung wird nicht migriert.
3. **Images bauen** – die laufende App bleibt unberührt
4. **Migrationen** – vor dem Umschalten, solange noch die alte Version bedient
5. **Container starten**
6. **Health-Check** – Container `healthy` + interner Smoke-Test durch Caddy

Scheitert 3–6, rollt das Skript automatisch auf den letzten funktionierenden
Image-Tag zurück (`.deploy-state`) und der Workflow wird rot.

**Die Datenbank wird bewusst nicht automatisch zurückgespielt** — das würde alles
verwerfen, was seit dem Backup geschrieben wurde. Das Skript gibt stattdessen den
fertigen Restore-Befehl samt Backup-Pfad aus.

Deshalb: **Migrationen möglichst rückwärtskompatibel schreiben** (erst Spalte
hinzufügen, alte erst ein Release später entfernen). Dann ist ein Container-Rollback
immer gefahrlos.

### Nützliche Befehle auf argos
```bash
cd /srv/apps/musig-elgg/production

ENVIRONMENT=production docker compose -p musig-elgg -f compose.yaml -f compose.server.yaml ps
ENVIRONMENT=production docker compose -p musig-elgg -f compose.yaml -f compose.server.yaml logs -f backend

cat .deploy-state           # aktuell laufender Image-Tag
ls -lt ../backups/          # vorhandene Backups

# Manueller Rollback auf einen beliebigen früheren Tag:
ENVIRONMENT=production IMAGE_TAG=<tag> docker compose -p musig-elgg -f compose.yaml -f compose.server.yaml up -d --no-build

# Edge-Router
docker compose -f /srv/infra/compose.yaml logs --tail 50 caddy
docker compose -f /srv/infra/compose.yaml exec caddy caddy reload --config /etc/caddy/Caddyfile
```

---

## Weitere App anhängen

Runner, Edge-Router und Secrets bleiben unverändert. Schritt-für-Schritt:
[`new-app-guide.md`](new-app-guide.md). Kurz:

1. Vorlagen aus `templates/` ins neue Repo kopieren
2. Caddy-Snippet nach `/srv/infra/caddy/conf.d/`, Caddy neu laden
3. VirtualHost auf hades (identisch bis auf `ServerName` + Zertifikat)
4. Verzeichnisse `/srv/apps/<app>/{production,staging}` + `.env`-Dateien
5. Aufrufer-Workflow ins Repo

---

## Fehlersuche

| Symptom | Ursache / Lösung |
|---|---|
| Workflow bleibt auf „Waiting for a runner" | Runner-Dienst auf hades: `sudo ./svc.sh status` |
| `Permission denied (publickey)` | Public-Key fehlt in `~/.ssh/authorized_keys` auf argos |
| 404 „Keine App für diese Domain konfiguriert" | Caddy-Snippet fehlt oder wurde nicht neu geladen |
| 502 vom Edge-Router | Netzwerk-Alias im Snippet ≠ Alias in `compose.<env>.yaml`, oder Container läuft nicht |
| Login schlägt fehl / Redirect-Schleife | `X-Forwarded-Proto` fehlt (Apache-vhost) oder `TRUST_PROXY_HOPS` ≠ 2 |
| Rate-Limiting sperrt alle Nutzer gemeinsam | `TRUST_PROXY_HOPS` steht nicht auf `2` |
| Chat/Live-Updates funktionieren nicht | WebSocket-Regel im Apache-vhost fehlt oder steht nach den ProxyPass-Regeln |
| Frontend ruft `localhost` auf | `PUBLIC_API_URL` fehlte beim Build → Image neu bauen, nicht nur neu starten |
| „Netzwerk 'edge' fehlt" | `docker network create edge` auf argos |
| Deploy bricht bei „Backup fehlgeschlagen" ab | `DATABASE_URL` prüfen. Absicht: ohne Sicherung wird nicht migriert |
