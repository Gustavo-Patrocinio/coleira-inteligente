/* Thin C API over TensorFlow Lite Micro, so the rest of the firmware stays in C. */
#ifndef COLLAR_MODEL_RUNNER_H_
#define COLLAR_MODEL_RUNNER_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Loads the model, registers its operators and allocates the tensor arena. */
int model_init(void);

/* Pointer to the int8 input tensor [MODEL_WINDOW][MODEL_CHANNELS]. */
int8_t *model_input(void);

/* Runs one inference and writes dequantized class probabilities (MODEL_N_CLASSES). */
int model_invoke(float *probs);

/* Bytes of the tensor arena actually used (measured after allocation). */
size_t model_arena_used(void);
size_t model_arena_size(void);

#ifdef __cplusplus
}
#endif

#endif /* COLLAR_MODEL_RUNNER_H_ */
