#include "model_runner.h"

#include <tensorflow/lite/micro/micro_interpreter.h>
#include <tensorflow/lite/micro/micro_mutable_op_resolver.h>
#include <tensorflow/lite/schema/schema_generated.h>

#include "model/model_config.h"
#include "model/model_data.h"

namespace {

/* Sized from a measured arena_used_bytes() plus margin; model_init() fails loudly if a
 * new model needs more. */
constexpr size_t kArenaSize = CONFIG_COLLAR_TENSOR_ARENA_SIZE;
alignas(16) uint8_t arena[kArenaSize];

const tflite::Model *model;
tflite::MicroInterpreter *interpreter;
TfLiteTensor *input;
TfLiteTensor *output;

} // namespace

extern "C" int model_init(void)
{
	model = tflite::GetModel(g_model_data);
	if (model->version() != TFLITE_SCHEMA_VERSION) {
		return -1;
	}

	static tflite::MicroMutableOpResolver<MODEL_OP_COUNT> resolver;
	MODEL_REGISTER_OPS(resolver);

	static tflite::MicroInterpreter static_interpreter(model, resolver, arena, kArenaSize);
	interpreter = &static_interpreter;
	if (interpreter->AllocateTensors() != kTfLiteOk) {
		return -2;
	}

	input = interpreter->input(0);
	output = interpreter->output(0);
	if (input->type != kTfLiteInt8 || output->type != kTfLiteInt8) {
		return -3;
	}
	if (input->bytes != MODEL_WINDOW * MODEL_CHANNELS || output->bytes != MODEL_N_CLASSES) {
		return -4;
	}
	return 0;
}

extern "C" int8_t *model_input(void)
{
	return input->data.int8;
}

extern "C" int model_invoke(float *probs)
{
	if (interpreter->Invoke() != kTfLiteOk) {
		return -1;
	}
	for (int i = 0; i < MODEL_N_CLASSES; i++) {
		probs[i] = (output->data.int8[i] - MODEL_OUT_ZERO_POINT) * MODEL_OUT_SCALE;
	}
	return 0;
}

extern "C" size_t model_arena_used(void)
{
	return interpreter ? interpreter->arena_used_bytes() : 0;
}

extern "C" size_t model_arena_size(void)
{
	return kArenaSize;
}
