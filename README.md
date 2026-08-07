# infra

Der **ausführbare Teil** der Deployment-Plattform: Edge-Router, zentrale
Datenbank, Deploy-Skript, Vorlagen. Alles, was **nicht** zu einer einzelnen App
gehört.

> ## 📖 Die Dokumentation liegt in [`applications-by-bretscher/docs`](https://github.com/applications-by-bretscher/docs)
>
> | Ich will … | Dort |
> |---|---|
> | **eine neue App deployen** | [`04-neue-app-deployen.md`](https://github.com/applications-by-bretscher/docs/blob/main/04-neue-app-deployen.md) |
> | verstehen, wie das funktioniert | [`01-architektur.md`](https://github.com/applications-by-bretscher/docs/blob/main/01-architektur.md) |
> | wissen, welcher Branch wohin deployt | [`02-branches-und-umgebungen.md`](https://github.com/applications-by-bretscher/docs/blob/main/02-branches-und-umgebungen.md) |
> | Docker verstehen und bedienen | [`03-docker.md`](https://github.com/applications-by-bretscher/docs/blob/main/03-docker.md) |
> | deployen, Logs, Rollback | [`05-betrieb.md`](https://github.com/applications-by-bretscher/docs/blob/main/05-betrieb.md) |
> | Datenbank anlegen oder sichern | [`06-datenbank.md`](https://github.com/applications-by-bretscher/docs/blob/main/06-datenbank.md) |
> | eine App vom Blech umziehen | [`07-app-umziehen.md`](https://github.com/applications-by-bretscher/docs/blob/main/07-app-umziehen.md) |
> | die Plattform aufsetzen | [`08-plattform-aufsetzen.md`](https://github.com/applications-by-bretscher/docs/blob/main/08-plattform-aufsetzen.md) |
> | wissen, warum etwas nicht geht | [`referenz/fehlersuche.md`](https://github.com/applications-by-bretscher/docs/blob/main/referenz/fehlersuche.md) |
>
> Dieses Repo führt bewusst **keine** eigenen Erklärungen — zwei Quellen driften
> auseinander.

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

---

## Inhalt

| Pfad | Zweck |
|---|---|
| `compose.yaml` | geteilte Dienste: caddy, mysql, adminer, ollama, whisper |
| `caddy/Caddyfile` | Basis-Konfiguration, lädt `conf.d/*.caddy` |
| `caddy/conf.d/` | Routing-Snippets der Apps (kommen aus den App-Repos, nicht versioniert) |
| `bin/deploy.sh` | **zentrales Deploy-Skript für alle Apps** — Backup, Migration, Health-Check, Rollback |
| `.github/workflows/docker-deploy.yml` | wiederverwendbarer Workflow, den die App-Repos aufrufen |
| `mysql/init/` | SQL, das beim allerersten Start der Datenbank läuft |
| `templates/` | Kopiervorlagen für neue Apps |

---

## Auf dem Server

`/srv/infra` ist ein Klon dieses Repos:

```bash
git clone https://github.com/applications-by-bretscher/infra.git /srv/infra
```

```bash
chmod +x /srv/infra/bin/deploy.sh && docker network create edge && docker compose -f /srv/infra/compose.yaml up -d
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

## Stand der Migration

| App | Staging | Produktion |
|---|---|---|
| musig-elgg | ✅ | ✅ umgestellt 08/2026 — alte Dienste gestoppt, noch nicht entfernt |
| rotary | – | – |
| jan-portfolio | – | – |
