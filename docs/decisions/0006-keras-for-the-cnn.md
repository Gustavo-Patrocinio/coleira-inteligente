# ADR 0006: Keras/TensorFlow (not PyTorch) for the embedded CNN

- **Status:** accepted
- **Date:** 2026-11-16
- **Affects:** section 5 (ML stack)

## Context

The CNN targets **TFLite Micro** on the nRF52840, in int8. The plan was to train in
PyTorch and convert. PyTorch → TFLite int8 conversion goes through chains such as
PyTorch → ONNX → TF (`onnx2tf`) or `ai-edge-torch`. The first often breaks on details
(NCHW/NHWC layout, unsupported operators); the second has no official Windows support,
and Windows is the development environment.

## Decision

Train the CNN in **Keras 3 on TensorFlow** and convert it with the native
`TFLiteConverter` (full int8 quantization with a representative dataset). scikit-learn
stays for the baselines.

## Alternatives

- **PyTorch + onnx2tf:** an ecosystem many people prefer, but it adds a fragile link
  exactly at the step that goes to the chip.
- **PyTorch + ai-edge-torch:** Google's official path, but no Windows support (would need WSL).

## Consequences

A heavy dependency (`tensorflow`, ~400 MB) in the ML environment. The CNN is small
(3 convolutional layers), so switching frameworks later would be cheap: architecture
and data live in `coleira_ml` and do not depend on the framework. The full path
(Keras export → int8 conversion → int8 inference for evaluation) was verified on Windows,
with no accuracy loss from quantization.
