#include "preprocess.h"

#include <math.h>
#include <string.h>

static int8_t quantize(float x, float scale, int32_t zero_point)
{
	float q = roundf(x / scale) + (float)zero_point;

	if (q > 127.0f) {
		return 127;
	}
	if (q < -128.0f) {
		return -128;
	}
	return (int8_t)q;
}

void preprocess_window(const int16_t *raw, int n, int8_t *out,
		       const struct preprocess_params *p)
{
	const float ka = p->accel_fs_g / 32768.0f;
	const float kg = p->gyro_fs_dps / 32768.0f;

	for (int i = 0; i < n; i++) {
		const int16_t *s = &raw[i * PRE_RAW_CH];
		int8_t *o = &out[i * PRE_MODEL_CH];
		float phys[PRE_MODEL_CH];

		for (int c = 0; c < 3; c++) {
			phys[c] = (float)s[c] * ka;
			phys[3 + c] = (float)s[3 + c] * kg;
		}
		phys[6] = sqrtf(phys[0] * phys[0] + phys[1] * phys[1] + phys[2] * phys[2]);

		for (int c = 0; c < PRE_MODEL_CH; c++) {
			o[c] = quantize(phys[c] / p->ch_scale[c], p->in_scale, p->in_zero_point);
		}
	}
}

void ring_init(struct sample_ring *r)
{
	memset(r, 0, sizeof(*r));
}

void ring_push(struct sample_ring *r, const int16_t sample[PRE_RAW_CH])
{
	memcpy(r->s[r->head], sample, sizeof(r->s[0]));
	r->head = (r->head + 1) % PRE_WINDOW;
	if (r->count < PRE_WINDOW) {
		r->count++;
	}
}

bool ring_full(const struct sample_ring *r)
{
	return r->count == PRE_WINDOW;
}

void ring_copy(const struct sample_ring *r, int16_t *out)
{
	/* when full, the oldest sample is at head */
	int start = ring_full(r) ? r->head : 0;

	for (int i = 0; i < r->count; i++) {
		memcpy(&out[i * PRE_RAW_CH], r->s[(start + i) % PRE_WINDOW], sizeof(r->s[0]));
	}
}
