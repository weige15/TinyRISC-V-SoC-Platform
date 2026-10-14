// Model ONLY the custom-instruction boundary; link the REAL lab2_api.cc.
// No ConvParams, wide-offset side channel, replacement hw_simd_mac, or CPU
// correction is available here. Both SET variants feed the same 9-bit latch,
// engine latch, signed-10 sum and signed-17 product as NPU.v / product().
#include "offset9_model.h"
#include "lab2_api.h"
#include "cfu.h"
#include <cstdio>
#include <cstring>
#include <vector>

uint64_t hw_simd_mac_bytes = 0;
std::map<uint32_t, uint64_t> hw_simd_mac_n_hist;
bool reuse_armed = false;
uint64_t reuse_hits = 0, reuse_stale = 0;
namespace offset9_model {
Stats stats;
bool capture_commands = false;
std::vector<CommandTrace> commands;
}
namespace {
using offset9_model::stats;
uint32_t length_r = 0;
bool configured = false, reuse_valid = false, fc_enabled = false, fc_valid = false;
uintptr_t reuse_address = 0, fc_lo = 0, fc_hi = 0;
uint32_t reuse_length = 0;
std::vector<uint8_t> input_words, filter_words;

void check(bool ok, const char* what) {
  if (!ok) {
    ++stats.failures;
    if (stats.failures <= 20) std::printf("MODEL FAIL: %s\n", what);
  }
}
int signed_bits(uint32_t bits, unsigned width) {
  const uint32_t mask = (1u << width) - 1;
  bits &= mask;
  return (bits & (1u << (width - 1))) ? int(bits) - int(1u << width) : int(bits);
}
size_t cover(uintptr_t address, uint32_t n) { return (size_t(n) + (address & 3) + 3) / 4; }
}

uint32_t software_cfu_raw(uint32_t funct3, uint32_t funct7, CfuWord rs1, CfuWord rs2) {
  using offset9_model::stats;
  check(funct3 == 4, "unexpected funct3");
  if (funct7 == 0 || funct7 == 5) {
    check(!configured, "SET overwrote an unconsumed command");
    length_r = static_cast<uint32_t>(rs1);
    // NPU.v: SET8 {rs2[7],rs2[7:0]}; SET9 rs2[8:0]. No int8_t temporary.
    stats.configured_bits = funct7 == 0
        ? static_cast<uint16_t>((rs2 & 0xffu) | ((rs2 & 0x80u) << 1))
        : static_cast<uint16_t>(rs2 & 0x1ffu);
    if (funct7 == 0) ++stats.set8; else ++stats.set9;
    configured = true;
    return length_r;
  }
  if (funct7 == 3 || funct7 == 4) {
    check(!configured, "reuse command between SET and COMPUTE");
    reuse_armed = (rs1 & 1) != 0;
    fc_enabled = reuse_armed && funct7 == 4;
    reuse_valid = false; fc_valid = false;
    if (reuse_armed) ++stats.arms; else ++stats.disarms;
    return rs1 & 1;
  }
  if (funct7 == 2) return 0;
  check(funct7 == 1 && configured, "COMPUTE without SET or unknown command");
  if (funct7 != 1 || !configured) return 0;
  configured = false;
  // Like all three RTL start branches (stream, ptr1 reuse, filter-cache hit).
  stats.engine_bits = stats.configured_bits;
  const int off = signed_bits(stats.engine_bits, 9);
  stats.last_offset = off; stats.last_n = length_r;
  ++stats.computes; ++stats.offset_calls[off];
  if (offset9_model::capture_commands)
    offset9_model::commands.push_back({rs1, rs2, length_r, off});
  ++hw_simd_mac_cnt; ++hw_simd_mac_n_hist[length_r]; hw_simd_mac_bytes += length_r;
  if (length_r == 0) { reuse_valid = false; return 0; }

  const auto* a = reinterpret_cast<const uint8_t*>(rs1);
  const auto* b = reinterpret_cast<const uint8_t*>(rs2);
  const size_t a_words = cover(rs1, length_r), b_words = cover(rs2, length_r);
  const uintptr_t b_start = rs2 & ~uintptr_t(3), b_end = b_start + 4 * b_words;
  const bool hit = reuse_armed && reuse_valid && rs1 == reuse_address && length_r == reuse_length;
  const bool fast = fc_enabled && hit && fc_valid && b_start >= fc_lo && b_end <= fc_hi &&
                    (rs1 & 3) == (rs2 & 3);
  if (hit) {
    ++reuse_hits;
    a = input_words.data() + (rs1 & 3);
    if (std::memcmp(a, reinterpret_cast<const void*>(rs1), length_r)) ++reuse_stale;
  } else {
    reuse_valid = false;
    // Host test allocations have >=3 bytes of head/tail covering-word space.
    if (reuse_armed && a_words <= 1024) {
      const auto* first = reinterpret_cast<const uint8_t*>(rs1 & ~uintptr_t(3));
      input_words.assign(first, first + 4 * a_words);
      reuse_address = rs1; reuse_length = length_r; reuse_valid = true;
      a = input_words.data() + (rs1 & 3);
    }
  }
  if (fast) {
    ++stats.fast_hits;
    b = filter_words.data() + (rs2 - fc_lo);
  } else if (fc_enabled &&
             (!fc_valid || (b_start >= fc_lo && b_start <= fc_hi && b_end > fc_hi)) &&
             b_end - (fc_valid ? fc_lo : b_start) <= 32768 * 4) {
    if (!fc_valid) { fc_lo = b_start; fc_hi = b_start; filter_words.clear(); }
    filter_words.resize(b_end - fc_lo);
    std::memcpy(filter_words.data() + b_start - fc_lo,
                reinterpret_cast<const void*>(b_start), 4 * b_words);
    fc_hi = b_end; fc_valid = true;
  }

  uint32_t accumulator = 0;
  const unsigned lanes = fast ? 32 : 4;
  const size_t low = rs2 & 3;
  const size_t slots = ((length_r + low + lanes - 1) / lanes) * lanes;
  for (size_t pos = 0; pos < slots; ++pos) {
    if (pos < low || pos >= low + length_r) continue; // RTL lane_valid
    const size_t i = pos - low;
    const int x = signed_bits(static_cast<uint32_t>(signed_bits(a[i], 8) + off), 10);
    const int p = signed_bits(static_cast<uint32_t>(x * signed_bits(b[i], 8)), 17);
    accumulator += static_cast<uint32_t>(p);
  }
  return accumulator;
}
