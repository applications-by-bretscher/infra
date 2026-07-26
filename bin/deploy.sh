#!/usr/bin/env bash
# =============================================================================
# Generisches Deploy-Skript – mit Backup, Health-Check und automatischem Rollback.
#
# Dieses Skript ist NICHT app-spezifisch. Es liegt zentral unter
# /srv/infra/bin/deploy.sh und bedient ALLE Apps. Es wird NICHT in die App-Repos
# kopiert – so kann es keine auseinanderdriftenden Kopien geben.
#
# Alles Projektabhängige steht in der .env der jeweiligen Umgebung:
#   APP_NAME, DOMAIN, PUBLIC_API_URL   (Pflicht)
#   BACKEND_DIR                        (optional, Default "backend")
#
# Erwartete Konvention im App-Repo:
#   compose.yaml          gemeinsame Service-Definitionen
#   compose.server.yaml   Server-Override für staging UND production
#   <BACKEND_DIR>/.env    Secrets und DATABASE_URL
#
# Immer AUS dem App-Verzeichnis heraus aufrufen:
#   cd /srv/apps/<app>/staging && /srv/infra/bin/deploy.sh staging
#
#   deploy.sh production            # deployt origin/main
#   deploy.sh staging               # deployt origin/development
#   deploy.sh staging feature/xyz   # deployt einen beliebigen Branch/Tag/SHA
#   deploy.sh production --dry-run  # zeigt nur, was passieren würde
#
# Ablauf (die Reihenfolge ist Absicht):
#   1. Code holen          – nur auschecken, noch nichts anfassen
#   2. DB-Backup           – bevor irgendeine Migration läuft
#   3. Images bauen        – die laufende App bleibt dabei unberührt
#   4. Migrationen         – explizit, damit Fehler VOR dem Umschalten auffallen
#   5. Container starten
#   6. Health-Check        – Container gesund + Seite erreichbar
#   Bei Fehler in 3–6 → automatischer Rollback auf den letzten guten Image-Tag.
#
# Bewusst KEIN automatischer DB-Restore: das würde alle Daten verwerfen, die seit
# dem Backup geschrieben wurden. Das Skript gibt im Fehlerfall den fertigen
# Restore-Befehl aus – die Entscheidung bleibt beim Menschen.
# =============================================================================
set -euo pipefail

# ── Argumente ────────────────────────────────────────────────────────────────
ENVIRONMENT="${1:-}"
GIT_REF="${2:-}"
DRY_RUN=0
for arg in "$@"; do
    [ "$arg" = "--dry-run" ] && DRY_RUN=1
done
[ "${GIT_REF:-}" = "--dry-run" ] && GIT_REF=""

case "$ENVIRONMENT" in
    production) PROJECT_SUFFIX="";         DEFAULT_REF="main" ;;
    staging)    PROJECT_SUFFIX="-staging"; DEFAULT_REF="development" ;;
    *)
        echo "Usage: $0 <production|staging> [git-ref] [--dry-run]" >&2
        exit 2
        ;;
esac
GIT_REF="${GIT_REF:-$DEFAULT_REF}"

# Beide Umgebungen nutzen dieselbe Server-Compose-Datei; den Unterschied macht
# ENVIRONMENT (Image-Namen und Netzwerk-Aliase). Export, damit compose es sieht.
# Wert merken: die .env wird spaeter eingelesen und darf ihn nicht ueberschreiben.
ENVIRONMENT_ARG="$ENVIRONMENT"
export ENVIRONMENT
COMPOSE_FILES=(-f compose.yaml -f compose.server.yaml)

# ── Pfade ────────────────────────────────────────────────────────────────────
# Dieses Skript liegt zentral (/srv/infra/bin/deploy.sh) und bedient ALLE Apps.
# Das App-Verzeichnis ist deshalb das aktuelle Arbeitsverzeichnis, NICHT der Ort
# des Skripts. Aufruf also immer aus dem App-Verzeichnis heraus:
#   cd /srv/apps/<app>/<environment> && /srv/infra/bin/deploy.sh <environment>
# Alternativ per Umgebungsvariable: APP_DIR=/srv/apps/... /srv/infra/bin/deploy.sh …
APP_DIR="${APP_DIR:-$PWD}"
BACKUP_DIR="${BACKUP_DIR:-$APP_DIR/../backups}"
STATE_FILE="$APP_DIR/.deploy-state"
BACKUP_RETENTION=10

