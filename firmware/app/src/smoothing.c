#include "smoothing.h"

#include <string.h>

void smooth_init(struct smooth_state *s)
{
	memset(s, 0, sizeof(*s));
}

static int majority(const struct smooth_cfg *cfg, const struct smooth_state *s)
{
	uint8_t counts[SMOOTH_MAX_CLASSES] = {0};
	int best = -1;
	int best_count = 0;

	for (int k = 0; k < s->hist_count; k++) {
		counts[s->hist[k]]++;
	}
	/* walk from the newest entry back, so ties go to the most recent class */
	for (int k = 0; k < s->hist_count; k++) {
		int len = cfg->majority_len;
		int idx = (((s->hist_pos - 1 - k) % len) + len) % len;
		int c = s->hist[idx];

		if (counts[c] > best_count) {
			best = c;
			best_count = counts[c];
		}
	}
	return best;
}

uint8_t smooth_step(const struct smooth_cfg *cfg, struct smooth_state *s, const float *probs)
{
	int best_state = -1;
	int best_event = -1;

	for (int i = 0; i < cfg->n_classes; i++) {
		if (cfg->event_n_min[i] == 0) {
			if (best_state < 0 || probs[i] > probs[best_state]) {
				best_state = i;
			}
			continue;
		}
		if (probs[i] >= cfg->p_event) {
			if (s->run[i] < UINT8_MAX) {
				s->run[i]++;
			}
		} else {
			s->run[i] = 0;
		}
		if (s->run[i] >= cfg->event_n_min[i] &&
		    (best_event < 0 || probs[i] > probs[best_event])) {
			best_event = i;
		}
	}

	/* the state history keeps running during events, so the state resumes smoothly */
	if (best_state >= 0) {
		s->hist[s->hist_pos] = (uint8_t)best_state;
		s->hist_pos = (uint8_t)((s->hist_pos + 1) % cfg->majority_len);
		if (s->hist_count < cfg->majority_len) {
			s->hist_count++;
		}
	}

	if (best_event >= 0) {
		return cfg->class_id[best_event];
	}
	int m = majority(cfg, s);

	return m < 0 ? SMOOTH_UNKNOWN : cfg->class_id[m];
}
