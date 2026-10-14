# Platform/sw/project.mk
MODEL_DIR := models
MODEL_FILE := ds_cnn_stream_fe.tflite
MODEL_PROFILE := ds_cnn_stream_fe

TENSOR_ARENA_SIZE := 2000000

APP_EXTRA_SRCS += $(wildcard models/label/label*_board.cc)
