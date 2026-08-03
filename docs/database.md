# Zentrale Datenbank

Ein MySQL-Container auf argos hält die Datenbanken **aller** Apps — je eine pro
App und Umgebung. Die Weboberfläche (Adminer) läuft daneben.

```
argos
└── /srv/infra
    ├── mysql      ← alle Datenbanken     (Volume: infra_mysql_data)
    └── adminer    ← Weboberfläche        (über hades, passwortgeschützt)
```

Die App-Container erreichen die Datenbank über das `edge`-Netz unter dem
Hostnamen **`mysql`**. In der `backend/.env` der jeweiligen Umgebung also:

```ini
DATABASE_URL="mysql://musig_elgg:PASSWORT@mysql:3306/musig_elgg_staging"
```

Kein `sslca` mehr nötig — die Verbindung verlässt den Server nicht.

---

## Einrichtung

```bash
cp /srv/infra/.env.example /srv/infra/.env
nano /srv/infra/.env          # MYSQL_ROOT_PASSWORD setzen
docker compose -f /srv/infra/compose.yaml up -d mysql adminer
```

Der erste Start dauert etwas (MySQL initialisiert sich) und spielt
`mysql/init/*.sql` ein. **Nur beim ersten Mal** — bei leerem Volume.

---

## Datenbank und Benutzer für eine App anlegen

Pro App und Umgebung ein eigener Benutzer, der **nur** auf seine Datenbank darf.
So kann eine kompromittierte App nicht die Daten der anderen lesen.

> ### Passwörter: hex, nicht base64
>
> Das Passwort landet in der `DATABASE_URL` — also **in einer URL**. Zeichen wie
> `/ @ : % ? #` haben dort eine Bedeutung und zerlegen die URL falsch. Bei
> `mysql://user:ab/cd@mysql:3306/db` endet die Auswertung am `/`, das Passwort
> wird zu `ab`, und die Anmeldung scheitert mit `Access denied`.
>
> `openssl rand -base64` erzeugt genau solche Zeichen (`+`, `/`, `=`). Deshalb:
>
> ```bash
> openssl rand -hex 24
> ```
>
> Ergibt nur `0-9a-f` und ist in jeder URL unproblematisch. Wer ein vorhandenes
> Passwort mit Sonderzeichen behalten will, muss es URL-kodieren (`/` → `%2F`).

```bash
docker compose -f /srv/infra/compose.yaml exec mysql \
  mysql -uroot -p -e "
    CREATE DATABASE IF NOT EXISTS meine_app_staging
      CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER IF NOT EXISTS 'meine_app_staging'@'%' IDENTIFIED BY 'PASSWORT';  -- openssl rand -hex 24
    GRANT ALL PRIVILEGES ON meine_app_staging.* TO 'meine_app_staging'@'%';
    FLUSH PRIVILEGES;"
```

> Kein `GRANT ALL ON *.*` — das gäbe der App Zugriff auf sämtliche Datenbanken.

---

## Bestehende Datenbank übernehmen

> ### Beim Import niemals `-p` verwenden
>
> `mysql -uroot -p < dump.sql` schlägt fehl mit `Access denied`. Grund: Ohne
> Terminal liest der Passwort-Prompt aus **stdin** — und dort steht der Dump.
> MySQL nimmt also die erste Zeile der SQL-Datei als Passwort.
>
> Stattdessen das Passwort per `MYSQL_PWD` übergeben, dann bleibt stdin frei:

```bash
ROOT_PW=$(grep -m1 '^MYSQL_ROOT_PASSWORD=' /srv/infra/.env | cut -d= -f2- | tr -d '"')

docker compose -f /srv/infra/compose.yaml exec -T -e MYSQL_PWD="$ROOT_PW" mysql \
  mysql -uroot < dump.sql
```

Für gepackte Dumps:

```bash
gunzip -c dump.sql.gz | docker compose -f /srv/infra/compose.yaml exec -T \
  -e MYSQL_PWD="$ROOT_PW" mysql mysql -uroot meine_app_staging
```

> Enthält der Dump kein `DROP TABLE IF EXISTS` (z.B. Exporte aus HeidiSQL), muss
> die Zieldatenbank **leer** sein — sonst brechen die `CREATE TABLE`-Anweisungen
> ab. Dann vorher `DROP DATABASE` + `CREATE DATABASE`.

Umgekehrt exportieren:

```bash
docker compose -f /srv/infra/compose.yaml exec mysql \
  mysqldump -uroot -p --single-transaction meine_app_staging | gzip > dump.sql.gz
```

---

## Sicherung

**Das Volume `infra_mysql_data` ist der wertvollste Teil des Servers.** Die
Backups in `deploy.sh` laufen nur vor Migrationen und ersetzen keine
regelmässige Sicherung.

Ein einfacher täglicher Dump aller Datenbanken:

```bash
sudo tee /etc/cron.daily/mysql-backup > /dev/null <<'EOF'
#!/bin/sh
set -e
DEST=/srv/backups/mysql
mkdir -p "$DEST"
docker compose -f /srv/infra/compose.yaml exec -T mysql \
  mysqldump -uroot -p"$(grep '^MYSQL_ROOT_PASSWORD=' /srv/infra/.env | cut -d= -f2-)" \
  --all-databases --single-transaction --routines --events \
  | gzip > "$DEST/all-$(date +%F).sql.gz"
# älter als 14 Tage entfernen
find "$DEST" -name 'all-*.sql.gz' -mtime +14 -delete
EOF
sudo chmod +x /etc/cron.daily/mysql-backup
```

Danach einmal von Hand testen und prüfen, dass die Datei nicht leer ist:

```bash
sudo /etc/cron.daily/mysql-backup && ls -lh /srv/backups/mysql/
```

> Ein Backup, das noch nie zurückgespielt wurde, ist kein Backup. Spiele
> mindestens einmal einen Dump in eine Testdatenbank ein, um sicher zu sein,
> dass er brauchbar ist.

---

## Weboberfläche

Erreichbar unter der eingerichteten Domain (Vorlage:
`templates/apache-vhost-adminer.conf`), geschützt durch **zwei** Hürden:

1. HTTP-Basic-Auth im Apache auf hades
2. den MySQL-Login selbst

Beim Login in Adminer:

| Feld | Wert |
|---|---|
| System | MySQL |
| Server | `mysql` |
| Benutzer | `root` oder der App-Benutzer |
| Passwort | aus `/srv/infra/.env` |

> Grosse Importe (> ein paar MB) laufen über die Kommandozeile zuverlässiger —
> die Weboberfläche stösst an PHP-Upload-Grenzen.
