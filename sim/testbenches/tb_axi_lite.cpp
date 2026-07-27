#include <cstdio>
#include <cstdint>
#include <iostream>
#include <memory>

#include "Vregister_iface.h"

struct Sim {
  std::unique_ptr<Vregister_iface> dut;
  Sim() : dut(std::make_unique<Vregister_iface>()) {}
  void pre()  { dut->clk = 0; dut->eval(); }
  void post() { dut->clk = 1; dut->eval(); }
  void tick() { pre(); post(); }
  void reset() {
    dut->rst_n = 0;
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1; tick();
  }

  // AXI-Lite write: addr, data. Returns true on completion.
  bool axi_write(uint32_t addr, uint32_t data) {
    pre();
    dut->s_axi_awaddr = addr;
    dut->s_axi_awvalid = 1;
    dut->s_axi_wdata = data;
    dut->s_axi_wvalid = 1;
    dut->s_axi_bready = 1;
    dut->s_axi_arvalid = 0;
    dut->s_axi_rready = 0;
    post();  // cycle 1: FSM accepts AW+W, moves to W_RESP

    deassert_w();
    tick();  // cycle 2: W_RESP asserts bvalid
    tick();  // cycle 3: bvalid handshake, return to W_IDLE

    return true;
  }

  void deassert_w() {
    pre();
    dut->s_axi_awvalid = 0;
    dut->s_axi_wvalid = 0;
    post();
  }

  // AXI-Lite read: addr. Returns data.
  uint32_t axi_read(uint32_t addr) {
    pre();
    dut->s_axi_araddr = addr;
    dut->s_axi_arvalid = 1;
    dut->s_axi_rready = 1;
    dut->s_axi_awvalid = 0;
    dut->s_axi_wvalid = 0;
    dut->s_axi_bready = 0;
    post();  // cycle 1: R_IDLE → R_DATA, asserts rvalid with data

    // Read rdata next cycle
    tick();
    pre();
    uint32_t data = dut->s_axi_rdata;
    dut->s_axi_arvalid = 0;
    post();
    return data;
  }
};

bool test_write_read() {
  std::cout << "=== test_write_read ===\n";
  Sim sim;
  sim.reset();

  // Write 0xDEADBEEF to address 0x10, then read it back
  bool wrote = sim.axi_write(0x10, 0xDEADBEEF);
  uint32_t readback = sim.axi_read(0x10);

  bool pass = wrote && (readback == 0xDEADBEEF);
  std::cout << "  Wrote 0xDEADBEEF → Read 0x" << std::hex << readback
            << std::dec << (pass ? " PASS" : " FAIL") << "\n";
  return pass;
}

bool test_stats_read() {
  std::cout << "=== test_stats_read ===\n";
  Sim sim;
  sim.reset();

  // Stats counters come from inputs — set some values
  sim.dut->cnt_packets = 12345;
  sim.dut->cnt_bytes = 999999;

  // Read stats via AXI-Lite (address 0x50 = packets[31:0])
  uint32_t pkt_lo = sim.axi_read(0x50);
  uint32_t pkt_hi = sim.axi_read(0x51);
  uint32_t byt_lo = sim.axi_read(0x52);

  uint64_t packets = ((uint64_t)pkt_hi << 32) | pkt_lo;
  bool pass = (packets == 12345) && (byt_lo == 999999);
  std::cout << "  packets=" << packets << " bytes_lo=" << byt_lo
            << (pass ? " PASS" : " FAIL") << "\n";
  return pass;
}

bool test_multiple_writes() {
  std::cout << "=== test_multiple_writes ===\n";
  Sim sim;
  sim.reset();

  bool ok = true;
  for (int i = 0; i < 4; i++) {
    uint32_t val = 0xA0000000 + i;
    ok = sim.axi_write(0x20 + i, val) && ok;
  }
  uint32_t r0 = sim.axi_read(0x20);
  uint32_t r1 = sim.axi_read(0x21);
  uint32_t r2 = sim.axi_read(0x22);
  uint32_t r3 = sim.axi_read(0x23);

  ok = ok && (r0 == 0xA0000000) && (r1 == 0xA0000001)
          && (r2 == 0xA0000002) && (r3 == 0xA0000003);
  std::cout << "  4 writes: " << (ok ? "PASS" : "FAIL") << "\n";
  return ok;
}

int main(int argc, char** argv) {
  setbuf(stdout, NULL); setbuf(stderr, NULL);
  Verilated::commandArgs(argc, argv);
  bool all = true;
  all &= test_write_read();
  all &= test_stats_read();
  all &= test_multiple_writes();
  std::cout << "\n=== " << (all ? "ALL TESTS PASSED" : "SOME TESTS FAILED") << " ===\n";
  return all ? 0 : 1;
}
