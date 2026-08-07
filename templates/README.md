# Vorlagen für neue Apps

Kopiervorlagen, damit eine neue App in wenigen Minuten am gemeinsamen CI/CD hängt.

**Schritt-für-Schritt-Anleitung:**
[`docs/04-neue-app-deployen.md`](https://github.com/applications-by-bretscher/docs/blob/main/04-neue-app-deployen.md)

## Was kopiert wird — und was angepasst werden muss

| Datei                        | Ziel                                  | Anpassen?                        |
|------------------------------|---------------------------------------|----------------------------------|
| `compose.server.yaml`        | `compose.server.yaml` im App-Repo     | nur bei anderen Services/Volumes |
| `env.example`                | `.env.example` im App-Repo            | `APP_NAME`, Domains              |
| `github-workflow-deploy.yml` | `.github/workflows/deploy.yml`        | nur `app:`                       |
| `caddy-snippet.caddy`        | `deployment/caddy/<app>.<env>.caddy` → auf **argos** nach `/srv/infra/caddy/conf.d/` | Domain, `<APP_NAME>`, `<ENV>` |
| `apache-vhost-hades.conf`    | auf **hades** nach `/etc/apache2/sites-available/` | `<DOMAIN>`, `<ARGOS>`, `<PORT>` |
| `apache-vhost-adminer.conf`  | nur EINMAL für die DB-Oberfläche auf **hades** | `<DOMAIN>`, `<ARGOS>`, `<PORT>` |

**`deploy.sh` wird bewusst nicht kopiert.** Es liegt zentral unter
`/srv/infra/bin/deploy.sh` und bedient alle Apps. Alles Projektabhängige liest es
aus der `.env` der jeweiligen Umgebung (`APP_NAME`, `DOMAIN`, `PUBLIC_API_URL`).

Das ist Absicht: Kopierte Skripte driften auseinander — ein Fehler wird in einem
Repo behoben und in den anderen vergessen.

## Voraussetzungen an die App

Damit die Vorlagen ohne Umbau passen, sollte die App diese Konventionen erfüllen:

1. **`compose.yaml`** definiert die Services (mindestens `backend`, `frontend`) und ein
   internes Netzwerk.
2. Der **`backend`-Service hat einen Healthcheck** — darauf stützt sich der Deploy,
   um zu entscheiden, ob eine neue Version gesund ist. Ohne Healthcheck kein Rollback-Schutz.
3. Ein **mehrstufiges Dockerfile** mit einem `runtime`-Target (bzw. das Target in
   `compose.server.yaml` anpassen).
4. Datenbank-Migrationen laufen über einen Befehl, der **idempotent** ist
   (z.B. `prisma migrate deploy`).
5. Die App wertet **`X-Forwarded-*`-Header** aus und kennt die Anzahl Proxy-Hops
   (bei Express: `app.set('trust proxy', 2)` für Apache + Caddy). Sonst sieht sie
   statt der Client-IP die des Proxys — mit Folgen für Rate-Limiting und Logs.

Weicht eine App davon ab (kein Frontend, andere Migrations-Tooling), sind nur die
entsprechenden Stellen in `compose.*.yaml` bzw. der Migrations-Schritt in `deploy.sh`
zu ändern — die restliche Mechanik bleibt gleich.
