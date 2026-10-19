-- The shared translation cache (/v1/translate). Safe to run on any database: everything is IF NOT EXISTS.
CREATE TABLE IF NOT EXISTS translations (
  key         TEXT PRIMARY KEY,
  target      TEXT NOT NULL,
  text        TEXT NOT NULL,
  translation TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  used_at     INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS translations_used ON translations (used_at);
CREATE TABLE IF NOT EXISTS translate_quota (
  ip_hash TEXT NOT NULL,
  hour    INTEGER NOT NULL,
  chars   INTEGER NOT NULL,
  PRIMARY KEY (ip_hash, hour)
);
