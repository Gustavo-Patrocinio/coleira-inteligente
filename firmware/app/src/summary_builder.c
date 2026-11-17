#include "summary_builder.h"

#include <string.h>

void sb_init(struct summary_builder *sb)
{
	memset(sb, 0, sizeof(*sb));
	memset(sb->ring, SB_LABEL_NONE, sizeof(sb->ring));
	sb->battery_pct = 0;
}

void sb_set_battery(struct summary_builder *sb, uint8_t pct)
{
	sb->battery_pct = pct > 100 ? 100 : pct;
}

void sb_add(struct summary_builder *sb, uint32_t uptime_s, uint8_t label)
{
	if (!sb->started) {
		sb->started = true;
		sb->next_uptime_s = uptime_s;
	}
	if (uptime_s < sb->next_uptime_s) {
		return; /* duplicate or out of order: keep the first label */
	}
	/* mark skipped seconds as "no data" (bounded by the ring size) */
	uint32_t gap = uptime_s - sb->next_uptime_s;

	if (gap > SB_RING_S) {
		gap = SB_RING_S;
	}
	for (uint32_t k = gap; k > 0; k--) {
		sb->ring[(uptime_s - k) % SB_RING_S] = SB_LABEL_NONE;
	}
	sb->ring[uptime_s % SB_RING_S] = label;
	sb->next_uptime_s = uptime_s + 1;
}

void sb_set_clock(struct summary_builder *sb, uint32_t epoch_s, uint32_t uptime_s)
{
	sb->epoch_minus_uptime = (int64_t)epoch_s - (int64_t)uptime_s;
	sb->clock_set = true;
}

void sb_encode(uint8_t out[SB_RECORD_SIZE], uint32_t minute_ts, const uint8_t seconds[7],
	       uint8_t unknown_s, uint8_t battery_pct, uint8_t flags)
{
	out[0] = 1; /* version (ADR 0001) */
	out[1] = (uint8_t)(minute_ts & 0xFF);
	out[2] = (uint8_t)((minute_ts >> 8) & 0xFF);
	out[3] = (uint8_t)((minute_ts >> 16) & 0xFF);
	out[4] = (uint8_t)((minute_ts >> 24) & 0xFF);
	memcpy(&out[5], seconds, 7);
	out[12] = unknown_s;
	out[13] = battery_pct;
	out[14] = flags;
}

int sb_flush(struct summary_builder *sb, uint32_t now_uptime_s, sb_emit_fn emit, void *user)
{
	if (!sb->clock_set || !sb->started) {
		return 0;
	}
	/* oldest uptime second still in the ring */
	uint32_t newest = sb->next_uptime_s; /* exclusive */
	uint32_t oldest = newest > SB_RING_S ? newest - SB_RING_S : 0;
	int64_t now_epoch = (int64_t)now_uptime_s + sb->epoch_minus_uptime;
	int64_t first_minute = ((int64_t)oldest + sb->epoch_minus_uptime) / 60 * 60;

	if (sb->last_emitted_minute && first_minute <= sb->last_emitted_minute) {
		first_minute = (int64_t)sb->last_emitted_minute + 60;
	}

	int emitted = 0;

	/* a minute is complete once the clock has passed its end */
	for (int64_t m = first_minute; m + 60 <= now_epoch; m += 60) {
		uint8_t secs[7] = {0};
		uint8_t unknown = 0;
		int observed = 0;

		for (int s = 0; s < 60; s++) {
			int64_t up = m + s - sb->epoch_minus_uptime;

			if (up < (int64_t)oldest || up >= (int64_t)newest) {
				continue;
			}
			uint8_t label = sb->ring[(uint32_t)up % SB_RING_S];

			if (label == SB_LABEL_NONE) {
				continue;
			}
			observed++;
			if (label < 7) {
				secs[label]++;
			} else {
				unknown++;
			}
		}
		if (observed > 0 && m > 0 && m <= UINT32_MAX) {
			uint8_t rec[SB_RECORD_SIZE];

			sb_encode(rec, (uint32_t)m, secs, unknown, sb->battery_pct, sb->flags);
			emit(rec, user);
			emitted++;
		}
		sb->last_emitted_minute = (uint32_t)m;
	}
	return emitted;
}
