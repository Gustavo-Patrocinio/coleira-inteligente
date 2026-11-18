-- Profiles: the owner's name and the dog's sex, neutering and breed (with the existing birth
-- date and weight). All optional: an account works with an email and a dog with a name.
ALTER TABLE users ADD COLUMN name text CHECK (char_length(name) <= 80);

ALTER TABLE dogs
  ADD COLUMN sex text CHECK (sex IN ('male', 'female')),
  ADD COLUMN neutered boolean,
  ADD COLUMN breed text CHECK (char_length(breed) <= 80);

-- Several collars per account and per dog. A collar moved to another dog gets a new device
-- row, so the old dog keeps its history; the old row is retired (its token stops working)
-- and minutes from before the move are not credited to the new dog (active_from).
ALTER TABLE devices
  DROP CONSTRAINT devices_serial_key,
  ADD COLUMN retired_at timestamptz,
  ADD COLUMN active_from timestamptz,
  ADD COLUMN name text CHECK (char_length(name) <= 40);
CREATE UNIQUE INDEX devices_active_serial ON devices (serial) WHERE retired_at IS NULL;
