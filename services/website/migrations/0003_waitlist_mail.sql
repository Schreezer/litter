ALTER TABLE waitlist_entries ADD COLUMN unsubscribe_token TEXT;
ALTER TABLE waitlist_entries ADD COLUMN unsubscribed_at INTEGER;
CREATE UNIQUE INDEX waitlist_unsubscribe_token ON waitlist_entries(unsubscribe_token);
CREATE TABLE mail_outbox (
 id TEXT PRIMARY KEY REFERENCES waitlist_entries(id),
 state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','sending','accepted','failed','uncertain','cancelled')),
 attempts INTEGER NOT NULL DEFAULT 0,
 next_attempt_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL,
 message_id TEXT,
 error_code TEXT
);
CREATE INDEX mail_pending ON mail_outbox(state,next_attempt_at);
