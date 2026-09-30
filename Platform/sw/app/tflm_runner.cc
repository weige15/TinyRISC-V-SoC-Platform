#include "tflm_runner.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "model_data.h"
#include "model_io.h"
#include "perf.h"
#include "platform_config.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/micro/micro_profiler_interface.h"
#include "tensorflow/lite/schema/schema_generated.h"
#include "tflm_ops.h"

#ifndef TENSOR_ARENA_SIZE
#define TENSOR_ARENA_SIZE PLATFORM_DEFAULT_TENSOR_ARENA_SIZE
#endif

#ifndef MODEL_NAME
#define MODEL_NAME "unknown"
#endif

namespace {

constexpr size_t kOutputWordCount = 12;
alignas(16) uint8_t tensor_arena[TENSOR_ARENA_SIZE];

void print_output_data(const TfLiteTensor* output) {
  if (output->type != kTfLiteFloat32 ||
      output->bytes != kOutputWordCount * sizeof(uint32_t)) {
    printf("Output Data unavailable: expected 12 float32 words, got type=%d, bytes=%u.\n",
           output->type, (unsigned)output->bytes);
    return;
  }

  puts("Output Data:");
  for (size_t i = 0; i < kOutputWordCount; ++i) {
    uint32_t word;
    memcpy(&word, &output->data.f[i], sizeof(word));
    printf("%-8u : 0x%08x\n", (unsigned)i, (unsigned)word);
  }
}

#if defined(TFLM_OPERATOR_CYCLE_PROFILE)
// Per-operator cycle profiler. TFLM calls BeginEvent/EndEvent around every
// node's invoke; each event records the node's mcycle delta. Enabled only in
// builds with -DTFLM_OPERATOR_CYCLE_PROFILE (APP_DEFINES) so the headline
// Invoke() measurement of a normal build contains no profiling.
class OperatorCycleProfiler : public tflite::MicroProfilerInterface {
 public:
  static constexpr uint32_t kMaxEvents = 64;

  uint32_t BeginEvent(const char* tag) override {
    if (event_count_ >= kMaxEvents) {
      ++dropped_events_;
      return kMaxEvents;
    }
    const uint32_t handle = event_count_++;
    tags_[handle] = tag;
    cycles_[handle] = 0;
    start_cycles_[handle] = perf_get_mcycle64();
    return handle;
  }

  void EndEvent(uint32_t event_handle) override {
    const uint64_t end = perf_get_mcycle64();
    if (event_handle < kMaxEvents) {
      cycles_[event_handle] = end - start_cycles_[event_handle];
      // Live progress line, printed after this node's cycles were captured.
      printf("  node %3u %-20s ", (unsigned)event_handle, tags_[event_handle]);
      PrintCyclesRightAligned(cycles_[event_handle], 14);
      putchar('\n');
    }
  }

  void Reset() {
    event_count_ = 0;
    dropped_events_ = 0;
  }

  void PrintPerNodeCycles() const {
    puts("Per-node cycles (execution order):");
    puts("  node  operator              cycles");
    for (uint32_t i = 0; i < event_count_; ++i) {
      printf("  %4u  %-20s  ", (unsigned)i, tags_[i]);
      PrintCyclesRightAligned(cycles_[i], 14);
      putchar('\n');
    }
  }

  void PrintPerOperatorTable(uint64_t invoke_cycles) const {
    const char* op_names[kMaxEvents];
    uint32_t op_counts[kMaxEvents];
    uint64_t op_cycles[kMaxEvents];
    uint32_t op_count = 0;
    uint64_t profiled_total = 0;
    for (uint32_t i = 0; i < event_count_; ++i) {
      uint32_t op = 0;
      while (op < op_count && strcmp(op_names[op], tags_[i]) != 0) ++op;
      if (op == op_count) {
        op_names[op] = tags_[i];
        op_counts[op] = 0;
        op_cycles[op] = 0;
        ++op_count;
      }
      ++op_counts[op];
      op_cycles[op] += cycles_[i];
      profiled_total += cycles_[i];
    }

    puts("Per-operator cycles (sum over nodes of each operator type):");
    puts("  operator              nodes          cycles   share");
    for (uint32_t op = 0; op < op_count; ++op) {
      printf("  %-20s  %5u  ", op_names[op], (unsigned)op_counts[op]);
      PrintCyclesRightAligned(op_cycles[op], 14);
      PrintPercent(op_cycles[op], invoke_cycles);
      putchar('\n');
    }
    printf("  %-20s  %5u  ", "(sum of operators)", (unsigned)event_count_);
    PrintCyclesRightAligned(profiled_total, 14);
    PrintPercent(profiled_total, invoke_cycles);
    putchar('\n');
    printf("  %-20s         ", "(Invoke total)");
    PrintCyclesRightAligned(invoke_cycles, 14);
    putchar('\n');
    if (dropped_events_ != 0) {
      printf("  warning: %u events exceeded the profiler capacity\n",
             (unsigned)dropped_events_);
    }
  }

