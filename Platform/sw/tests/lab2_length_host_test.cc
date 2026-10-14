// Link the REAL project/lab2_api.cc, not a replacement hw_simd_mac.
// Only the custom-instruction boundary is modeled on a native host.
// The current API streams any N in one SET/COMPUTE pair. We test that call
// AND its 256-byte partition/recombination (legacy caller split contract).
#include "lab2_api.h"
#include "cfu.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <random>
#include <vector>

namespace {
constexpr uint32_t kChunk = 256;
constexpr uint32_t kMaxTestN = 70000;
uint64_t mismatches = 0, cases = 0, element_audits = 0, total_computes = 0;
uint32_t configured_n = 0;
int configured_offset = 0;
bool configured = false;
struct Trace {
  int8_t* a = nullptr;
  int8_t* b = nullptr;
  uint32_t n = 0;
  int offset = 0;
  uint32_t calls = 0, sets = 0;
  std::vector<unsigned> visits;
  std::vector<int> offsets;
} trace;

void check(bool ok, const char* message) {
  if (!ok) {
    ++mismatches;
    if (mismatches <= 20) std::printf("[FAIL] %s\n", message);
  }
}

// 64-bit unsplit oracle: modulo conversion occurs once, at the end.
int64_t reference_wide(const int8_t* a, const int8_t* b, int offset, uint32_t n) {
  int64_t sum = 0;
  for (uint32_t i = 0; i < n; ++i)
    sum += (int64_t{a[i]} + offset) * int64_t{b[i]};
  return sum;
}

void begin_trace(int8_t* a, int8_t* b, uint32_t n, int offset) {
  check(!configured, "previous SET was not consumed");
  trace = {a, b, n, offset, 0, 0, std::vector<unsigned>(n), std::vector<int>(n)};
}

void end_trace(uint32_t expected_calls) {
  check(trace.calls == expected_calls && trace.sets == expected_calls,
        "wrong number of SET/COMPUTE calls");
  check(!configured, "unconsumed SET");
  for (uint32_t i = 0; i < trace.n; ++i) {
    check(trace.visits[i] == 1, "element skipped or visited more than once");
    check(trace.offsets[i] == trace.offset, "element input_offset not applied exactly once");
    ++element_audits;
  }
}

uint32_t partitioned(int8_t* a, int8_t* b, int8_t offset, uint32_t n) {
  uint32_t sum = 0;  // defined wraparound, including the sum of signed chunks
  for (uint32_t done = 0; done < n;) {
    const uint32_t count = std::min(kChunk, n - done);
    sum += static_cast<uint32_t>(hw_simd_mac(a + done, b + done, offset, count));
    done += count;
  }
  return sum;
}

void run(int8_t* a, int8_t* b, int8_t offset, uint32_t n) {
  const auto expected = static_cast<uint32_t>(reference_wide(a, b, offset, n));
  const std::vector<int8_t> saved_a(a, a + n), saved_b(b, b + n);
  begin_trace(a, b, n, offset);
  const auto unsplit = static_cast<uint32_t>(hw_simd_mac(a, b, offset, n));
  end_trace(n ? 1 : 0);
  begin_trace(a, b, n, offset);
  const auto split = partitioned(a, b, offset, n);
  end_trace((n + kChunk - 1) / kChunk);
  check(unsplit == expected, "unsplit real API differs from reference");
  check(split == expected && split == unsplit, "split differs from unsplit reference/API");
  check(std::equal(saved_a.begin(), saved_a.end(), a) &&
        std::equal(saved_b.begin(), saved_b.end(), b), "API modified an operand");
  ++cases;
}
}  // namespace

