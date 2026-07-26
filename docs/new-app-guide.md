# Neue App ans CI/CD anhängen

Schritt-für-Schritt. Rechne mit **20–30 Minuten** beim ersten Mal, danach ~10.

Voraussetzung: Die gemeinsame Infrastruktur steht bereits (Organisation, Runner auf
hades, Edge-Router auf argos, `edge`-Netzwerk). Falls nicht →
[`cicd-setup.md`](cicd-setup.md). Hintergrund zum Aufbau →
[`deployment-architecture.md`](deployment-architecture.md).

Zur Erinnerung, wer was macht:
**hades** = öffentlich, Apache + TLS, Runner · **argos** = intern, Docker + Caddy.

---

## Checkliste

- [ ] 1. App erfüllt die Konventionen
- [ ] 2. Dateien aus den Vorlagen kopieren und anpassen
- [ ] 3. DNS-Einträge setzen
- [ ] 4. Datenbanken anlegen
- [ ] 5. Verzeichnisse und `.env` auf argos
- [ ] 6. Caddy-Snippets auf argos aktivieren
- [ ] 7. Apache-VirtualHosts auf hades anlegen
- [ ] 8. Staging von Hand deployen
- [ ] 9. Über GitHub testen, dann Produktion

---

## 1. Konventionen prüfen

Die Vorlagen passen ohne Umbau, wenn die App das erfüllt:

| Anforderung | Warum |
|---|---|
| `compose.yaml` mit `backend`- und `frontend`-Service | Vorlagen greifen diese Namen auf |
| **Healthcheck auf dem `backend`-Service** | Ohne ihn kann der Deploy nicht erkennen, ob eine neue Version gesund ist → kein Rollback-Schutz |
| Mehrstufiges Dockerfile mit `runtime`-Target | Prod baut gezielt dieses Target |
| Idempotenter Migrationsbefehl | Wird bei jedem Deploy ausgeführt |
| Frontend liest API-URL aus einer Build-Variable | Staging und Prod brauchen unterschiedliche URLs |

Beispiel für den Healthcheck (in `compose.yaml`):
```yaml
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:3004/health"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 20s
```

> Ohne Healthcheck läuft der Deploy zwar, merkt aber nicht, wenn die neue Version
> beim Start abstürzt. Das ist genau der Fall, gegen den das ganze Setup schützen soll.

Weicht die App ab (kein Frontend, anderes Migrations-Tool), sind nur die betroffenen
Stellen anzupassen — die Mechanik bleibt.

---

## 2. Dateien kopieren

Aus `templates/` dieses Repos:

| Von | Nach | Anpassen |
|---|---|---|
| `compose.server.yaml` | `compose.server.yaml` | `<INTERNAL_NETWORK>`, ggf. Volumes |
| `env.example` | `.env.example` | `APP_NAME`, Domains |
| `github-workflow-deploy.yml` | `.github/workflows/deploy.yml` | nur `app:` |
| `caddy-snippet.caddy` | `deployment/caddy/<app>.production.caddy` | Domain, `<APP_NAME>`, `<ENV>` |
| `caddy-snippet.caddy` | `deployment/caddy/<app>.staging.caddy` | dito, mit `staging.` |
| `apache-vhost-hades.conf` | später direkt auf hades (Schritt 7) | `<DOMAIN>`, `<ARGOS>`, `<PORT>` |

> **`deploy.sh` wird nicht kopiert.** Es liegt zentral unter
> `/srv/infra/bin/deploy.sh` und bedient alle Apps. Verbesserungen daran wirken
> damit sofort überall — es gibt keine Kopien, die auseinanderdriften.

Laufzeit-Datei ignorieren:
```bash
echo ".deploy-state" >> .gitignore
```

Branch `development` anlegen, falls noch nicht vorhanden:
```bash
git switch -c development && git push -u origin development
```

