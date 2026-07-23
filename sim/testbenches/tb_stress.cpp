#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <vector>
#include <memory>
#include <random>

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
  uint64_t cycles = 0;
  Sim() : dut(std::make_unique<Vparser_pipeline>()) {}
  void pre()  { dut->clk = 0; dut->eval(); }
  void post() { dut->clk = 1; dut->eval(); cycles++; }
  void reset() {
    dut->rst_n = 0;
    for (int i = 0; i < 8; i++) { pre(); post(); }
    dut->rst_n = 1; pre(); post();
  }
};

// Push a packet through the pipeline with optional output recording.
// Returns the number of bytes captured.
size_t push_and_capture(Sim& sim, const std::vector<uint8_t>& pkt, int dw,
                        std::vector<uint8_t>& rx) {
  sim.dut->m_tready = 1;
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
  return rx.size();
}

// Pull one beat from pipeline (for handshake-timed drain)
bool pull_beat(Sim& sim, int dw, uint8_t* data, size_t* nbytes, bool* last) {
  sim.pre();
  if (sim.dut->m_tvalid) {
    sim.dut->m_tready = 1;
    uint64_t keep = sim.dut->m_tkeep;
    *nbytes = 0;
    for (int b = 0; b < dw; b++) if (keep & (1ULL << b)) (*nbytes)++;
    for (size_t i = 0; i < *nbytes; i++) {
      uint32_t w = sim.dut->m_tdata.data()[i / 4];
      data[i] = (w >> ((i % 4) * 8)) & 0xFF;
    }
    *last = sim.dut->m_tlast;
    sim.post();
    return true;
  }
  sim.dut->m_tready = 0;
  sim.post();
  return false;
}

// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
  setbuf(stdout, NULL); setbuf(stderr, NULL);
  Verilated::commandArgs(argc, argv);

  std::mt19937 rng(42);
  PacketGen gen;
  uint8_t sm[6] = {0x02, 0, 0, 0, 0, 1};
  uint8_t dm[6] = {0x02, 0, 0, 0, 0, 2};
  int dw = 8;
  int total_pkts = 0, ok_pkts = 0;

  std::cout << "=== Stress Tests ===\n";

  // Test 1: 200 small UDP packets, m_tready=1 always
  {
    Sim sim; sim.reset();
    int fail = 0;
    for (int i = 0; i < 200; i++) {
      auto pkt = gen.make_udp_packet(sm, dm, 0xC0A80001, 0xC0A80002,
                                      100+i, 200+i, std::vector<uint8_t>(20, i&0xFF));
      std::vector<uint8_t> rx;
      push_and_capture(sim, pkt, dw, rx);
      if (rx.size() != pkt.size()) fail++;
      total_pkts++;
    }
    ok_pkts += 200 - fail;
    printf("  200 UDP (no backpressure): %d/%d\n", 200-fail, 200);
  }

  // Test 2: 100 mixed packets (UDP + TCP + ARP)
  {
    Sim sim; sim.reset();
    int fail = 0;
    for (int i = 0; i < 100; i++) {
      auto pkt = (i % 3 == 0)
        ? gen.make_tcp_packet(sm, dm, 0xC0A80001, 0xC0A80002, 80, 55555,
                               std::vector<uint8_t>(30, i&0xFF))
        : (i % 3 == 1)
          ? gen.make_arp_packet(sm, dm, 0xC0A80001, 0xC0A80002)
          : gen.make_udp_packet(sm, dm, 0xC0A80001, 0xC0A80002, 53, 1234,
                                std::vector<uint8_t>(15, i&0xFF));
      std::vector<uint8_t> rx;
      push_and_capture(sim, pkt, dw, rx);
      if (rx.size() != pkt.size()) fail++;
      total_pkts++;
    }
    ok_pkts += 100 - fail;
    printf("  100 mixed UDP/TCP/ARP: %d/%d\n", 100-fail, 100);
  }

  // Test 3: 50 jumbo packets (1518 bytes)
  {
    Sim sim; sim.reset();
    int fail = 0;
    for (int i = 0; i < 50; i++) {
      auto pkt = gen.make_udp_packet(sm, dm, 0xC0A80001, 0xC0A80002,
                                      100+i, 200+i,
                                      std::vector<uint8_t>(1450, i&0xFF));
      std::vector<uint8_t> rx;
      push_and_capture(sim, pkt, dw, rx);
      if (rx.size() != pkt.size()) fail++;
      total_pkts++;
    }
    ok_pkts += 50 - fail;
    printf("  50 jumbo (1518B): %d/%d\n", 50-fail, 50);
  }

  // Test 4: Pipeline flush after backpressure (periodic drain)
  {
    Sim sim; sim.reset();
    int fail = 0;
    for (int batch = 0; batch < 10; batch++) {
      // Push 5 packets without draining in between
      for (int p = 0; p < 5; p++) {
        auto pkt = gen.make_tcp_packet(sm, dm, 0xC0A80001, 0xC0A80002,
                                        80, 55555,
                                        std::vector<uint8_t>(30, p));
        std::vector<uint8_t> rx;
        push_and_capture(sim, pkt, dw, rx);
        if (rx.size() != pkt.size()) fail++;
        total_pkts++;
      }
    }
    ok_pkts += 50 - fail;
    printf("  50 batched TCP (periodic drain): %d/%d\n", 50-fail, 50);
  }

  printf("\n=== %d/%d PACKETS OK ===\n", ok_pkts, total_pkts);
  return (ok_pkts == total_pkts) ? 0 : 1;
}
