/*
 * Collar app, Phase 2: behavior classification on the chip (still on USB).
 *
 *   sampler thread:   20 ms timer → IMU → ring buffer of the last 2 s;
 *                     every 50 samples (1 s) hands a copy of the window to inference
 *   inference thread: preprocess (int8) → CNN (TFLite Micro) → smoothing (ADR 0002)
 *                     → one line per second on the log, plus a per-minute summary
 *
 * Phase 3: each smoothed second also feeds the per-minute summary (contract 4.7), stored in
 * flash and served over the BLE sync service (contract 4.8, ADR 0013).
 */
#include <string.h>

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/timing/timing.h>

#include "ble_sync.h"
#include "imu.h"
#include "model/model_config.h"
#include "model_runner.h"
#include "preprocess.h"
#include "smoothing.h"
#include "summary_builder.h"
#include "summary_store.h"

LOG_MODULE_REGISTER(app, LOG_LEVEL_INF);

BUILD_ASSERT(MODEL_WINDOW == PRE_WINDOW, "model window must match the preprocessing window");
BUILD_ASSERT(MODEL_CHANNELS == PRE_MODEL_CH, "model channels must match preprocessing");
BUILD_ASSERT(MODEL_N_CLASSES <= SMOOTH_MAX_CLASSES, "too many classes for the smoother");

#define SAMPLE_PERIOD K_MSEC(20)
#define STEP_SAMPLES  50 /* 1 s step, 50% overlap (contract 4.3) */

static const uint8_t class_ids[] = MODEL_CLASS_IDS;
static const char *const class_names[] = MODEL_CLASS_NAMES;

/* Double buffer: the sampler fills `pending` while inference works on its own copy. */
static int16_t pending[PRE_WINDOW * PRE_RAW_CH];
static uint32_t pending_t_ms;
K_SEM_DEFINE(window_ready, 0, 1);
K_MUTEX_DEFINE(window_lock);

/* Per-minute summary (Phase 3, ADR 0013): one smoothed label per second goes in, records
 * aligned to epoch minutes go to flash. The BT thread sets the clock, so guard it. */
static struct summary_builder summary;
K_MUTEX_DEFINE(summary_lock);
#define FLAG_BATTERY_NOT_MEASURED 0x01 /* until the fuel gauge (Phase 5) */

static void store_record(const uint8_t record[SB_RECORD_SIZE], void *user)
{
	ARG_UNUSED(user);
	if (store_append(record) != 0) {
		LOG_WRN("could not store a summary record");
	}
}

static void on_time(uint32_t epoch_s)
{
	k_mutex_lock(&summary_lock, K_FOREVER);
	sb_set_clock(&summary, epoch_s, k_uptime_get_32() / 1000U);
	k_mutex_unlock(&summary_lock);
	ble_sync_set_state(0, true);
}

static const char *name_of(uint8_t id)
{
	for (int i = 0; i < MODEL_N_CLASSES; i++) {
		if (class_ids[i] == id) {
			return class_names[i];
		}
	}
	return id == SMOOTH_UNKNOWN ? "unknown" : "?";
}

static void sampler_thread(void *a, void *b, void *c)
{
	ARG_UNUSED(a);
	ARG_UNUSED(b);
	ARG_UNUSED(c);

	static struct sample_ring ring;
	struct k_timer timer;
	struct imu_sample s;
	int since_step = 0;

	ring_init(&ring);
	k_timer_init(&timer, NULL, NULL);
	k_timer_start(&timer, SAMPLE_PERIOD, SAMPLE_PERIOD);

	for (;;) {
		k_timer_status_sync(&timer);
		if (imu_read(&s) != 0) {
			continue; /* keep the previous samples; rare I2C hiccups */
		}
		ring_push(&ring, s.v);
		if (ring_full(&ring) && ++since_step >= STEP_SAMPLES) {
			since_step = 0;
			k_mutex_lock(&window_lock, K_FOREVER);
			ring_copy(&ring, pending);
			pending_t_ms = k_uptime_get_32();
			k_mutex_unlock(&window_lock);
			k_sem_give(&window_ready); /* if inference is still busy, this window is skipped */
		}
	}
}

