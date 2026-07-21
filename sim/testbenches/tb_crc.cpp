#include <cstdio>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>

#include "Vcrc32.h"

struct Sim {
  std::unique_ptr<Vcrc32> dut;
  Sim() : dut(std::make_unique<Vcrc32>()) {}
  void pre()  { dut->clk = 0; dut->eval(); }
  void post() { dut->clk = 1; dut->eval(); }
  void reset() {
    dut->rst_n = 0;
    for (int i = 0; i < 4; i++) { pre(); post(); }
    dut->rst_n = 1; pre(); post();
  }
};

// Known CRC32 test vector: "12345678" → 0x9AE0DAAF (IEEE 802.3)
bool test_known_vector() {
  std::cout << "=== test_known_vector (32-bit aligned) ===\n";
  Sim sim;
  sim.reset();
  sim.dut->data_valid = 0;

  // Send "12345678" as two 32-bit words (aligned)
  uint32_t beat0 = '1' | ('2' << 8) | ('3' << 16) | ('4' << 24);  // = 0x34333231
  uint32_t beat1 = '5' | ('6' << 8) | ('7' << 16) | ('8' << 24);  // = 0x38373635

  sim.pre(); sim.dut->data_in = beat0; sim.dut->data_valid = 1; sim.dut->data_last = 0; sim.post();
  sim.pre(); sim.dut->data_in = beat1; sim.dut->data_valid = 1; sim.dut->data_last = 1; sim.post();
  sim.pre(); sim.dut->data_valid = 0;
  if (sim.dut->crc_valid) {
    uint32_t crc = sim.dut->crc_out;
    // CRC32 of "12345678" = 0x9AE0DAAF
    bool pass = (crc == 0x9AE0DAAF);
    printf("  CRC(12345678) = 0x%08X %s\n", crc, pass ? "PASS" : "FAIL");
    return pass;
  }
  sim.post();
  sim.pre();
  if (sim.dut->crc_valid) {
    uint32_t crc = sim.dut->crc_out;
    bool pass = (crc == 0x9AE0DAAF);
    printf("  CRC(12345678) = 0x%08X %s\n", crc, pass ? "PASS" : "FAIL");
    return pass;
  }
  printf("  CRC not ready\n");
  return false;
}

bool test_single_word() {
  std::cout << "=== test_single_word (32-bit aligned) ===\n";
  Sim sim;
  sim.reset();
  sim.dut->data_valid = 0;

  // CRC32 of "1234" as a single 32-bit word
  uint32_t word = '1' | ('2' << 8) | ('3' << 16) | ('4' << 24);  // "1234"
  sim.pre(); sim.dut->data_in = word; sim.dut->data_valid = 1; sim.dut->data_last = 1; sim.post();
  sim.pre(); sim.dut->data_valid = 0;
  uint32_t expected = 0x9BE3E0A3;  // CRC32 of "1234" (verified against algorithm)
  if (sim.dut->crc_valid) {
    uint32_t crc = sim.dut->crc_out;
    bool pass = (crc == expected);
    printf("  CRC('1234') = 0x%08X %s\n", crc, pass ? "PASS" : "FAIL");
    return pass;
  }
  sim.post();
  sim.pre();
  if (sim.dut->crc_valid) {
    uint32_t crc = sim.dut->crc_out;
    bool pass = (crc == expected);
    printf("  CRC('1234') = 0x%08X %s\n", crc, pass ? "PASS" : "FAIL");
    return pass;
  }
  printf("  CRC not ready\n");
  return false;
}

int main(int argc, char** argv) {
  setbuf(stdout, NULL); setbuf(stderr, NULL);
  Verilated::commandArgs(argc, argv);
  bool all = true;
  all &= test_known_vector();
  all &= test_single_word();
  std::cout << "\n=== " << (all ? "ALL TESTS PASSED" : "SOME TESTS FAILED") << " ===\n";
  return all ? 0 : 1;
}
