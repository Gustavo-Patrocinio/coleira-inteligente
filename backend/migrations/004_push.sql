-- Push notifications (FCM): the app registers each phone's token; the alerts job sends one
-- notification per new alert and marks it, so retries and restarts never send it twice.
CREATE TABLE push_tokens (
    token      text PRIMARY KEY, -- a phone moving to another account moves its token too
    user_id    bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    platform   text NOT NULL CHECK (platform IN ('android', 'ios')),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX push_tokens_user ON push_tokens (user_id);

ALTER TABLE alerts ADD COLUMN notified_at timestamptz;
