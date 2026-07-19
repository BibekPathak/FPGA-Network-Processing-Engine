#include <cstdio>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <vector>
#include <memory>

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
    for (int i = 0; i < 4; i++) { pre(); post(); }
    dut->rst_n = 1; pre(); post();
  }
};

// Push a packet with m_tready=1 throughout.
// Capture all output beats in order.
void push_and_capture(Sim& sim, const std::vector<uint8_t>& pkt,
                      std::vector<uint8_t>& out, int dw) {
  sim.dut->m_tready = 1;
  size_t pos = 0;

  while (pos < pkt.size()) {
    size_t nb = (pkt.size() - pos < (size_t)dw) ? (pkt.size() - pos) : dw;
    bool last = (pos + nb >= pkt.size());

    // Pre: set input, capture any output
    sim.pre();
    set32(sim.dut->s_tdata.data(), &pkt[pos], nb);
    sim.dut->s_tkeep = (1ULL << nb) - 1;
    sim.dut->s_tlast = last;
    sim.dut->s_tvalid = 1;
    if (sim.dut->m_tvalid && sim.dut->m_tready) {
      size_t nbytes = 0;
      uint64_t keep = sim.dut->m_tkeep;
      for (int b = 0; b < dw; b++) if (keep & (1ULL << b)) nbytes++;
      for (size_t i = 0; i < nbytes; i++) {
        uint32_t w = sim.dut->m_tdata.data()[i / 4];
        out.push_back((w >> ((i % 4) * 8)) & 0xFF);
      }
    }

    // Post: push current beat, pipeline advances
    sim.post();
    pos += nb;
  }

  // Drain remaining beats from pipeline
  int timeout = 10000;
  while (timeout--) {
    sim.pre();
    if (sim.dut->m_tvalid && sim.dut->m_tready) {
      size_t nbytes = 0;
      uint64_t keep = sim.dut->m_tkeep;
      for (int b = 0; b < dw; b++) if (keep & (1ULL << b)) nbytes++;
      for (size_t i = 0; i < nbytes; i++) {
        uint32_t w = sim.dut->m_tdata.data()[i / 4];
        out.push_back((w >> ((i % 4) * 8)) & 0xFF);
      }
      if (sim.dut->m_tlast) {
        sim.post();
        break;
      }
      sim.post();
    } else {
      sim.post();
      break;
    }
  }

  // Flush pipeline completely (silently consume any residual)
  for (int i = 0; i < 8; i++) {
    sim.pre();
    if (sim.dut->m_tvalid && sim.dut->m_tready) {
      sim.post();
    } else {
      sim.post();
    }
  }
}

// Combined push + drain
std::vector<uint8_t> push_one(Sim& sim, const std::vector<uint8_t>& pkt, int dw) {
  std::vector<uint8_t> out;
  push_and_capture(sim, pkt, out, dw);
  return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
bool test_udp() {
  std::cout << "=== test_udp ===\n";
  Sim sim; PacketGen gen; int dw = 8;
  sim.reset();
  uint8_t sm[6]={0x02,0,0,0,0,1}, dm[6]={0x02,0,0,0,0,2};
  auto pkt = gen.make_udp_packet(sm, dm, 0xC0A80001, 0xC0A80002, 1234, 80, {'H','i'});
  auto rx = push_one(sim, pkt, dw);
  bool pass = (rx.size() == pkt.size());
  std::cout << "  rx=" << rx.size() << " exp=" << pkt.size() << (pass ? " PASS" : " FAIL") << "\n";
  return pass;
}

bool test_tcp() {
  std::cout << "=== test_tcp ===\n";
  Sim sim; PacketGen gen; int dw = 8;
  sim.reset();
  uint8_t sm[6]={0x02,0,0,0,0,1}, dm[6]={0x02,0,0,0,0,2};
  auto pkt = gen.make_tcp_packet(sm, dm, 0xC0A80001, 0xC0A80002, 4321, 443, {'d','a','t','a'});
  auto rx = push_one(sim, pkt, dw);
  bool pass = (rx.size() == pkt.size());
  std::cout << "  rx=" << rx.size() << " exp=" << pkt.size() << (pass ? " PASS" : " FAIL") << "\n";
  return pass;
}

bool test_arp() {
  std::cout << "=== test_arp ===\n";
  Sim sim; PacketGen gen; int dw = 8;
  sim.reset();
  uint8_t sm[6]={0x02,0,0,0,0,1}, dm[6]={0x02,0,0,0,0,2};
  auto pkt = gen.make_arp_packet(sm, dm, 0xC0A80001, 0xC0A80002);
  auto rx = push_one(sim, pkt, dw);
  bool pass = (rx.size() == pkt.size());
  std::cout << "  rx=" << rx.size() << " exp=" << pkt.size() << (pass ? " PASS" : " FAIL") << "\n";
  return pass;
}

bool test_multi() {
  std::cout << "=== test_multi ===\n";
  PacketGen gen; int dw = 8;
  uint8_t sm[6]={0x02,0,0,0,0,1}, dm[6]={0x02,0,0,0,0,2};
  auto udp = gen.make_udp_packet(sm, dm, 0xC0A80001, 0xC0A80002, 53, 1234, {'D','N','S'});
  auto tcp = gen.make_tcp_packet(sm, dm, 0xC0A80001, 0xC0A80002, 80, 55555, {'H','T','T','P'});
  auto arp = gen.make_arp_packet(sm, dm, 0xC0A80001, 0xC0A80002);
  Sim su, st, sa;
  su.reset(); auto r1 = push_one(su, udp, dw);
  st.reset(); auto r2 = push_one(st, tcp, dw);
  sa.reset(); auto r3 = push_one(sa, arp, dw);
  bool pass = (r1.size()==udp.size() && r2.size()==tcp.size() && r3.size()==arp.size());
  std::cout << "  udp=" << r1.size() << "/" << udp.size()
            << " tcp=" << r2.size() << "/" << tcp.size()
            << " arp=" << r3.size() << "/" << arp.size()
            << (pass ? " PASS" : " FAIL") << "\n";
  return pass;
}

int main(int argc, char** argv) {
  setbuf(stdout, NULL); setbuf(stderr, NULL);
  Verilated::commandArgs(argc, argv);
  bool all = true;
  all &= test_udp(); all &= test_tcp(); all &= test_arp(); all &= test_multi();
  std::cout << "\n=== " << (all ? "ALL TESTS PASSED" : "SOME TESTS FAILED") << " ===\n";
  return all ? 0 : 1;
}