# Verzeichnis des Backends innerhalb der App. Nicht fest verdrahten – nicht jede
# App nennt es gleich. Überschreibbar in der .env der Umgebung:
#   BACKEND_DIR=api
BACKEND_DIR="${BACKEND_DIR:-backend}"

cd "$APP_DIR"

log()  { echo -e "\n\033[1;34m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*" >&2; }
fail() { echo -e "\033[1;31m[x]\033[0m $*" >&2; }
ok()   { echo -e "\033[1;32m[ok]\033[0m $*"; }

# ── Vorbedingungen ───────────────────────────────────────────────────────────
[ -f "$APP_DIR/.env" ] || { fail "Es fehlt $APP_DIR/.env (APP_NAME, DOMAIN, PUBLIC_API_URL)."; exit 1; }

# .env ZUERST einlesen – sie darf BACKEND_DIR überschreiben, das direkt danach
# geprüft wird.
# shellcheck disable=SC1091
set -a; source "$APP_DIR/.env"; set +a

# Das Argument gewinnt IMMER gegen die .env. Stuende dort versehentlich
# ENVIRONMENT=production, wuerde "deploy.sh staging" sonst die Produktion
# ueberschreiben - ein Fehler, den man erst nach dem Schaden bemerkt.
ENVIRONMENT="$ENVIRONMENT_ARG"
export ENVIRONMENT

: "${APP_NAME:?APP_NAME fehlt in .env}"
: "${DOMAIN:?DOMAIN fehlt in .env}"

BACKEND_ENV="$APP_DIR/$BACKEND_DIR/.env"
[ -f "$BACKEND_ENV" ] || {
    fail "Es fehlt $BACKEND_ENV (DATABASE_URL, Secrets)."
    fail "Heisst der Backend-Ordner anders? Dann BACKEND_DIR=<ordner> in $APP_DIR/.env setzen."
    exit 1
}
docker network inspect edge >/dev/null 2>&1 || {
    fail "Docker-Netzwerk 'edge' fehlt. Einmalig anlegen: docker network create edge"
    exit 1
}

PROJECT_NAME="${APP_NAME}${PROJECT_SUFFIX}"
COMPOSE=(docker compose -p "$PROJECT_NAME" "${COMPOSE_FILES[@]}")

echo "============================================================"
echo " Deploy: $APP_NAME / $ENVIRONMENT"
echo " Ref:    $GIT_REF"
echo " Domain: $DOMAIN"
[ "$DRY_RUN" = "1" ] && echo " Modus:  DRY-RUN (es wird nichts verändert)"
echo "============================================================"

PREVIOUS_TAG="$(cat "$STATE_FILE" 2>/dev/null || true)"

# ── Health-Check ─────────────────────────────────────────────────────────────
# Nutzt den Healthcheck, der bereits in compose.yaml für den Backend-Service
# definiert ist – kein zweiter, abweichender Gesundheitsbegriff.
wait_for_healthy() {
    local timeout="${1:-120}"
    local waited=0
    local cid status

    while [ "$waited" -lt "$timeout" ]; do
        cid="$("${COMPOSE[@]}" ps -q backend 2>/dev/null || true)"
        if [ -n "$cid" ]; then
            status="$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo unknown)"
            case "$status" in
                healthy)   return 0 ;;
                unhealthy) return 1 ;;
            esac
        fi
        sleep 3
        waited=$((waited + 3))
        echo -n "."
    done
    echo
    return 1
}

