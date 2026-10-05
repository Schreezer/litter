ALTER TABLE landing_participants ADD COLUMN waitlist_at INTEGER;
CREATE TABLE waitlist_entries (
 id TEXT PRIMARY KEY,
 email TEXT NOT NULL UNIQUE,
 created_at INTEGER NOT NULL,
 consent_version TEXT NOT NULL,
 experiment TEXT,
 variant TEXT CHECK (variant IN ('a','b')),
 participant_hash TEXT
);
CREATE INDEX waitlist_created ON waitlist_entries(created_at);
CREATE TABLE waitlist_rate_limits (key TEXT PRIMARY KEY, attempts INTEGER NOT NULL, expires_at INTEGER NOT NULL);
CREATE INDEX waitlist_rate_expiry ON waitlist_rate_limits(expires_at);
CREATE TABLE analytics_outbox (
 id TEXT PRIMARY KEY, experiment TEXT NOT NULL, participant_hash TEXT NOT NULL,
 variant TEXT NOT NULL, event TEXT NOT NULL, occurred_at INTEGER NOT NULL,
 delivered_at INTEGER
);
CREATE INDEX analytics_pending ON analytics_outbox(delivered_at, occurred_at);
CREATE TRIGGER analytics_exposed_at AFTER UPDATE OF exposed_at ON landing_participants
WHEN OLD.exposed_at IS NULL AND NEW.exposed_at IS NOT NULL
BEGIN
 INSERT OR IGNORE INTO analytics_outbox (id,experiment,participant_hash,variant,event,occurred_at)
 VALUES (NEW.experiment || ':' || NEW.participant_hash || ':landing_viewed', NEW.experiment, NEW.participant_hash, NEW.variant, 'landing_viewed', NEW.exposed_at);
END;
CREATE TRIGGER analytics_early_access_at AFTER UPDATE OF early_access_at ON landing_participants
WHEN OLD.early_access_at IS NULL AND NEW.early_access_at IS NOT NULL
BEGIN
 INSERT OR IGNORE INTO analytics_outbox (id,experiment,participant_hash,variant,event,occurred_at)
 VALUES (NEW.experiment || ':' || NEW.participant_hash || ':waitlist_cta_clicked', NEW.experiment, NEW.participant_hash, NEW.variant, 'waitlist_cta_clicked', NEW.early_access_at);
END;
CREATE TRIGGER analytics_demo_engaged_at AFTER UPDATE OF demo_engaged_at ON landing_participants
WHEN OLD.demo_engaged_at IS NULL AND NEW.demo_engaged_at IS NOT NULL
BEGIN
 INSERT OR IGNORE INTO analytics_outbox (id,experiment,participant_hash,variant,event,occurred_at)
 VALUES (NEW.experiment || ':' || NEW.participant_hash || ':demo_engaged', NEW.experiment, NEW.participant_hash, NEW.variant, 'demo_engaged', NEW.demo_engaged_at);
END;
CREATE TRIGGER analytics_waitlist_at AFTER UPDATE OF waitlist_at ON landing_participants
WHEN OLD.waitlist_at IS NULL AND NEW.waitlist_at IS NOT NULL
BEGIN
 INSERT OR IGNORE INTO analytics_outbox (id,experiment,participant_hash,variant,event,occurred_at)
 VALUES (NEW.experiment || ':' || NEW.participant_hash || ':waitlist_joined', NEW.experiment, NEW.participant_hash, NEW.variant, 'waitlist_joined', NEW.waitlist_at);
END;
