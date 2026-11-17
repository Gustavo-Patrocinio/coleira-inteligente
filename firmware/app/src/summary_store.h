/* Per-minute summary records in flash (FCB on the storage partition, ADR 0013). */
#ifndef COLLAR_SUMMARY_STORE_H_
#define COLLAR_SUMMARY_STORE_H_

#include <stdint.h>

#include "summary_builder.h"

struct store_stats {
	uint32_t count;
	uint32_t oldest_minute_ts;
	uint32_t newest_minute_ts;
};

int store_init(void);

/* Appends one record; drops the oldest sector when full. */
int store_append(const uint8_t record[SB_RECORD_SIZE]);

/* Calls `cb` for every stored record with minute_ts ≥ since (oldest first). If `cb` returns
 * non-zero the walk stops. Returns the number of records passed to `cb`. */
int store_walk_since(uint32_t since_minute_ts,
		     int (*cb)(const uint8_t record[SB_RECORD_SIZE], void *user), void *user);

struct store_stats store_stats(void);

#endif /* COLLAR_SUMMARY_STORE_H_ */
