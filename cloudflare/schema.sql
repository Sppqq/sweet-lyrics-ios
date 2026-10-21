-- Reports sent from the app (Settings -> Reports). Photos live in R2 under "<id>/<n>.<ext>".
CREATE TABLE IF NOT EXISTS reports (
  id          TEXT PRIMARY KEY,
  created_at  INTEGER NOT NULL,          -- unix seconds
  kind        TEXT NOT NULL,             -- 'manual' | 'auto'
  error_kind  TEXT,                      -- what failed, for 'auto'
  message     TEXT,                      -- what the user wrote
  app_version TEXT,
  build       TEXT,
  channel     TEXT,
  os          TEXT,
  device      TEXT,
  locale      TEXT,
  install_id  TEXT,                      -- random per install, not tied to any account
  ip_hash     TEXT,                      -- salted hash, only for rate limits
  log         TEXT,
  photos      INTEGER NOT NULL DEFAULT 0,
  photo_exts  TEXT NOT NULL DEFAULT '',  -- e.g. 'jpg,png'
  status      TEXT NOT NULL DEFAULT 'open',  -- open | in_progress | closed
  updated_at  INTEGER NOT NULL DEFAULT 0     -- last message or status change
);
CREATE INDEX IF NOT EXISTS reports_created ON reports (created_at);
CREATE INDEX IF NOT EXISTS reports_install ON reports (install_id, created_at);
CREATE INDEX IF NOT EXISTS reports_ip ON reports (ip_hash, created_at);
CREATE INDEX IF NOT EXISTS reports_status ON reports (status, created_at);
CREATE TABLE IF NOT EXISTS messages (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  report_id   TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  author      TEXT NOT NULL,                 -- 'user' | 'dev'
  text        TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS messages_report ON messages (report_id, id);
-- Lyric translations shared by every install (/v1/translate). key: target + ":" + hash of the text.
CREATE TABLE IF NOT EXISTS translations (
  key         TEXT PRIMARY KEY,
  target      TEXT NOT NULL,
  text        TEXT NOT NULL,
  translation TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  used_at     INTEGER NOT NULL             -- last asked for (refreshed weekly at most)
);
CREATE INDEX IF NOT EXISTS translations_used ON translations (used_at);
-- Characters of uncached lines translated per network per hour.
CREATE TABLE IF NOT EXISTS translate_quota (
  ip_hash TEXT NOT NULL,
  hour    INTEGER NOT NULL,                -- unix hours
  chars   INTEGER NOT NULL,
  PRIMARY KEY (ip_hash, hour)
);
-- Line and song explanations (/v1/explain) and the artist bios they use.
CREATE TABLE IF NOT EXISTS explanations (
  key        TEXT PRIMARY KEY,               -- prompt version + hash of the model, language, track, lyrics and line
  body       TEXT NOT NULL,                  -- the JSON the app gets
  created_at INTEGER NOT NULL,
  used_at    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS explanations_used ON explanations (used_at);
CREATE TABLE IF NOT EXISTS artist_bios (
  key         TEXT PRIMARY KEY,              -- wiki language + ":" + lowercased artist name
  summary     TEXT NOT NULL,                 -- empty: Wikipedia had nothing (asked again after a week)
  description TEXT NOT NULL,
  url         TEXT NOT NULL,
  fetched_at  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS explain_quota (
  ip_hash TEXT NOT NULL,
  hour    INTEGER NOT NULL,
  count   INTEGER NOT NULL,
  PRIMARY KEY (ip_hash, hour)
);
-- Genius pages for explanations and complaints about answers (/v1/explain/report).
CREATE TABLE IF NOT EXISTS genius_songs (
  key        TEXT PRIMARY KEY,               -- lowercased "artist – title"
  body       TEXT NOT NULL,                  -- description, annotations and artist bio as JSON; empty: Genius had nothing
  fetched_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS explain_reports (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  key        TEXT NOT NULL,                  -- the explanation's cache key
  reason     TEXT NOT NULL,                  -- wrong | language | offensive | other
  comment    TEXT NOT NULL,
  answer     TEXT NOT NULL,                  -- the answer as it was, kept even after it leaves the cache
  install_id TEXT NOT NULL,
  ip_hash    TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS explain_reports_ip ON explain_reports (ip_hash, created_at);