# Testet die interne Kette Caddy -> Frontend-Container mit dem echten Host-Header.
# Bewusst NICHT über https://$DOMAIN: das liefe über hades zurück und würde bei
# einem DNS- oder Apache-Problem fehlschlagen, obwohl der Deploy selbst in Ordnung
# ist (und umgekehrt ein hairpin-NAT-Problem als Deploy-Fehler erscheinen lassen).
smoke_test() {
    local port="${EDGE_HTTP_PORT:-8080}"
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
        -H "Host: $DOMAIN" "http://localhost:${port}/" 2>/dev/null || echo 000)"
    echo "    GET http://localhost:${port}/ (Host: $DOMAIN) -> HTTP $code"
    [ "$code" = "200" ]
}

# ── Rollback ─────────────────────────────────────────────────────────────────
rollback() {
    local reason="$1"
    fail "$reason"

    if [ -z "$PREVIOUS_TAG" ]; then
        warn "Kein vorheriger Image-Tag bekannt - automatischer Rollback nicht moeglich."
        warn "Der Stack laeuft moeglicherweise in einem unfertigen Zustand. Bitte pruefen:"
        warn "  ${COMPOSE[*]} ps"
        return
    fi

    log "ROLLBACK auf $PREVIOUS_TAG"
    if IMAGE_TAG="$PREVIOUS_TAG" "${COMPOSE[@]}" up -d --no-build; then
        if wait_for_healthy 90; then
            ok "Rollback erfolgreich - die vorherige Version laeuft wieder."
        else
            fail "Rollback gestartet, aber Health-Check schlaegt weiterhin fehl. Bitte sofort pruefen!"
        fi
    else
        fail "Rollback fehlgeschlagen. Bitte sofort manuell eingreifen!"
    fi

    if [ -n "${BACKUP_FILE:-}" ] && [ -f "${BACKUP_FILE:-}" ]; then
        echo
        warn "Falls die Datenbank durch eine Migration beschaedigt wurde, kann sie so"
        warn "zurueckgespielt werden (VORSICHT: verwirft alle Daten seit dem Backup):"
        echo "  gunzip -c '$BACKUP_FILE' \\"
        echo "    | docker run --rm -i --network edge -e MYSQL_PWD='<passwort>' mysql:8.0 \\"
        echo "      mysql -h '${DB_HOST:-<db-host>}' -P '${DB_PORT:-3306}' -u '${DB_USER:-<db-user>}' '${DB_NAME:-<db-name>}'"
        warn "Das Passwort steht in $BACKEND_ENV (DATABASE_URL)."
    fi
}

# ── 1. Code holen ────────────────────────────────────────────────────────────
log "Code holen ($GIT_REF)"
if [ "$DRY_RUN" = "1" ]; then
    echo "   [dry-run] git fetch + checkout $GIT_REF"
    NEW_TAG="dryrun"
else
    git fetch --prune --tags origin
    git checkout --detach "origin/$GIT_REF" 2>/dev/null || git checkout --detach "$GIT_REF"
    NEW_TAG="$(git rev-parse --short HEAD)"
fi
export IMAGE_TAG="$NEW_TAG"
echo "    Neuer Image-Tag:  $NEW_TAG"
echo "    Bisheriger Tag:   ${PREVIOUS_TAG:-<keiner>}"

# ── 2. DB-Backup ─────────────────────────────────────────────────────────────
log "Datenbank sichern (vor allen Migrationen)"
BACKUP_FILE=""
if [ "$DRY_RUN" = "1" ]; then
    echo "   [dry-run] mysqldump -> $BACKUP_DIR/${ENVIRONMENT}_<timestamp>.sql.gz"
