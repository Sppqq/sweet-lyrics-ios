-- Line and song explanations (/v1/explain) and the artist bios they use. Safe to run on any database.
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
