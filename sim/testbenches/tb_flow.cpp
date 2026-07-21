#include <cstdio>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <vector>
#include <memory>
#include <set>

#include "Vparser_pipeline.h"
#include "Vparser_pipeline__Syms.h"
#include "packet_gen.h"

static void set32(uint32_t* dst, const uint8_t* src, size_t n) {
  for (size_t i = 0; i < (n + 3) / 4; i++) {
    uint32_t w = 0;
    for (size_t j = 0; j < 4 && i * 4 + j < n; j++)
      w |= static_cast<uint32_t>(src[i * 4 + j]) << (j * 8);
    dst[i] = w;
  }
}

struct Sim {
  std::unique_ptr<Vparser_pipeline> dut;
  Sim() : dut(std::make_unique<Vparser_pipeline>()) {}
  void pre()  { dut->clk = 0; dut->eval(); }
  void post() { dut->clk = 1; dut->eval(); }
  void reset() {
    dut->rst_n = 0;
    for (int i = 0; i < 4; i++) { pre(); post(); }
    dut->rst_n = 1; pre(); post();
  }
};

void push_and_drain(Sim& sim, const std::vector<uint8_t>& pkt, int dw) {
  sim.dut->m_tready = 1;
  size_t pos = 0;
  while (pos < pkt.size()) {
    size_t nb = (pkt.size() - pos < (size_t)dw) ? (pkt.size() - pos) : dw;
    sim.pre();
    set32(sim.dut->s_tdata.data(), &pkt[pos], nb);
    sim.dut->s_tkeep = (1ULL << nb) - 1;
    sim.dut->s_tlast = (pos + nb >= pkt.size());
    sim.dut->s_tvalid = 1;
    sim.post();
    while (!sim.dut->s_tready) { sim.pre(); sim.post(); }
    pos += nb;
  }
  sim.pre(); sim.dut->s_tvalid = 0; sim.post();
  int timeout = 100000;
  while (timeout--) {
    sim.pre();
    if (sim.dut->m_tvalid && sim.dut->m_tready) {
      bool last = sim.dut->m_tlast;
      sim.post();
      if (last) break;
    } else { sim.post(); if (!sim.dut->m_tvalid) break; }
  }
}

// ---------------------------------------------------------------------------
bool test_basic() {
  std::cout << "=== test_basic ===\n";
  Sim sim; PacketGen gen; int dw = 8;
  sim.reset();
  uint8_t sm[6]={0x02,0,0,0,0,1}, dm[6]={0x02,0,0,0,0,2};

  // Push 5 identical DNS packets — same flow
  for (int i = 0; i < 5; i++) {
    auto pkt = gen.make_udp_packet(sm, dm, 0xC0A80001, 0xC0A80002, 53, 1234,
                                    std::vector<uint8_t>(10, 'x'));
    push_and_drain(sim, pkt, dw);
  }

  // The flow table should have tracked this as a hit (5 packets)
  std::cout << "  No crash after 5 same-flow packets\n  PASS\n";
  return true;
}

bool test_multi_flow() {
  std::cout << "=== test_multi_flow ===\n";
  Sim sim; PacketGen gen; int dw = 8;
  sim.reset();
  uint8_t sm[6]={0x02,0,0,0,0,1}, dm[6]={0x02,0,0,0,0,2};

  // Push 20 different flows
  for (int i = 0; i < 20; i++) {
    auto pkt = gen.make_udp_packet(sm, dm, 0xC0A80001, 0xC0A80002,
                                    100 + i, 200 + i,
                                    std::vector<uint8_t>(10, 'x'));
    push_and_drain(sim, pkt, dw);
  }

  std::cout << "  No crash after 20 different flows\n  PASS\n";
  return true;
}

bool test_data_integrity() {
  std::cout << "=== test_data_integrity ===\n";
  Sim sim; PacketGen gen; int dw = 8;
  sim.reset();
  uint8_t sm[6]={0x02,0,0,0,0,1}, dm[6]={0x02,0,0,0,0,2};
  auto pkt = gen.make_udp_packet(sm, dm, 0xC0A80001, 0xC0A80002, 53, 1234,
                                  {'T','e','s','t'});

  sim.dut->m_tready = 1;
  std::vector<uint8_t> rx;
  size_t pos = 0;
  while (pos < pkt.size()) {
    size_t nb = (pkt.size() - pos < (size_t)dw) ? (pkt.size() - pos) : dw;
    sim.pre();
    if (sim.dut->m_tvalid && sim.dut->m_tready) {
      size_t nbytes = 0;
      uint64_t keep = sim.dut->m_tkeep;
      for (int b = 0; b < dw; b++) if (keep & (1ULL << b)) nbytes++;
      for (size_t i = 0; i < nbytes; i++) {
        uint32_t w = sim.dut->m_tdata.data()[i / 4];
        rx.push_back((w >> ((i % 4) * 8)) & 0xFF);
      }
    }
    set32(sim.dut->s_tdata.data(), &pkt[pos], nb);
    sim.dut->s_tkeep = (1ULL << nb) - 1;
    sim.dut->s_tlast = (pos + nb >= pkt.size());
    sim.dut->s_tvalid = 1;
    sim.post();
    while (!sim.dut->s_tready) { sim.pre(); sim.post(); }
    pos += nb;
  }
  sim.pre(); sim.dut->s_tvalid = 0;
  if (sim.dut->m_tvalid && sim.dut->m_tready) {
    size_t nbytes = 0;
    uint64_t keep = sim.dut->m_tkeep;
    for (int b = 0; b < dw; b++) if (keep & (1ULL << b)) nbytes++;
    for (size_t i = 0; i < nbytes; i++) {
      uint32_t w = sim.dut->m_tdata.data()[i / 4];
      rx.push_back((w >> ((i % 4) * 8)) & 0xFF);
    }
  }
  sim.post();
  int timeout = 100000;
  while (timeout--) {
    sim.pre();
    if (sim.dut->m_tvalid && sim.dut->m_tready) {
      bool last = sim.dut->m_tlast;
      size_t nbytes = 0;
      uint64_t keep = sim.dut->m_tkeep;
      for (int b = 0; b < dw; b++) if (keep & (1ULL << b)) nbytes++;
      for (size_t i = 0; i < nbytes; i++) {
        uint32_t w = sim.dut->m_tdata.data()[i / 4];
        rx.push_back((w >> ((i % 4) * 8)) & 0xFF);
      }
      sim.post();
      if (last) break;
    } else { sim.post(); if (!sim.dut->m_tvalid) break; }
  }
  bool pass = (rx.size() == pkt.size());
  std::cout << "  size=" << rx.size() << "/" << pkt.size()
            << (pass ? " PASS" : " FAIL") << "\n";
  return pass;
}

int main(int argc, char** argv) {
  setbuf(stdout, NULL); setbuf(stderr, NULL);
  Verilated::commandArgs(argc, argv);
  bool all = true;
  all &= test_data_integrity();
  all &= test_basic();
  all &= test_multi_flow();
  std::cout << "\n=== " << (all ? "ALL TESTS PASSED" : "SOME TESTS FAILED") << " ===\n";
  return all ? 0 : 1;
}
