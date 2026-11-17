-- Hourly continuous aggregate per collar (Phase 4). Created WITH NO DATA so it can run in
-- the migration transaction; the policy fills and keeps it fresh.

CREATE MATERIALIZED VIEW activity_hourly
WITH (timescaledb.continuous) AS
SELECT device_id,
       time_bucket(INTERVAL '1 hour', minute_ts) AS bucket,
       count(*)::integer          AS minutes,
       sum(still_s)::integer      AS still_s,
       sum(walking_s)::integer    AS walking_s,
       sum(running_s)::integer    AS running_s,
       sum(scratching_s)::integer AS scratching_s,
       sum(shaking_s)::integer    AS shaking_s,
       sum(eating_s)::integer     AS eating_s,
       sum(drinking_s)::integer   AS drinking_s,
       sum(unknown_s)::integer    AS unknown_s
FROM activity_minute
GROUP BY device_id, bucket
WITH NO DATA;

SELECT add_continuous_aggregate_policy('activity_hourly',
    start_offset      => INTERVAL '35 days',
    end_offset        => INTERVAL '1 hour',
    schedule_interval => INTERVAL '15 minutes');
