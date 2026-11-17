/*
 * Builds per-minute summary records (contract 4.7 / ADR 0001) from one behavior label per
 * second (Phase 3).
 *
 * - Minutes are aligned to wall-clock (epoch) minutes, so the backend's (device, minute)
 *   key is meaningful. The collar only learns the time when a client syncs it (ADR 0013).
 * - Until then, labels are kept per uptime second in a RAM ring (last SB_RING_S seconds);
 *   when the clock arrives, those seconds are stamped retroactively and emitted.
 * - Minutes with no observed second produce no record; partial minutes are fine
 *   (sum of seconds ≤ 60 is the contract invariant).
 *
 * Pure C, no Zephyr dependencies: host-tested (firmware/app/tests/host_test.c).
 */
#ifndef COLLAR_SUMMARY_BUILDER_H_
#define COLLAR_SUMMARY_BUILDER_H_

#include <stdbool.h>
#include <stdint.h>

#define SB_RECORD_SIZE 15
#define SB_RING_S      7200 /* 2 h of per-second labels kept before the clock is known */
#define SB_LABEL_NONE  0xFE /* no observation for that second (not counted at all) */
#define SB_UNKNOWN     255  /* observed, but no confident class → unknown_s */

struct summary_builder {
	uint8_t ring[SB_RING_S];
	uint32_t next_uptime_s; /* uptime second the next sb_add() is expected for */
	bool started;
	bool clock_set;
	int64_t epoch_minus_uptime; /* epoch_s = uptime_s + this */
	uint32_t last_emitted_minute; /* epoch seconds of the last minute emitted (0 = none) */
	uint8_t battery_pct;
	uint8_t flags;
};

typedef void (*sb_emit_fn)(const uint8_t record[SB_RECORD_SIZE], void *user);

void sb_init(struct summary_builder *sb);
void sb_set_battery(struct summary_builder *sb, uint8_t pct);

/* Label for uptime second `uptime_s` (class ID 0..6, SB_UNKNOWN, or SB_LABEL_NONE).
 * Seconds skipped since the previous call are recorded as SB_LABEL_NONE. */
void sb_add(struct summary_builder *sb, uint32_t uptime_s, uint8_t label);

/* The client says it is `epoch_s` now, at collar uptime `uptime_s`. Later calls adjust
 * the clock (drift); minutes already emitted are never emitted again. */
void sb_set_clock(struct summary_builder *sb, uint32_t epoch_s, uint32_t uptime_s);

/* Emits every complete minute not emitted yet (oldest first). Returns how many. */
int sb_flush(struct summary_builder *sb, uint32_t now_uptime_s, sb_emit_fn emit, void *user);

/* Encodes one record (exposed for tests and the sync code). */
void sb_encode(uint8_t out[SB_RECORD_SIZE], uint32_t minute_ts, const uint8_t seconds[7],
	       uint8_t unknown_s, uint8_t battery_pct, uint8_t flags);

#endif /* COLLAR_SUMMARY_BUILDER_H_ */
