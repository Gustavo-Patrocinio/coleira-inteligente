-- Core schema (Phase 4). Plain SQL; applied in file-name order by src/db.ts.

CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE users (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email         text NOT NULL UNIQUE,
    password_hash text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE dogs (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id    bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name       text NOT NULL,
    timezone   text NOT NULL DEFAULT 'America/Sao_Paulo', -- IANA; days and nights are local
    birth_date date,
    weight_kg  numeric(5, 2),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX dogs_user_idx ON dogs (user_id);

CREATE TABLE devices (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dog_id     bigint NOT NULL REFERENCES dogs (id) ON DELETE CASCADE,
    serial     text NOT NULL UNIQUE,           -- e.g. the collar's BLE address
    token_hash text NOT NULL UNIQUE,           -- sha256 of the device token (token shown once)
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX devices_dog_idx ON devices (dog_id);

-- One row per collar per minute (contract 4.7, decoded). Idempotent key: (device_id, minute_ts).
CREATE TABLE activity_minute (
    device_id    bigint NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
    minute_ts    timestamptz NOT NULL,
    still_s      smallint NOT NULL,
    walking_s    smallint NOT NULL,
    running_s    smallint NOT NULL,
    scratching_s smallint NOT NULL,
    shaking_s    smallint NOT NULL,
    eating_s     smallint NOT NULL,
    drinking_s   smallint NOT NULL,
    unknown_s    smallint NOT NULL,
    battery_pct  smallint NOT NULL,
    flags        smallint NOT NULL,
    via          text NOT NULL CHECK (via IN ('base_station', 'app')), -- which path delivered it
    received_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, minute_ts),
    CHECK (still_s + walking_s + running_s + scratching_s + shaking_s + eating_s + drinking_s
           + unknown_s <= 60)
);
SELECT create_hypertable('activity_minute', by_range('minute_ts', INTERVAL '7 days'));

-- Daily metrics per dog and local day, written by the alerts job (also used by trends).
CREATE TABLE daily_metrics (
    dog_id          bigint NOT NULL REFERENCES dogs (id) ON DELETE CASCADE,
    day             date NOT NULL,
    coverage_min    integer NOT NULL,  -- minutes with data that day
    active_s        integer NOT NULL,  -- walking + running
    scratching_s    integer NOT NULL,
    night_wakeups   integer NOT NULL,  -- got-up episodes in the night ending that morning
    updated_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (dog_id, day)
);

CREATE TABLE alerts (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dog_id     bigint NOT NULL REFERENCES dogs (id) ON DELETE CASCADE,
    day        date NOT NULL,
    metric     text NOT NULL CHECK (metric IN ('activity', 'scratching', 'night_wakeups')),
    direction  text NOT NULL CHECK (direction IN ('high', 'low')),
    value      double precision NOT NULL,
    median     double precision NOT NULL,
    robust_z   double precision NOT NULL,
    feedback   text CHECK (feedback IN ('useful', 'false_alarm')),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (dog_id, day, metric)
);