 private:
  static void PrintCyclesRightAligned(uint64_t cycles, int width) {
    char digits[24];
    int length = 0;
    do {
      digits[length++] = static_cast<char>('0' + (cycles % 10));
      cycles /= 10;
    } while (cycles != 0);
    for (int pad = length; pad < width; ++pad) putchar(' ');
    while (length > 0) putchar(digits[--length]);
  }

  static void PrintPercent(uint64_t part, uint64_t whole) {
    const uint32_t hundredths =
        whole == 0 ? 0 : static_cast<uint32_t>((part * 10000ULL) / whole);
    printf("  %3u.%02u%%", (unsigned)(hundredths / 100),
           (unsigned)(hundredths % 100));
  }

  const char* tags_[kMaxEvents];
  uint64_t start_cycles_[kMaxEvents];
  uint64_t cycles_[kMaxEvents];
  uint32_t event_count_ = 0;
  uint32_t dropped_events_ = 0;
};
#endif  // TFLM_OPERATOR_CYCLE_PROFILE

void print_duration(uint64_t cycles) {
  printf("Cycles: ");
  perf_print_cycles(cycles);
  putchar('\n');
  perf_print_time_ms(cycles);
}

}  // namespace

void tflm_run_inference(void) {
  printf("\n=== TFLM Functional Verification ===\n");
  printf("Model: %s (%d bytes)\n", MODEL_NAME, g_model_len);
#ifdef TFLM_SOFTWARE_CONV
  puts("Convolution path: software/reference (upstream TFLM ConvPerChannel)");
#else
  puts("Convolution path: accelerated NPU burst dot product (CONV_2D), "
       "channel-blocked int8 kernel (DEPTHWISE_CONV_2D)");
#endif
  printf("Tensor arena: %u bytes\n", (unsigned)sizeof(tensor_arena));
  model_io_print_profile();

  const tflite::Model* model = tflite::GetModel(g_model);
  if (model->version() != TFLITE_SCHEMA_VERSION) {
    printf("Model schema mismatch: got %d, expected %d\n", model->version(),
           TFLITE_SCHEMA_VERSION);
    return;
  }

  ProjectOpResolver resolver;
  tflm_register_project_ops(&resolver);

#if defined(TFLM_OPERATOR_CYCLE_PROFILE)
  puts("Per-operator cycle profiling: enabled (TFLM_OPERATOR_CYCLE_PROFILE)");
  // Constructed on the stack: this runtime does not run global constructors,
  // so a static object would have no valid vtable.
  OperatorCycleProfiler operator_cycle_profiler;
  tflite::MicroInterpreter interpreter(model, resolver, tensor_arena,
                                       sizeof(tensor_arena), nullptr,
                                       &operator_cycle_profiler);
#else
  tflite::MicroInterpreter interpreter(model, resolver, tensor_arena,
                                       sizeof(tensor_arena));
#endif
  const TfLiteStatus allocation_status = interpreter.AllocateTensors();
  if (allocation_status != kTfLiteOk) {
    printf("AllocateTensors failed: status=%d.\n", allocation_status);
    return;
  }
  puts("AllocateTensors: kTfLiteOk");

  TfLiteTensor* input = interpreter.input(0);
  TfLiteTensor* output = interpreter.output(0);
  if (input == 0 || output == 0) {
    printf("Model tensors are not available.\n");
    return;
  }

  const size_t sample_count = model_io_sample_count();
  uint64_t total_cycles = 0;
  for (size_t sample_index = 0; sample_index < sample_count; ++sample_index) {
    printf("\n--- Sample %u/%u ---\n", (unsigned)(sample_index + 1),
           (unsigned)sample_count);
    model_io_prepare_input(input, sample_index);

#if defined(TFLM_OPERATOR_CYCLE_PROFILE)
    operator_cycle_profiler.Reset();
#endif
    printf("Running inference...\n");
    uint64_t start_cycles = perf_get_mcycle64();
    TfLiteStatus status = interpreter.Invoke();
    uint64_t cycles = perf_get_mcycle64() - start_cycles;
    total_cycles += cycles;

    if (status != kTfLiteOk) {
      printf("Invoke failed: status=%d.\n", status);
      print_duration(cycles);
      return;
    }

    puts("Invoke status: kTfLiteOk");
    printf("Inference complete.\n");
    print_output_data(output);
    model_io_verify_output(output, sample_index);
    print_duration(cycles);
#if defined(TFLM_OPERATOR_CYCLE_PROFILE)
    operator_cycle_profiler.PrintPerNodeCycles();
    operator_cycle_profiler.PrintPerOperatorTable(cycles);
#endif
  }

  if (sample_count > 1) {
    printf("\nTotal for %u samples:\n", (unsigned)sample_count);
    print_duration(total_cycles);
  }
}
