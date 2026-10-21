-- Genius pages for explanations and listeners' complaints about answers (/v1/explain/report). Safe to run on any database.
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
