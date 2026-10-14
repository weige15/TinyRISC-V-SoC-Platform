# Software command timeout

The initial fresh `make -C Platform -j4 sw_build MODEL_FILE=ds_cnn_stream_fe.tflite MODEL_PROFILE=ds_cnn_stream_fe APP_DEFINES=` invocation exceeded the harness 240-second limit while compiling TFLM kernels. `sw_build.log` is preserved. Process inspection afterward found no remaining compiler or software make processes; no compiler error was reported in that log. Resume uses the same source tree/flags with two workers and does not clean/reuse an old image. Final exit, image identity and startup checks are recorded separately.
