-- =============================================================================
-- Legt Datenbanken und Benutzer für die Apps an.
--
-- WICHTIG: Diese Datei wird NUR beim allerersten Start ausgeführt, solange das
-- Volume mysql_data noch leer ist. Spätere Änderungen hier haben keine Wirkung –
-- dann die Statements von Hand ausführen (Adminer oder docker exec).
--
-- Passwörter: Diese Datei liegt im Repo. Trage hier KEINE echten Passwörter ein.
-- Die Platzhalter unten werden beim ersten Start gesetzt und danach über
-- Adminer geändert – oder besser: lege die Benutzer nach dem ersten Start
-- manuell an. Siehe docs/database.md.
-- =============================================================================

-- ── musig-elgg ───────────────────────────────────────────────────────────────
CREATE DATABASE IF NOT EXISTS musig_elgg_staging
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Produktion folgt später als eigener, geplanter Umzug von herkules.
-- CREATE DATABASE IF NOT EXISTS musig_elgg
--   CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- ── Weitere Apps hier ergänzen ───────────────────────────────────────────────
-- CREATE DATABASE IF NOT EXISTS rotary_staging
--   CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
