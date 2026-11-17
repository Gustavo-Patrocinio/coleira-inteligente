# Collar app (Phase 2): on-chip behavior classification with TensorFlow Lite Micro.
#
# Needs the tflite-micro Zephyr module. In a west workspace from firmware/west.yml it is
# fetched automatically; with a standalone NCS install pass its path:
#   west build ... -- -DZEPHYR_EXTRA_MODULES=C:/ncs/extra/tflite-micro
cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(collar_app LANGUAGES C CXX)

set(COMMON ${CMAKE_CURRENT_SOURCE_DIR}/../common/src)

target_include_directories(app PRIVATE src ${COMMON})
target_sources(app PRIVATE
  src/main.c
  src/preprocess.c
  src/smoothing.c
  src/model_runner.cc
  src/model/model_data.c
  ${COMMON}/imu.c
)