> **`APP_NAME` ist der rote Faden.** Derselbe Wert steht in der `.env`, im Workflow
> (`app:`), im Serververzeichnis `/srv/apps/<APP_NAME>/` und in den Caddy-Aliasen.
> Weicht einer davon ab, findet Caddy den Container nicht (502).

---

## 3. DNS

Beide Domains auf die öffentliche IP von **hades** zeigen lassen:

```
meine-app.ch            A    <öffentliche IP von hades>
staging.meine-app.ch    A    <öffentliche IP von hades>
```

Vor dem ersten Deploy prüfen — Caddy stellt sonst kein Zertifikat aus:
```bash
dig +short meine-app.ch staging.meine-app.ch
```

---

## 4. Datenbanken

Zwei getrennte Datenbanken. Staging darf **nie** auf die Prod-Daten zeigen.

```sql
CREATE DATABASE meine_app          CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE meine_app_staging  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
```

---

## 5. Verzeichnisse und `.env` auf argos

Auf **argos**:

```bash
sudo mkdir -p /srv/apps/meine-app/backups
cd /srv/apps/meine-app

git clone -b main        git@github.com:applications-by-bretscher/meine-app.git production
git clone -b development git@github.com:applications-by-bretscher/meine-app.git staging
```

Dann die vier `.env`-Dateien anlegen (gitignored, bleiben dauerhaft liegen):

**`production/.env`**
```ini
APP_NAME=meine-app
DOMAIN=meine-app.ch
PUBLIC_API_URL=https://meine-app.ch/api
```

**`staging/.env`**
```ini
APP_NAME=meine-app
DOMAIN=staging.meine-app.ch
PUBLIC_API_URL=https://staging.meine-app.ch/api
```

**`production/backend/.env`** und **`staging/backend/.env`** aus der
`.env.example` der App erzeugen. Pro Umgebung unterschiedlich:

| Variable | production | staging |
|---|---|---|
| `DATABASE_URL` | `…/meine_app` | `…/meine_app_staging` |
| `CORS_ORIGIN` | `https://meine-app.ch` | `https://staging.meine-app.ch` |
| `FRONTEND_URL` | `https://meine-app.ch` | `https://staging.meine-app.ch` |
| `JWT_SECRET` | eigener Wert | **anderer** Wert |
| `TRUST_PROXY_HOPS` | `2` | `2` |

> `FRONTEND_URL` nicht vergessen: Fehlt sie, enthalten Passwort-Reset-Mails
> `localhost`-Links. Unterschiedliche `JWT_SECRET` verhindern, dass ein
> Staging-Token in Produktion gilt.

> **`TRUST_PROXY_HOPS=2`**, weil zwei Proxies davorstehen (Apache auf hades, Caddy auf
> argos). Bei `1` sieht das Backend die Caddy-IP statt der Client-IP — Rate-Limiting
> würde dann alle Nutzer gemeinsam sperren.

---

## 6. Caddy-Snippets auf argos aktivieren

```bash
sudo cp /srv/apps/meine-app/production/deployment/caddy/meine-app.production.caddy \
        /srv/infra/caddy/conf.d/
sudo cp /srv/apps/meine-app/staging/deployment/caddy/meine-app.staging.caddy \
        /srv/infra/caddy/conf.d/

# Konfiguration prüfen, bevor sie aktiv wird
docker compose -f /srv/infra/compose.yaml exec caddy \
  caddy validate --config /etc/caddy/Caddyfile

# Übernehmen (ohne Neustart, ohne Downtime für andere Apps)
docker compose -f /srv/infra/compose.yaml exec caddy \
  caddy reload --config /etc/caddy/Caddyfile
```

Direkt prüfen, ob Caddy die Domain kennt (404 = Snippet fehlt oder nicht geladen):
```bash
curl -i -H "Host: meine-app.ch" http://localhost:8080/
```
Ein **502** ist an dieser Stelle richtig — die App-Container laufen ja noch nicht.

---

## 7. Apache-VirtualHosts auf hades

