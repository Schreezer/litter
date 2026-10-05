CREATE TABLE landing_participants (
    experiment TEXT NOT NULL,
    participant_hash TEXT NOT NULL,
    variant TEXT NOT NULL CHECK (variant IN ('a', 'b')),
    enrolled_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    exposed_at INTEGER,
    early_access_at INTEGER,
    demo_engaged_at INTEGER,
    PRIMARY KEY (experiment, participant_hash)
);
CREATE INDEX landing_participants_expiry ON landing_participants(expires_at);
CREATE INDEX landing_participants_cohort ON landing_participants(experiment, exposed_at, variant);
