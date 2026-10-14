#ifndef OFFSET9_MODEL_H_
#define OFFSET9_MODEL_H_
#include <cstdint>
#include <map>
#include <vector>

// Counters shared with the broader convolution regression.
extern uint64_t hw_simd_mac_bytes;
extern std::map<uint32_t, uint64_t> hw_simd_mac_n_hist;
extern bool reuse_armed;
extern uint64_t reuse_hits, reuse_stale;
namespace offset9_model {
struct CommandTrace {
  uintptr_t a, b;
  uint32_t n;
  int offset;
};
// Disabled normally; routing tests enable this for exact split visitation.
extern bool capture_commands;
extern std::vector<CommandTrace> commands;
struct Stats {
  uint64_t set8 = 0, set9 = 0, computes = 0, fast_hits = 0, failures = 0;
  uint64_t arms = 0, disarms = 0;
  uint16_t configured_bits = 0, engine_bits = 0;
  int last_offset = 0;
  uint32_t last_n = 0;
  std::map<int, uint64_t> offset_calls;
};
extern Stats stats;
}
#endif
