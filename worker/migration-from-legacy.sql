-- Run this only when replays was created from the original DEVELOPMENT.md schema.
-- Check first with: PRAGMA table_info(replays);
ALTER TABLE replays ADD COLUMN category TEXT NOT NULL DEFAULT 'run';
