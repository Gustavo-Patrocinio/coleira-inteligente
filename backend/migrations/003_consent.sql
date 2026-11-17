-- LGPD consent (app onboarding): which version of the privacy notice the user accepted and
-- when, plus the separate, optional opt-in to share collection sessions for training.
ALTER TABLE users
  ADD COLUMN consent_version integer,
  ADD COLUMN consent_at timestamptz,
  ADD COLUMN research_opt_in boolean NOT NULL DEFAULT false;