// cfu.h's native seam preserves uintptr_t (no truncation of host pointers).
// Trace verifies both pointer progressions, bounds, per-element visitation,
// and the int8 offset actually configured by production code on EVERY call.
uint32_t software_cfu_raw(uint32_t funct3, uint32_t funct7, CfuWord rs1, CfuWord rs2) {
  check(funct3 == 4, "unexpected CFU funct3");
  if (funct7 == 0) {
    check(!configured, "SET overwrote a pending command");
    configured_n = static_cast<uint32_t>(rs1);
    const unsigned byte = static_cast<unsigned>(rs2 & 255);
    configured_offset = byte < 128 ? static_cast<int>(byte) : static_cast<int>(byte) - 256;
    configured = true;
    ++trace.sets;
    return configured_n;
  }
  check(funct7 == 1 && configured, "COMPUTE without SET or unexpected CFU funct7");
  if (funct7 != 1 || !configured) return 0;
  configured = false;
  ++trace.calls;
  ++total_computes;
  const auto p1 = reinterpret_cast<uintptr_t>(trace.a);
  const auto p2 = reinterpret_cast<uintptr_t>(trace.b);
  const bool in_range = rs1 >= p1 && rs2 >= p2 && rs1-p1 <= trace.n &&
                        rs2-p2 == rs1-p1 && configured_n <= trace.n-(rs1-p1);
  check(in_range, "wrong split pointer progression or out-of-range request");
  check(configured_n > 0, "zero-byte COMPUTE");
  check(configured_offset == trace.offset, "offset changed at a split boundary");
  if (!in_range) return 0;  // never dereference an invalid mutant request
  const auto* a = reinterpret_cast<const int8_t*>(rs1);
  const auto* b = reinterpret_cast<const int8_t*>(rs2);
  uint32_t acc = 0;
  for (uint32_t i = 0; i < configured_n; ++i) {
    const auto index = static_cast<uint32_t>(rs1-p1) + i;
    ++trace.visits[index];
    trace.offsets[index] += configured_offset;
    // Incremental modulo-2^32 model, independent of the 64-bit oracle.
    acc += static_cast<uint32_t>((static_cast<int>(a[i]) + configured_offset) *
                                static_cast<int>(b[i]));
  }
  return acc;
}

int main() {
  alignas(64) std::array<int8_t, kMaxTestN + 8> storage_a{}, storage_b{};
  std::mt19937 random(20261013);
  const uint32_t lengths[] = {257, 300, 511, 512, 513};
  const int offsets[] = {-128, -1, 0, 1, 127};
  for (uint32_t n : lengths) {
    const auto before = cases;
    for (unsigned low1 = 0; low1 < 4; ++low1)
      for (unsigned low2 = 0; low2 < 4; ++low2)
        for (int offset : offsets)
          for (int pattern = 0; pattern < 2; ++pattern) {
            int8_t* a = storage_a.data() + 4 + low1;
            int8_t* b = storage_b.data() + 4 + low2;
            check((reinterpret_cast<uintptr_t>(a) & 3) == low1 &&
                  (reinterpret_cast<uintptr_t>(b) & 3) == low2, "test alignment");
            std::fill(storage_a.begin(), storage_a.end(), 0x55);
            std::fill(storage_b.begin(), storage_b.end(), 0x33);
            for (uint32_t i = 0; i < n; ++i) {
              // Offset-only pattern cannot hide duplicate offsets behind
              // cancellation of signed random weights.
              a[i] = pattern ? 0 : static_cast<int8_t>(int(random() % 256) - 128);
              b[i] = pattern ? static_cast<int8_t>(1 + i % 127)
                             : static_cast<int8_t>(int(random() % 256) - 128);
            }
            run(a, b, static_cast<int8_t>(offset), n);
            check(a[-1] == 0x55 && a[n] == 0x55 && b[-1] == 0x33 && b[n] == 0x33,
                  "operand redzone changed");
          }
    check(cases - before == 16 * 5 * 2, "host matrix missing a tuple");
    std::printf("HOST COVERAGE: N=%u alignments=16 offsets=5 patterns=2 cases=%llu\n",
                n, static_cast<unsigned long long>(cases-before));
  }
  // Both signs of real overflow, with unaligned pointers and 274 chunks.
  for (unsigned low1 = 0; low1 < 4; ++low1)
    for (unsigned low2 = 0; low2 < 4; ++low2)
      for (bool negative : {false, true}) {
        int8_t* a = storage_a.data() + 4 + low1;
        int8_t* b = storage_b.data() + 4 + low2;
        std::fill_n(a, kMaxTestN, negative ? 127 : -128);
        std::fill_n(b, kMaxTestN, -128);
        const int8_t offset = negative ? 127 : -128;
        const auto wide = reference_wide(a, b, offset, kMaxTestN);
        check(negative ? wide < std::numeric_limits<int32_t>::min()
                       : wide > std::numeric_limits<int32_t>::max(),
              "host wrap test did not overflow int32");
        run(a, b, offset, kMaxTestN);
      }
  begin_trace(nullptr, nullptr, 0, -128);
  check(hw_simd_mac(nullptr, nullptr, -128, 0) == 0, "empty API result");
  end_trace(0);
  ++cases;
  check(cases == 833, "host case count");
  std::printf("HOST RESULT: cases=%llu computes=%llu per_element_audits=%llu mismatches=%llu\n",
              static_cast<unsigned long long>(cases), static_cast<unsigned long long>(total_computes),
              static_cast<unsigned long long>(element_audits), static_cast<unsigned long long>(mismatches));
  return mismatches ? 1 : 0;
}
