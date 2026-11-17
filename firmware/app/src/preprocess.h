/*
 * Window buffer and preprocessing: raw int16 IMU samples → the int8 tensor the CNN expects.
 *
 * Must match training exactly (ml/src/coleira_ml/cnn.py):
 *   physical = raw × full_scale / 32768        (g, dps)
 *   channels = ax, ay, az, gx, gy, gz, |a|     (|a| from the physical accel)
 *   x        = physical / ch_scale[c]          (cnn.INPUT_SCALE)
 *   q        = clamp(round(x / in_scale) + in_zero_point, -128, 127)
 * A host test compares this C code against the Python preprocessing.
 * Pure C, no Zephyr dependencies, so it also builds and runs on a PC.
 */
#ifndef COLLAR_PREPROCESS_H_
#define COLLAR_PREPROCESS_H_

#include <stdbool.h>
#include <stdint.h>

#define PRE_WINDOW   100 /* 2 s at 50 Hz (contract 4.3) */
#define PRE_RAW_CH   6
#define PRE_MODEL_CH 7

struct preprocess_params {
	float accel_fs_g;
	float gyro_fs_dps;
	float ch_scale[PRE_MODEL_CH];
	float in_scale;
	int32_t in_zero_point;
};

/* raw: [n][6] chronological; out: [n][7] model input. */
void preprocess_window(const int16_t *raw, int n, int8_t *out,
		       const struct preprocess_params *p);

/* Ring buffer holding the last PRE_WINDOW samples. */
struct sample_ring {
	int16_t s[PRE_WINDOW][PRE_RAW_CH];
	int head;  /* index where the next sample goes */
	int count; /* number of valid samples (≤ PRE_WINDOW) */
};

void ring_init(struct sample_ring *r);
void ring_push(struct sample_ring *r, const int16_t sample[PRE_RAW_CH]);
bool ring_full(const struct sample_ring *r);
/* Copies the window in chronological order (oldest first) into out[PRE_WINDOW][6]. */
void ring_copy(const struct sample_ring *r, int16_t *out);

#endif /* COLLAR_PREPROCESS_H_ */
