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
#include "../src/summary_builder.h"

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

/* ------------------------------------------------------------------ summary builder */

struct sink {
	uint8_t rec[16][SB_RECORD_SIZE];
	int n;
};

static void collect(const uint8_t record[SB_RECORD_SIZE], void *user)
{
	struct sink *k = user;

	if (k->n < 16) {
		memcpy(k->rec[k->n], record, SB_RECORD_SIZE);
	}
	k->n++;
}

static uint32_t rec_ts(const uint8_t *r)
{
	return (uint32_t)r[1] | (uint32_t)r[2] << 8 | (uint32_t)r[3] << 16 | (uint32_t)r[4] << 24;
}

static int rec_total(const uint8_t *r)
{
	int t = r[12];

	for (int c = 0; c < 7; c++) {
		t += r[5 + c];
	}
	return t;
}

#define T0 1800000000u /* a minute-aligned epoch (2027-01-15) */

static void test_summary(void)
{
	static struct summary_builder sb;
	struct sink k = {0};

	/* clock known from the start, 30 s into a minute */
	sb_init(&sb);
	sb_set_battery(&sb, 77);
	sb_set_clock(&sb, T0 + 30, 0);
	for (uint32_t t = 0; t < 180; t++) {
		sb_add(&sb, t, t < 90 ? 1 /* walking */ : 0 /* still */);
	}
	CHECK(sb_flush(&sb, 180, collect, &k) == 3); /* the 4th minute is not complete yet */
	CHECK(k.n == 3);
	CHECK(k.rec[0][0] == 1);                  /* version */
	CHECK(rec_ts(k.rec[0]) == T0);            /* aligned to the epoch minute */
	CHECK(rec_total(k.rec[0]) == 30);         /* partial first minute */
	CHECK(k.rec[0][5 + 1] == 30);             /* walking */
	CHECK(rec_ts(k.rec[1]) == T0 + 60 && k.rec[1][5 + 1] == 60);
	CHECK(rec_ts(k.rec[2]) == T0 + 120 && k.rec[2][5 + 0] == 60);
	CHECK(k.rec[0][13] == 77);                /* battery */
	k.n = 0;
	CHECK(sb_flush(&sb, 180, collect, &k) == 0); /* never twice */

	/* clock arrives later: seconds kept in RAM are stamped retroactively */
	sb_init(&sb);
	for (uint32_t t = 1000; t < 1240; t++) {
		sb_add(&sb, t, t % 60 < 6 ? 4 /* shaking */ : SB_UNKNOWN);
	}
	CHECK(sb_flush(&sb, 1240, collect, &k) == 0); /* no clock yet */
	sb_set_clock(&sb, T0 + 240, 1240);            /* uptime 1000 = T0 */
	k.n = 0;
	CHECK(sb_flush(&sb, 1240, collect, &k) == 4);
	CHECK(rec_ts(k.rec[0]) == T0 && rec_ts(k.rec[3]) == T0 + 180);
	CHECK(k.rec[0][5 + 4] == 6 && k.rec[0][12] == 54); /* shaking 6 s, unknown 54 s */

	/* a clock correction does not re-emit stored minutes */
	sb_set_clock(&sb, T0 + 242, 1240);
	for (uint32_t t = 1240; t < 1320; t++) {
		sb_add(&sb, t, 0);
	}
	k.n = 0;
	sb_flush(&sb, 1320, collect, &k);
	CHECK(k.n >= 1);
	CHECK(rec_ts(k.rec[0]) == T0 + 240);
	CHECK(rec_total(k.rec[0]) <= 60);

	/* gaps: skipped seconds are "no data"; a minute with nothing yields no record */
	sb_init(&sb);
	sb_set_clock(&sb, T0, 0);
	sb_add(&sb, 0, 2);
	sb_add(&sb, 150, 2); /* nothing between 1 and 149 */
	k.n = 0;
	CHECK(sb_flush(&sb, 180, collect, &k) == 2); /* minute 0 (1 s) and minute 2 (1 s) */
	CHECK(rec_ts(k.rec[0]) == T0 && rec_total(k.rec[0]) == 1);
	CHECK(rec_ts(k.rec[1]) == T0 + 120 && rec_total(k.rec[1]) == 1);
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

/* smooth IN OUT N K P_EVENT MAJ IDS NMIN: N windows of K float32 probs in, N class IDs out.
 * IDS and NMIN are comma-separated (one per model output). Python parity check. */
static int parse_list(const char *s, uint8_t *out, int max)
{
	int n = 0;

	while (*s && n < max) {
		out[n++] = (uint8_t)strtol(s, (char **)&s, 10);
		if (*s == ',') {
			s++;
		}
	}
	return n;
}

static int run_smooth(char **a)
{
	FILE *fin = fopen(a[0], "rb");
	FILE *fout = fopen(a[1], "wb");
	int n = atoi(a[2]);
	struct smooth_cfg cfg = {0};
	struct smooth_state st;
	float probs[SMOOTH_MAX_CLASSES];

	if (!fin || !fout) {
		return 3;
	}
	cfg.n_classes = (uint8_t)atoi(a[3]);
	cfg.p_event = (float)atof(a[4]);
	cfg.majority_len = (uint8_t)atoi(a[5]);
	if (parse_list(a[6], cfg.class_id, SMOOTH_MAX_CLASSES) != cfg.n_classes ||
	    parse_list(a[7], cfg.event_n_min, SMOOTH_MAX_CLASSES) != cfg.n_classes) {
		return 4;
	}
	smooth_init(&st);
	for (int i = 0; i < n; i++) {
		if (fread(probs, sizeof(float), cfg.n_classes, fin) != cfg.n_classes) {
			return 5;
		}
		uint8_t c = smooth_step(&cfg, &st, probs);

		fwrite(&c, 1, 1, fout);
	}
	fclose(fin);
	fclose(fout);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc >= 2 && strcmp(argv[1], "smoothing") == 0) {
		test_smoothing();
	} else if (argc >= 2 && strcmp(argv[1], "ring") == 0) {
		test_ring();
	} else if (argc >= 2 && strcmp(argv[1], "summary") == 0) {
		test_summary();
	} else if (argc == 5 && strcmp(argv[1], "preprocess") == 0) {
		return run_preprocess(argv[2], argv[3], atoi(argv[4]));
	} else if (argc == 10 && strcmp(argv[1], "smooth") == 0) {
		return run_smooth(argv + 2);
	} else {
		fprintf(stderr, "usage: host_test smoothing|ring|summary | preprocess IN OUT N | smooth ...\n");
		return 2;
	}
	if (failures) {
		fprintf(stderr, "%d check(s) failed\n", failures);
		return 1;
	}
	printf("ok\n");
	return 0;
}
