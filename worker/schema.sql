CREATE TABLE IF NOT EXISTS replays(
  uuid TEXT PRIMARY KEY,
  key TEXT NOT NULL UNIQUE,
  map TEXT NOT NULL,
  category TEXT NOT NULL,
  course INTEGER NOT NULL,
  course_str TEXT,
  steamid64 TEXT NOT NULL,
  mode TEXT NOT NULL,
  timetype TEXT,
  jumptype TEXT,
  block INTEGER,
  reason TEXT,
  date TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  time_ms INTEGER,
  sha256 TEXT NOT NULL,
  size INTEGER NOT NULL,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_replays_map ON replays(map);
CREATE INDEX IF NOT EXISTS idx_replays_steam ON replays(steamid64);
CREATE INDEX IF NOT EXISTS idx_replays_date ON replays(date);
CREATE INDEX IF NOT EXISTS idx_replays_timestamp ON replays(timestamp);