static void inference_thread(void *a, void *b, void *c)
{
	ARG_UNUSED(a);
	ARG_UNUSED(b);
	ARG_UNUSED(c);

	static int16_t window[PRE_WINDOW * PRE_RAW_CH];
	static const struct preprocess_params pp = {
		.accel_fs_g = MODEL_ACCEL_FS_G,
		.gyro_fs_dps = MODEL_GYRO_FS_DPS,
		.ch_scale = MODEL_CH_SCALE,
		.in_scale = MODEL_IN_SCALE,
		.in_zero_point = MODEL_IN_ZERO_POINT,
	};
	struct smooth_cfg sc = {
		.n_classes = MODEL_N_CLASSES,
		.p_event = 0.6f,  /* ADR 0002 initial values; calibrate in Phase 2 */
		.majority_len = 5,
	};
	struct smooth_state ss;
	uint16_t seconds[256] = {0};
	uint32_t windows = 0;
	uint32_t worst_us = 0;

	for (int i = 0; i < MODEL_N_CLASSES; i++) {
		sc.class_id[i] = class_ids[i];
		sc.event_n_min[i] = class_ids[i] == 4 ? 1 : class_ids[i] == 3 ? 2 : 0;
	}
	smooth_init(&ss);
	timing_init();
	timing_start();

	for (;;) {
		uint32_t t_ms;
		float probs[MODEL_N_CLASSES];

		k_sem_take(&window_ready, K_FOREVER);
		k_mutex_lock(&window_lock, K_FOREVER);
		memcpy(window, pending, sizeof(window));
		t_ms = pending_t_ms;
		k_mutex_unlock(&window_lock);

		timing_t t0 = timing_counter_get();

		preprocess_window(window, PRE_WINDOW, model_input(), &pp);
		if (model_invoke(probs) != 0) {
			LOG_ERR("inference failed");
			continue;
		}
		timing_t t1 = timing_counter_get();
		uint32_t us = (uint32_t)(timing_cycles_to_ns(timing_cycles_get(&t0, &t1)) / 1000U);

		worst_us = MAX(worst_us, us);

		int top = 0;

		for (int i = 1; i < MODEL_N_CLASSES; i++) {
			if (probs[i] > probs[top]) {
				top = i;
			}
		}
		uint8_t out = smooth_step(&sc, &ss, probs);

		k_mutex_lock(&summary_lock, K_FOREVER);
		sb_add(&summary, t_ms / 1000U, out);
		sb_flush(&summary, k_uptime_get_32() / 1000U, store_record, NULL);
		k_mutex_unlock(&summary_lock);

		seconds[out]++;
		windows++;
		LOG_INF("t=%u.%03us raw=%s(%d%%) out=%s  %u.%03u ms", t_ms / 1000, t_ms % 1000,
			class_names[top], (int)(probs[top] * 100.0f + 0.5f), name_of(out), us / 1000,
			us % 1000);

		if (windows % 60 == 0) { /* preview of the Phase 3 per-minute summary */
			LOG_INF("--- minute: still=%us walking=%us running=%us shaking=%us unknown=%us",
				seconds[0], seconds[1], seconds[2], seconds[4], seconds[SMOOTH_UNKNOWN]);
			LOG_INF("--- inference worst %u.%03u ms, arena %u/%u bytes", worst_us / 1000,
				worst_us % 1000, (unsigned)model_arena_used(),
				(unsigned)model_arena_size());
			memset(seconds, 0, sizeof(seconds));
		}
	}
}

/* Not started automatically: main() starts them only after the IMU and model are ready. */
K_THREAD_DEFINE(sampler, 1536, sampler_thread, NULL, NULL, NULL, 3, 0, SYS_FOREVER_MS);
K_THREAD_DEFINE(inference, 4096, inference_thread, NULL, NULL, NULL, 6, 0, SYS_FOREVER_MS);

int main(void)
{
	int err = imu_init();

	if (err) {
		LOG_ERR("IMU init failed (%d)", err);
		return err;
	}
	sb_init(&summary);
	summary.flags = FLAG_BATTERY_NOT_MEASURED;
	err = store_init();
	if (err) {
		LOG_ERR("summary storage failed (%d)", err);
		return err;
	}
	err = ble_sync_init(on_time);
	if (err) {
		LOG_ERR("bluetooth failed (%d)", err);
		return err;
	}
	err = model_init();
	if (err) {
		LOG_ERR("model init failed (%d); arena %u bytes may be too small", err,
			(unsigned)model_arena_size());
		return err;
	}
	LOG_INF("model ready: %d classes, arena used %u of %u bytes", MODEL_N_CLASSES,
		(unsigned)model_arena_used(), (unsigned)model_arena_size());
	k_thread_start(inference);
	k_thread_start(sampler);
	return 0;
}