else
    mkdir -p "$BACKUP_DIR"

    # DATABASE_URL direkt aus der Datei lesen - NICHT ueber `docker --env-file`.
    # Dessen Parser nimmt jede Zeile woertlich: Anfuehrungszeichen wuerden Teil
    # des Werts, und mehrzeilige Eintraege (z.B. FCM_SERVICE_ACCOUNT_JSON)
    # bringen ihn durcheinander.
    DB_URL="$(sed -n 's/^[[:space:]]*DATABASE_URL[[:space:]]*=[[:space:]]*//p' "$BACKEND_ENV" | tail -n 1)"
    DB_URL="${DB_URL%"${DB_URL##*[![:space:]]}"}"        # Leerzeichen am Ende
    case "$DB_URL" in                                     # umschliessende Quotes
        \"*\") DB_URL="${DB_URL#\"}"; DB_URL="${DB_URL%\"}" ;;
        \'*\') DB_URL="${DB_URL#\'}"; DB_URL="${DB_URL%\'}" ;;
    esac

    if [ -z "$DB_URL" ]; then
        fail "In $BACKEND_ENV wurde keine Zeile DATABASE_URL=... gefunden."
        fail "Ohne Backup wird nicht migriert."
        exit 1
    fi

    # Zerlegen mit Node statt Regex: Passwoerter koennen URL-encodete
    # Sonderzeichen enthalten. Ausgabe zeilenweise, damit nichts escaped werden muss.
    # (Das JS enthaelt bewusst KEINE einfachen Anfuehrungszeichen.)
    DB_INFO="$(
        docker run --rm -e DATABASE_URL="$DB_URL" node:20-bookworm-slim \
            node -e 'const u=new URL(process.env.DATABASE_URL);process.stdout.write([u.hostname,u.port||"3306",decodeURIComponent(u.username),decodeURIComponent(u.password),u.pathname.replace(/^\//,"")].join("\n"))' \
            2>/dev/null
    )" || DB_INFO=""

    if [ -z "$DB_INFO" ]; then
        fail "DATABASE_URL konnte nicht geparst werden - Deploy abgebrochen."
        # Passwort ausblenden, damit es nicht in Logs landet
        fail "Gefunden: $(printf '%s' "$DB_URL" | sed -E 's#(//[^:]*:)[^@]*@#\1***@#')"
        fail "Erwartet: mysql://benutzer:passwort@host:3306/datenbank"
        exit 1
    fi

    { read -r DB_HOST; read -r DB_PORT; read -r DB_USER; read -r DB_PASS; read -r DB_NAME; } <<< "$DB_INFO"

    if [ -z "$DB_HOST" ] || [ -z "$DB_NAME" ]; then
        fail "DATABASE_URL unvollstaendig (Host oder Datenbankname fehlt) - Deploy abgebrochen."
        exit 1
    fi
    BACKUP_FILE="$BACKUP_DIR/${ENVIRONMENT}_$(date +%Y%m%d-%H%M%S)_${NEW_TAG}.sql.gz"
    DUMP_ERR="$(mktemp)"
    # --network edge ist zwingend: die zentrale Datenbank ist nur dort unter dem
    # Namen "mysql" erreichbar. Eine externe DB waere von hier ebenfalls erreichbar.
    if docker run --rm --network edge -e MYSQL_PWD="$DB_PASS" mysql:8.0 \
        mysqldump -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" \
            --single-transaction --quick --no-tablespaces \
            --set-gtid-purged=OFF "$DB_NAME" 2>"$DUMP_ERR" | gzip > "$BACKUP_FILE"
    then
        rm -f "$DUMP_ERR"
        ok "Backup: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
        ls -1t "$BACKUP_DIR/${ENVIRONMENT}_"*.sql.gz 2>/dev/null \
            | tail -n +$((BACKUP_RETENTION + 1)) | xargs -r rm -f
    else
        rm -f "$BACKUP_FILE"; BACKUP_FILE=""
        fail "Backup fehlgeschlagen - Deploy abgebrochen (ohne Sicherung wird nicht migriert)."
        fail "Verbindung: $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"
        # Meldung von mysqldump zeigen - ohne sie sucht man im Dunkeln
        if [ -s "$DUMP_ERR" ]; then
            fail "mysqldump meldet:"
            sed 's/^/      /' "$DUMP_ERR" >&2
        fi
        rm -f "$DUMP_ERR"
        exit 1
    fi
fi

# ── 3. Images bauen ──────────────────────────────────────────────────────────
# Vor dem Stoppen: ein fehlgeschlagener Build laesst die laufende App unberuehrt.
log "Images bauen (Tag: $NEW_TAG)"
if [ "$DRY_RUN" = "1" ]; then
    echo "   [dry-run] ${COMPOSE[*]} build"
elif ! "${COMPOSE[@]}" build; then
    rollback "Build fehlgeschlagen."
    exit 1
fi

# ── 4. Migrationen ───────────────────────────────────────────────────────────
log "Prisma-Migrationen anwenden"
if [ "$DRY_RUN" = "1" ]; then
    echo "   [dry-run] ${COMPOSE[*]} run --rm --no-deps -T backend npx prisma migrate deploy"
elif ! "${COMPOSE[@]}" run --rm --no-deps -T backend npx prisma migrate deploy; then
    rollback "Migration fehlgeschlagen."
    exit 1
fi

# ── 5. Container starten ─────────────────────────────────────────────────────
log "Container starten"
if [ "$DRY_RUN" = "1" ]; then
    echo "   [dry-run] ${COMPOSE[*]} up -d --no-build"
elif ! "${COMPOSE[@]}" up -d --no-build; then
    rollback "Start der Container fehlgeschlagen."
    exit 1
fi

# ── 6. Health-Check ──────────────────────────────────────────────────────────
log "Health-Check"
if [ "$DRY_RUN" = "1" ]; then
    echo "   [dry-run] auf 'healthy' warten + interner Smoke-Test (Host: $DOMAIN)"
else
    if ! wait_for_healthy 150; then
        "${COMPOSE[@]}" logs --tail 50 backend || true
        rollback "Backend wurde nicht healthy."
        exit 1
    fi
    echo
    ok "Backend ist healthy"

    if ! smoke_test; then
        warn "Interner Smoke-Test fehlgeschlagen (Backend-Container ist aber healthy)."
        warn "Haeufigste Ursachen:"
        warn "  - Caddy-Snippet fehlt in /srv/infra/caddy/conf.d/ oder wurde nicht neu geladen"
        warn "  - Domain im Snippet passt nicht zu DOMAIN aus der .env ($DOMAIN)"
        warn "  - Netzwerk-Alias im Snippet passt nicht zu compose.<env>.yaml"
        warn "Pruefen: docker compose -f /srv/infra/compose.yaml logs --tail 50 caddy"
        rollback "App ueber den internen Edge-Router nicht erreichbar."
        exit 1
    fi
    ok "Interner Smoke-Test bestanden (oeffentlich: https://$DOMAIN/ via hades)"
fi

# ── Abschluss ────────────────────────────────────────────────────────────────
# Aufräumen bewusst NUR auf die Images dieser App+Umgebung begrenzt.
# Ein globales `docker image prune` wäre hier falsch: auf diesem Server laufen
# auch fremde Container (OnlyOffice, Grafana, Plex …), die davon betroffen sein
# könnten. Wir behalten die letzten IMAGE_RETENTION Tags, damit ein manueller
# Rollback auf eine ältere Version jederzeit möglich bleibt.
IMAGE_RETENTION="${IMAGE_RETENTION:-5}"

prune_own_images() {
    local repo
    for repo in "$APP_NAME-$ENVIRONMENT-backend" "$APP_NAME-$ENVIRONMENT-frontend"; do
        docker images "$repo" --format '{{.Tag}} {{.CreatedAt}}' 2>/dev/null \
            | sort -k2 -r \
            | tail -n +$((IMAGE_RETENTION + 1)) \
            | awk '{print $1}' \
            | while read -r tag; do
                [ -n "$tag" ] && [ "$tag" != "$NEW_TAG" ] \
                    && docker rmi "$repo:$tag" >/dev/null 2>&1 || true
            done
    done
}

if [ "$DRY_RUN" != "1" ]; then
    echo "$NEW_TAG" > "$STATE_FILE"
    prune_own_images
fi

log "Status"
[ "$DRY_RUN" = "1" ] || "${COMPOSE[@]}" ps

echo
ok "Deploy abgeschlossen: $APP_NAME / $ENVIRONMENT @ $NEW_TAG"
