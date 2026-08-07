-- =============================================================================
-- Legt Datenbanken für die Apps an.
--
-- WICHTIG: Diese Datei läuft NUR beim allerersten Start, solange das Volume
-- mysql_data noch leer ist. Spätere Änderungen hier haben KEINE Wirkung – dann
-- die Statements von Hand ausführen (Adminer oder docker compose exec).
--
-- Auf einem laufenden Server ist sie damit reine Dokumentation. Der gültige Weg,
-- eine Datenbank samt Benutzer anzulegen, steht im docs-Repo:
--   docs/06-datenbank.md  →  "Datenbank und Benutzer anlegen"
--
-- Passwörter: Diese Datei liegt im Repo. Hier stehen deshalb KEINE Benutzer und
-- keine Passwörter – die werden nach dem ersten Start von Hand angelegt.
--
-- Kollation: utf8mb4_unicode_ci, passend zu --collation-server in compose.yaml.
-- Bewusst NICHT die MySQL-8-Vorgabe utf8mb4_0900_ai_ci – die bestehenden
-- Datenbestände tragen durchgehend utf8mb4_unicode_ci, und gemischte
-- Kollationen brechen später bei JOINs mit "Illegal mix of collations".
-- Begründung und Prüfbefehle: docs/06-datenbank.md → "Kollation"
-- =============================================================================

-- ── musig-elgg ───────────────────────────────────────────────────────────────
-- Beide Umgebungen laufen seit 08/2026 auf diesem Server.
CREATE DATABASE IF NOT EXISTS musig_elgg
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS musig_elgg_staging
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- ── Weitere Apps hier ergänzen ───────────────────────────────────────────────
-- CREATE DATABASE IF NOT EXISTS rotary
--   CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
-- CREATE DATABASE IF NOT EXISTS rotary_staging
--   CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
