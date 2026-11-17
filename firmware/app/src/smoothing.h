/*
 * Temporal smoothing of per-window class probabilities (ADR 0002).
 *
 * - State classes (still, walking, running, eating, drinking): majority vote over the
 *   last `majority_len` windows of the most likely state class (ties → most recent).
 * - Event classes (scratching, shaking): an event is active when its probability has been
 *   ≥ p_event for ≥ n_min consecutive windows. An active event overrides the state; if two
 *   are active, the one with the higher probability wins.
 *
 * Pure C, no Zephyr dependencies, so it also builds and runs on a PC (host test).
 */
#ifndef COLLAR_SMOOTHING_H_
#define COLLAR_SMOOTHING_H_

#include <stdint.h>

#define SMOOTH_MAX_CLASSES  8
#define SMOOTH_MAX_MAJORITY 9
#define SMOOTH_UNKNOWN      255

struct smooth_cfg {
	uint8_t n_classes;
	uint8_t class_id[SMOOTH_MAX_CLASSES];    /* contract 4.1 ID of each model output */
	uint8_t event_n_min[SMOOTH_MAX_CLASSES]; /* 0 = state class; ≥ 1 = event class */
	float p_event;
	uint8_t majority_len;                    /* ≤ SMOOTH_MAX_MAJORITY */
};

struct smooth_state {
	uint8_t hist[SMOOTH_MAX_MAJORITY]; /* recent state-class output indices */
	uint8_t hist_count;
	uint8_t hist_pos;
	uint8_t run[SMOOTH_MAX_CLASSES];   /* consecutive windows ≥ p_event, per event class */
};

void smooth_init(struct smooth_state *s);

/* One window in, one contract class ID out (SMOOTH_UNKNOWN if there is no state class). */
uint8_t smooth_step(const struct smooth_cfg *cfg, struct smooth_state *s, const float *probs);

#endif /* COLLAR_SMOOTHING_H_ */
