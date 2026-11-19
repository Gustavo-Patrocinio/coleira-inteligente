-- Sessions and password reset.
-- token_version goes into every login token; changing or resetting the password bumps it,
-- so tokens issued before stop working on every other phone.
ALTER TABLE users ADD COLUMN token_version integer NOT NULL DEFAULT 0;

-- One pending reset code per user: a 6-digit code sent by email, stored only as a hash,
-- valid for 15 minutes and for at most 5 wrong guesses.
CREATE TABLE password_resets (
  user_id     bigint PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
  code_hash   text NOT NULL,
  expires_at  timestamptz NOT NULL,
  attempts    integer NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now()
);
