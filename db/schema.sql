-- Focus intervals. started_at and ended_at are unix milliseconds.
-- ended_at is null only for the segment that is still in the foreground.
-- Queries treat a window as half-open: [from, to).

CREATE TABLE IF NOT EXISTS segments (
    id INTEGER PRIMARY KEY,
    started_at INTEGER NOT NULL,
    ended_at INTEGER,
    app_name TEXT NOT NULL,
    bundle_id TEXT NOT NULL,
    window_title TEXT,
    url TEXT,
    hostname TEXT,
    category TEXT,
    work_related INTEGER
);

CREATE INDEX IF NOT EXISTS idx_segments_started_at ON segments (started_at);
CREATE INDEX IF NOT EXISTS idx_segments_hostname ON segments (hostname);
CREATE INDEX IF NOT EXISTS idx_segments_open ON segments (started_at) WHERE ended_at IS NULL;