Aus `templates/apache-vhost-hades.conf`, einmal pro Domain. Ersetze
`<DOMAIN>`, `<ARGOS>` (z.B. `argos.net.letsbuild.ch`) und `<PORT>` (`8080`):

```bash
# auf hades
sudo nano /etc/apache2/sites-available/meine-app.conf
sudo nano /etc/apache2/sites-available/meine-app-staging.conf

# Zertifikate holen
sudo certbot --apache -d meine-app.ch
sudo certbot --apache -d staging.meine-app.ch

sudo a2ensite meine-app.conf meine-app-staging.conf
sudo apache2ctl configtest
sudo systemctl reload apache2
```

Die VirtualHosts sind für jede App identisch bis auf `ServerName` und Zertifikatspfad —
die App-spezifische Verteilung macht Caddy auf argos.

---

## 8. Staging von Hand deployen

Der erste Lauf immer manuell — so siehst du die Ausgabe direkt:

```bash
cd /srv/apps/meine-app/staging
/srv/infra/bin/deploy.sh staging --dry-run   # zeigt nur, was passieren würde
/srv/infra/bin/deploy.sh staging             # echter Lauf
```

Was du sehen solltest: Backup geschrieben → Images gebaut → Migrationen angewendet →
Container gestartet → `Backend ist healthy` → `Interner Smoke-Test bestanden`.

Dann im Browser `https://staging.meine-app.ch` prüfen — inklusive **Login** (testet
Cookies und `X-Forwarded-Proto`) und, falls vorhanden, einer Live-Funktion (testet
die WebSocket-Kette durch beide Proxies).

Danach dasselbe für Produktion:
```bash
cd /srv/apps/meine-app/production
/srv/infra/bin/deploy.sh production
```

---

## 9. Über GitHub testen

GitHub → Actions → **Deploy** → *Run workflow* → Umgebung + Branch wählen.

Läuft das durch, ist der Automatik-Betrieb aktiv:

| Aktion | Ergebnis |
|---|---|
| Push/Merge auf `development` | Staging |
| Push/Merge auf `main` | Produktion |
| *Run workflow* | frei wählbare Umgebung + Branch |

**Empfohlener Abschlusstest:** Deploye auf Staging absichtlich eine kaputte
Migration. Der Deploy muss fehlschlagen, automatisch zurückrollen — und die alte
Version muss weiterlaufen. Erst wenn das klappt, ist das Sicherheitsnetz bewiesen.

---

## Häufige Stolpersteine

| Symptom | Ursache |
|---|---|
| 404 „Keine App für diese Domain konfiguriert" | Caddy-Snippet fehlt in `/srv/infra/caddy/conf.d/` oder wurde nicht neu geladen |
| 502 vom Edge-Router | Alias in `compose.<env>.yaml` ≠ Upstream im Snippet, oder Container läuft nicht |
| Kein TLS-Zertifikat | DNS zeigt nicht auf hades, oder Port 80 erreicht hades nicht |
| Login schlägt fehl / Redirect-Schleife | `X-Forwarded-Proto` fehlt (Apache-vhost oder Caddy-Snippet) |
| Rate-Limiting sperrt alle Nutzer gemeinsam | `TRUST_PROXY_HOPS` steht nicht auf `2` |
| WebSockets/Live-Updates tot | WebSocket-`RewriteRule` im Apache-vhost fehlt oder steht **nach** den ProxyPass-Regeln |
| Frontend ruft `localhost` auf | `PUBLIC_API_URL` fehlte beim Build – Image neu bauen, nicht nur neu starten |
| „Netzwerk 'edge' fehlt" | `docker network create edge` auf argos |
| Deploy bricht bei „Backup fehlgeschlagen" ab | `DATABASE_URL` falsch oder DB nicht erreichbar. Absicht: ohne Sicherung wird nicht migriert |
| Workflow wartet ewig | Runner-Dienst auf hades prüfen: `sudo ./svc.sh status` |
| Staging schreibt in Prod-Daten | `DATABASE_URL` in `staging/backend/.env` prüfen — **sofort stoppen** |
