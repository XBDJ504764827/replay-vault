-- Run once when upgrading an existing D1 database that predates the in-game
-- replay viewer. Check first with: PRAGMA table_info(replays);
-- If "tickrate" is missing, run this migration, then deploy the updated Worker.
ALTER TABLE replays ADD COLUMN tickrate INTEGER;
