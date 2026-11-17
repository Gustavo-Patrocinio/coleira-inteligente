#include "summary_store.h"

#include <errno.h>

#include <zephyr/fs/fcb.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/storage/flash_map.h>

LOG_MODULE_REGISTER(store, LOG_LEVEL_INF);

#define STORE_ID         FIXED_PARTITION_ID(storage_partition)
#define STORE_MAX_SECTORS 128
#define STORE_MAGIC      0xC01A5E01

static struct fcb fcb;
static struct flash_sector sectors[STORE_MAX_SECTORS];
static struct store_stats stats;
K_MUTEX_DEFINE(store_lock);

static uint32_t rec_ts(const uint8_t *r)
{
	return (uint32_t)r[1] | (uint32_t)r[2] << 8 | (uint32_t)r[3] << 16 | (uint32_t)r[4] << 24;
}

static int read_entry(struct fcb_entry_ctx *ctx, uint8_t rec[SB_RECORD_SIZE])
{
	if (ctx->loc.fe_data_len != SB_RECORD_SIZE) {
		return -EINVAL;
	}
	return flash_area_read(ctx->fap, FCB_ENTRY_FA_DATA_OFF(ctx->loc), rec, SB_RECORD_SIZE);
}

static int stats_cb(struct fcb_entry_ctx *ctx, void *arg)
{
	ARG_UNUSED(arg);
	uint8_t rec[SB_RECORD_SIZE];

	if (read_entry(ctx, rec) == 0) {
		uint32_t ts = rec_ts(rec);

		if (stats.count == 0 || ts < stats.oldest_minute_ts) {
			stats.oldest_minute_ts = ts;
		}
		if (ts > stats.newest_minute_ts) {
			stats.newest_minute_ts = ts;
		}
		stats.count++;
	}
	return 0;
}

int store_init(void)
{
	uint32_t cnt = STORE_MAX_SECTORS;
	int err = flash_area_get_sectors(STORE_ID, &cnt, sectors);

	if (err) {
		LOG_ERR("cannot read storage sectors (%d)", err);
		return err;
	}
	fcb.f_magic = STORE_MAGIC;
	fcb.f_version = 1;
	fcb.f_sector_cnt = (uint8_t)cnt;
	fcb.f_scratch_cnt = 1; /* one free sector so rotation never blocks appends */
	fcb.f_sectors = sectors;

	err = fcb_init(STORE_ID, &fcb);
	if (err) {
		LOG_WRN("storage unreadable (%d): erasing and starting over", err);
		const struct flash_area *fa;

		if (flash_area_open(STORE_ID, &fa) == 0) {
			flash_area_erase(fa, 0, fa->fa_size);
			flash_area_close(fa);
		}
		err = fcb_init(STORE_ID, &fcb);
		if (err) {
			return err;
		}
	}
	stats = (struct store_stats){0};
	fcb_walk(&fcb, NULL, stats_cb, NULL);
	LOG_INF("storage: %u sectors, %u records stored", cnt, stats.count);
	return 0;
}

int store_append(const uint8_t record[SB_RECORD_SIZE])
{
	struct fcb_entry loc;
	int err;

	k_mutex_lock(&store_lock, K_FOREVER);
	err = fcb_append(&fcb, SB_RECORD_SIZE, &loc);
	if (err == -ENOSPC) {
		/* full: drop the oldest sector (about one day / 13) and retry */
		fcb_rotate(&fcb);
		stats = (struct store_stats){0};
		fcb_walk(&fcb, NULL, stats_cb, NULL);
		err = fcb_append(&fcb, SB_RECORD_SIZE, &loc);
	}
	if (err == 0) {
		err = flash_area_write(fcb.fap, FCB_ENTRY_FA_DATA_OFF(loc), record, SB_RECORD_SIZE);
	}
	if (err == 0) {
		err = fcb_append_finish(&fcb, &loc);
	}
	if (err == 0) {
		uint32_t ts = rec_ts(record);

		if (stats.count == 0) {
			stats.oldest_minute_ts = ts;
		}
		stats.newest_minute_ts = MAX(stats.newest_minute_ts, ts);
		stats.count++;
	}
	k_mutex_unlock(&store_lock);
	return err;
}

struct walk_args {
	uint32_t since;
	int (*cb)(const uint8_t *rec, void *user);
	void *user;
	int passed;
};

static int walk_cb(struct fcb_entry_ctx *ctx, void *arg)
{
	struct walk_args *w = arg;
	uint8_t rec[SB_RECORD_SIZE];

	if (read_entry(ctx, rec) != 0 || rec_ts(rec) < w->since) {
		return 0;
	}
	w->passed++;
	return w->cb(rec, w->user);
}

int store_walk_since(uint32_t since_minute_ts,
		     int (*cb)(const uint8_t record[SB_RECORD_SIZE], void *user), void *user)
{
	struct walk_args w = {.since = since_minute_ts, .cb = cb, .user = user};

	k_mutex_lock(&store_lock, K_FOREVER);
	fcb_walk(&fcb, NULL, walk_cb, &w);
	k_mutex_unlock(&store_lock);
	return w.passed;
}

struct store_stats store_stats(void)
{
	return stats;
}
