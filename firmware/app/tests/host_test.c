/*
 * Host test for the firmware's pure-C logic (no Zephyr): compiled and driven by
 * ml/tests/test_firmware_host.py with a PC C compiler (zig cc).
 *
 *   host_test smoothing            → runs the smoothing checks, exit code 0 = pass
 *   host_test ring                 → runs the ring buffer checks
 *   host_test preprocess IN OUT N  → IN: N×6 int16 raw samples, OUT: N×7 int8 model input,
 *                                    using the constants in model/model_config.h
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../src/model/model_config.h"
#include "../src/preprocess.h"
#include "../src/smoothing.h"

static int failures;

#define CHECK(cond)                                                                    \
	do {                                                                           \
		if (!(cond)) {                                                         \
			fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);  \
			failures++;                                                    \
		}                                                                      \
	} while (0)

/* Classes in model order: still(0) walking(1) scratching(3) shaking(4) */
static struct smooth_cfg cfg(void)
{
	struct smooth_cfg c = {.n_classes = 4, .p_event = 0.6f, .majority_len = 5};
	const uint8_t ids[] = {0, 1, 3, 4};
	const uint8_t nmin[] = {0, 0, 2, 1};

	memcpy(c.class_id, ids, sizeof(ids));
	memcpy(c.event_n_min, nmin, sizeof(nmin));
	return c;
}

static uint8_t step(const struct smooth_cfg *c, struct smooth_state *s, float p0, float p1,
		    float p3, float p4)
{
	float p[4] = {p0, p1, p3, p4};

	return smooth_step(c, s, p);
}

static void test_smoothing(void)
{
	struct smooth_cfg c = cfg();
	struct smooth_state s;

	/* majority over the last 5 state decisions */
	smooth_init(&s);
	CHECK(step(&c, &s, 0.2f, 0.8f, 0, 0) == 1);
	CHECK(step(&c, &s, 0.2f, 0.8f, 0, 0) == 1);
	CHECK(step(&c, &s, 0.9f, 0.1f, 0, 0) == 1); /* 2 walking vs 1 still */
	CHECK(step(&c, &s, 0.9f, 0.1f, 0, 0) == 0); /* tie 2–2 → most recent (still) */
	CHECK(step(&c, &s, 0.9f, 0.1f, 0, 0) == 0);

	/* the window slides: after 5 still, three walking are needed to flip */
	smooth_init(&s);
	for (int i = 0; i < 5; i++) {
		step(&c, &s, 0.9f, 0.1f, 0, 0);
	}
	CHECK(step(&c, &s, 0.1f, 0.9f, 0, 0) == 0);
	CHECK(step(&c, &s, 0.1f, 0.9f, 0, 0) == 0);
	CHECK(step(&c, &s, 0.1f, 0.9f, 0, 0) == 1);

	/* a single short shake (n_min = 1) shows up immediately and does not stick */
	smooth_init(&s);
	for (int i = 0; i < 5; i++) {
		step(&c, &s, 0.9f, 0.1f, 0, 0);
	}
	CHECK(step(&c, &s, 0.2f, 0.1f, 0.0f, 0.7f) == 4);
	CHECK(step(&c, &s, 0.9f, 0.1f, 0.0f, 0.0f) == 0);

	/* scratching needs 2 consecutive windows ≥ 0.6 */
	smooth_init(&s);
	CHECK(step(&c, &s, 0.3f, 0.0f, 0.7f, 0.0f) == 0);
	CHECK(step(&c, &s, 0.3f, 0.0f, 0.7f, 0.0f) == 3);
	CHECK(step(&c, &s, 0.3f, 0.0f, 0.5f, 0.0f) == 0); /* below threshold → back to state */
	CHECK(step(&c, &s, 0.3f, 0.0f, 0.7f, 0.0f) == 0); /* run restarted */

	/* two events active → higher probability wins */
	smooth_init(&s);
	step(&c, &s, 0.0f, 0.0f, 0.65f, 0.65f);
	CHECK(step(&c, &s, 0.0f, 0.0f, 0.62f, 0.9f) == 4);

	/* majority_len smaller than the history buffer, with wrap-around */
	c.majority_len = 3;
	smooth_init(&s);
	for (int i = 0; i < 7; i++) {
		step(&c, &s, 0.1f, 0.9f, 0, 0);
	}
	CHECK(step(&c, &s, 0.9f, 0.1f, 0, 0) == 1);
	CHECK(step(&c, &s, 0.9f, 0.1f, 0, 0) == 0);
}

static void test_ring(void)
{
	static struct sample_ring r;
	static int16_t out[PRE_WINDOW * PRE_RAW_CH];
	int16_t s[PRE_RAW_CH];

	ring_init(&r);
	for (int i = 0; i < PRE_WINDOW + 37; i++) {
		for (int c = 0; c < PRE_RAW_CH; c++) {
			s[c] = (int16_t)(i * 10 + c);
		}
		ring_push(&r, s);
		CHECK(ring_full(&r) == (i + 1 >= PRE_WINDOW));
	}
	ring_copy(&r, out);
	/* oldest kept sample is #37, newest is #136 */
	CHECK(out[0] == 370);
	CHECK(out[5] == 375);
	CHECK(out[(PRE_WINDOW - 1) * PRE_RAW_CH] == 1360);
}

static int run_preprocess(const char *in_path, const char *out_path, int n)
{
	const struct preprocess_params p = {
		.accel_fs_g = MODEL_ACCEL_FS_G,
		.gyro_fs_dps = MODEL_GYRO_FS_DPS,
		.ch_scale = MODEL_CH_SCALE,
		.in_scale = MODEL_IN_SCALE,
		.in_zero_point = MODEL_IN_ZERO_POINT,
	};
	int16_t *raw = malloc(sizeof(int16_t) * n * PRE_RAW_CH);
	int8_t *q = malloc((size_t)n * PRE_MODEL_CH);
	FILE *f = fopen(in_path, "rb");

	if (!raw || !q || !f || fread(raw, sizeof(int16_t), n * PRE_RAW_CH, f) != (size_t)n * 6) {
		fprintf(stderr, "cannot read %s\n", in_path);
		return 2;
	}
	fclose(f);
	preprocess_window(raw, n, q, &p);
	f = fopen(out_path, "wb");
	if (!f || fwrite(q, 1, (size_t)n * PRE_MODEL_CH, f) != (size_t)n * PRE_MODEL_CH) {
		return 2;
	}
	fclose(f);
	free(raw);
	free(q);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc >= 2 && strcmp(argv[1], "smoothing") == 0) {
		test_smoothing();
	} else if (argc >= 2 && strcmp(argv[1], "ring") == 0) {
		test_ring();
	} else if (argc == 5 && strcmp(argv[1], "preprocess") == 0) {
		return run_preprocess(argv[2], argv[3], atoi(argv[4]));
	} else {
		fprintf(stderr, "usage: host_test smoothing|ring|preprocess IN OUT N\n");
		return 2;
	}
	if (failures) {
		fprintf(stderr, "%d check(s) failed\n", failures);
		return 1;
	}
	printf("ok\n");
	return 0;
}
