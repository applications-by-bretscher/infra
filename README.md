# infra

Gemeinsame Deployment-Plattform für alle Apps der Organisation.
Hier liegt alles, was **nicht** zu einer einzelnen App gehört.

---

## Aufbau

```
Internet
   │  443 (TLS)
   ▼
hades ── Apache: TLS + eine Regel pro Domain ──┐
   │                                            │ http, Host-Header bleibt erhalten
   │  ssh (Deploy)                              ▼
   │                                     argos:8080  Caddy (Edge-Router)
   │                                            │  verteilt nach Domain + Pfad
   ├── self-hosted GitHub-Runner ───ssh───▶     ├── app-a production / staging
   │                                            └── app-b production / staging
   ▲
   └─ meldet sich AUSGEHEND bei GitHub – GitHub braucht keinen Zugang nach innen
```

| Server | Rolle |
|---|---|
| **hades** | öffentlich, Apache terminiert TLS, betreibt den GitHub-Runner |
| **argos** | intern, hier laufen Docker-Container und der Edge-Router |

Ausführlich: [`docs/deployment-architecture.md`](docs/deployment-architecture.md)

---

## Inhalt

| Pfad | Zweck |
|---|---|
| `compose.yaml` | Edge-Router (Caddy) — läuft einmal pro Docker-Server |
| `caddy/Caddyfile` | Basis-Konfiguration, lädt `conf.d/*.caddy` |
| `caddy/conf.d/` | Routing-Snippets der Apps (kommen aus den App-Repos, nicht versioniert) |
| `bin/deploy.sh` | **zentrales Deploy-Skript für alle Apps** — Backup, Migration, Health-Check, Rollback |
| `.github/workflows/docker-deploy.yml` | wiederverwendbarer Workflow, den die App-Repos aufrufen |
| `templates/` | Kopiervorlagen für neue Apps |
| `docs/` | Setup, Architektur, Anleitung für neue Apps |

---

## Auf dem Server

`/srv/infra` ist ein Klon dieses Repos:

```bash
git clone https://github.com/applications-by-bretscher/infra.git /srv/infra
chmod +x /srv/infra/bin/deploy.sh
docker network create edge
docker compose -f /srv/infra/compose.yaml up -d
```

Aktualisieren:

```bash
cd /srv/infra && git pull
```

Änderungen an `bin/deploy.sh` wirken sofort beim nächsten Deploy — für alle Apps.
Nach Änderungen am `Caddyfile` oder an Snippets:

```bash
docker compose -f /srv/infra/compose.yaml exec caddy caddy reload --config /etc/caddy/Caddyfile
```

---

## Neue App anschliessen

Runner, Edge-Router und Secrets bleiben unverändert. Schritt für Schritt:
[`docs/new-app-guide.md`](docs/new-app-guide.md)

Kurz:
1. Vorlagen aus `templates/` ins App-Repo kopieren
2. Caddy-Snippet nach `/srv/infra/caddy/conf.d/`, Caddy neu laden
3. Apache-VirtualHost auf hades (identisch bis auf `ServerName` + Zertifikat)
4. `/srv/apps/<app>/{production,staging}` anlegen, `.env`-Dateien befüllen
5. Aufrufer-Workflow ins App-Repo

---

## Wichtige Konventionen

- **Keine App veröffentlicht Host-Ports.** Container hängen im Netzwerk `edge`
  und werden über ihren Alias `<app>-<env>-backend|frontend` erreicht. Dadurch
  gibt es unabhängig von der App-Zahl genau einen Host-Port: 8080.
- **Caddy macht kein TLS.** Das erledigt Apache auf hades. Alle Snippets
  beginnen deshalb mit `http://`.
- **`TRUST_PROXY_HOPS=2`** in jeder App — vor dem Backend stehen zwei Proxies.
  Sonst sieht die App die Proxy-IP statt der Client-IP (Rate-Limiting, Logs).
- **Migrationen rückwärtskompatibel schreiben**, damit ein Container-Rollback
  ohne DB-Restore sicher bleibt.

---

## Setup von Grund auf

[`docs/cicd-setup.md`](docs/cicd-setup.md)
