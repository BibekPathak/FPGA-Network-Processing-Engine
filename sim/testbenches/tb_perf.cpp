#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <vector>
#include <memory>
#include <chrono>

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
  void reset(int n = 4) {
    dut->rst_n = 0;
    for (int i = 0; i < n; i++) { pre(); post(); }
    dut->rst_n = 1; pre(); post();
  }
};

// ---------------------------------------------------------------------------
// PerfResult: stores measurement data for one run
// ---------------------------------------------------------------------------
struct PerfResult {
  uint64_t packets      = 0;
  uint64_t total_bytes  = 0;
  uint64_t push_cycles  = 0;   // cycles spent pushing
  uint64_t drain_cycles = 0;   // cycles spent draining (after push)
  uint64_t first_out    = 0;   // cycle when first output beat appeared
  uint64_t total_cycles = 0;

  double latency_cycles = 0;
  double cycles_per_packet = 0;
  double cycles_per_byte = 0;
  double throughput_gbps = 0;
};

// ---------------------------------------------------------------------------
// Push N identical packets back-to-back, measure performance
// ---------------------------------------------------------------------------
PerfResult measure(Sim& sim, const std::vector<uint8_t>& pkt, int dw,
                   int num_packets) {
  PerfResult r;
  sim.dut->m_tready = 1;
  uint64_t start_cycle = sim.cycles;

  // Pre-heat: push first packet, drain completely
  // (to fill pipeline to steady state)
  for (int p = 0; p < 2; p++) {
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
    // Drain
    int timeout = 10000;
    while (timeout--) {
      sim.pre();
      if (sim.dut->m_tvalid && sim.dut->m_tready) {
        if (sim.dut->m_tlast) { sim.post(); break; }
        sim.post();
      } else { sim.post(); break; }
    }
  }

  // Actual measurement
  uint64_t start_push = sim.cycles;
  bool first_beat_seen = false;

  for (int p = 0; p < num_packets; p++) {
    size_t pos = 0;
    while (pos < pkt.size()) {
      size_t nb = (pkt.size() - pos < (size_t)dw) ? (pkt.size() - pos) : dw;
      sim.pre();
      set32(sim.dut->s_tdata.data(), &pkt[pos], nb);
      sim.dut->s_tkeep = (1ULL << nb) - 1;
      sim.dut->s_tlast = (pos + nb >= pkt.size());
      sim.dut->s_tvalid = 1;

      // Track first output beat
      if (sim.dut->m_tvalid && sim.dut->m_tready && !first_beat_seen) {
        r.first_out = sim.cycles - start_push;
        first_beat_seen = true;
      }

      sim.post();
      while (!sim.dut->s_tready) { sim.pre(); sim.post(); }
      pos += nb;
    }
    // Idle between packets
    sim.pre(); sim.dut->s_tvalid = 0; sim.post();
    r.packets++;
    r.total_bytes += pkt.size();
  }

  uint64_t push_end = sim.cycles;
  r.push_cycles = push_end - start_push;

  // Drain remaining
  while (true) {
    sim.pre();
    if (sim.dut->m_tvalid && sim.dut->m_tready) {
      bool last = sim.dut->m_tlast;
      sim.post();
      if (last) break;
    } else { sim.post(); break; }
  }
  r.drain_cycles = sim.cycles - push_end;
  r.total_cycles = sim.cycles - start_cycle - 4;  // subtract pre-heat

  // Compute metrics
  r.latency_cycles = r.first_out;
  r.cycles_per_packet = (double)r.push_cycles / r.packets;
  r.cycles_per_byte = (double)r.push_cycles / r.total_bytes;

  // Throughput at 156.25 MHz clock
  double seconds = r.total_cycles / 156.25e6;
  if (seconds > 0)
    r.throughput_gbps = (r.total_bytes * 8.0) / seconds / 1e9;

  return r;
}

// ---------------------------------------------------------------------------
// Print results
// ---------------------------------------------------------------------------
void print_result(const char* label, const PerfResult& r, int pkt_size) {
  printf("%-20s %4d pkts %4d B  "
         "lat=%3.0f cyc  cyc/pkt=%5.1f  cyc/B=%5.3f  thrpt=%5.2f Gbps\n",
         label, (int)r.packets, pkt_size,
         r.latency_cycles, r.cycles_per_packet,
         r.cycles_per_byte, r.throughput_gbps);
}

// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
  setbuf(stdout, NULL); setbuf(stderr, NULL);
  Verilated::commandArgs(argc, argv);

  Sim sim; PacketGen gen; int dw = 8;
  uint8_t sm[6] = {0x02,0,0,0,0,1}, dm[6] = {0x02,0,0,0,0,2};
  int num = 1000;

  printf("NPE Pipeline Performance Measurement\n");
  printf("====================================\n");
  printf("Clock: 156.25 MHz (simulated)\n");
  printf("Data bus: 64-bit (8 bytes/cycle)\n");
  printf("Pipeline: 8 stages\n");
  printf("Packets per test: %d\n\n", num);

  // Small packets (64B)
  {
    auto pkt = gen.make_udp_packet(sm, dm, 0xC0A80001, 0xC0A80002,
                                    1234, 80, std::vector<uint8_t>(22, 'x'));
    sim.reset(); auto r = measure(sim, pkt, dw, num);
    print_result("Min-size (64B)", r, pkt.size());
  }

  // Medium packets (256B)
  {
    auto pkt = gen.make_udp_packet(sm, dm, 0xC0A80001, 0xC0A80002,
                                    1234, 80, std::vector<uint8_t>(214, 'x'));
    sim.reset(); auto r = measure(sim, pkt, dw, num);
    print_result("Medium (256B)", r, pkt.size());
  }

  // Large packets (512B)
  {
    auto pkt = gen.make_udp_packet(sm, dm, 0xC0A80001, 0xC0A80002,
                                    1234, 80, std::vector<uint8_t>(470, 'x'));
    sim.reset(); auto r = measure(sim, pkt, dw, num);
    print_result("Large (512B)", r, pkt.size());
  }

  // Jumbo packets (1518B)
  {
    auto pkt = gen.make_udp_packet(sm, dm, 0xC0A80001, 0xC0A80002,
                                    1234, 80, std::vector<uint8_t>(1476, 'x'));
    sim.reset(); auto r = measure(sim, pkt, dw, num);
    print_result("Jumbo (1518B)", r, pkt.size());
  }

  // TCP packets (64B)
  {
    auto pkt = gen.make_tcp_packet(sm, dm, 0xC0A80001, 0xC0A80002,
                                    4321, 443, std::vector<uint8_t>(22, 'x'));
    sim.reset(); auto r = measure(sim, pkt, dw, num);
    print_result("TCP (64B)", r, pkt.size());
  }

  // Mixed: 64B UDP + 1518B TCP alternating
  {
    auto s = gen.make_udp_packet(sm, dm, 0xC0A80001, 0xC0A80002,
                                  1234, 80, std::vector<uint8_t>(22, 'x'));
    auto l = gen.make_tcp_packet(sm, dm, 0xC0A80001, 0xC0A80002,
                                  4321, 443, std::vector<uint8_t>(1476, 'x'));
    sim.reset(); sim.dut->m_tready = 1;

    // For mixed test, do inline measurement
    auto start = sim.cycles;
    int pkt_count = 0;
    uint64_t total_bytes = 0;

    for (int p = 0; p < num; p++) {
      auto& pkt = (p % 2 == 0) ? s : l;
      size_t pos = 0;
      while (pos < pkt.size()) {
        size_t nb = (pkt.size()-pos < 8) ? pkt.size()-pos : 8;
        sim.pre();
        set32(sim.dut->s_tdata.data(), &pkt[pos], nb);
        sim.dut->s_tkeep = (1ULL<<nb)-1;
        sim.dut->s_tlast = (pos+nb >= pkt.size());
        sim.dut->s_tvalid = 1;
        sim.post();
        while (!sim.dut->s_tready) { sim.pre(); sim.post(); }
        pos += nb;
      }
      sim.pre(); sim.dut->s_tvalid = 0; sim.post();
      pkt_count++;
      total_bytes += pkt.size();
    }
    // Drain
    while (true) {
      sim.pre();
      if (sim.dut->m_tvalid && sim.dut->m_tready) {
        bool last = sim.dut->m_tlast;
        sim.post();
        if (last) break;
      } else { sim.post(); break; }
    }
    double sec = (sim.cycles - start) / 156.25e6;
    printf("%-20s %4d pkts mixed  "
           "thrpt=%5.2f Gbps  cyc/pkt=%5.1f\n",
           "Mixed (64+1518B)", pkt_count,
           sec > 0 ? (total_bytes * 8.0) / sec / 1e9 : 0,
           (double)(sim.cycles - start) / pkt_count);
  }

  printf("\n--- CSV ---\n");
  printf("packet_size,packets,latency_cyc,cyc_per_pkt,cyc_per_byte,gbps\n");

  for (auto& t : std::vector<std::pair<int,const char*>>{
         {64,"UDP"},{256,"UDP"},{512,"UDP"},{1518,"UDP"},{64,"TCP"}}) {
    auto pkt = (t.second[0]=='U')
      ? gen.make_udp_packet(sm,dm,0xC0A80001,0xC0A80002,1234,80,
                             std::vector<uint8_t>(t.first-42,'x'))
      : gen.make_tcp_packet(sm,dm,0xC0A80001,0xC0A80002,4321,443,
                             std::vector<uint8_t>(t.first-54,'x'));
    sim.reset(); auto r = measure(sim, pkt, dw, num);
    printf("%d,%d,%.0f,%.1f,%.3f,%.2f\n",
           t.first, (int)r.packets,
           r.latency_cycles, r.cycles_per_packet,
           r.cycles_per_byte, r.throughput_gbps);
  }

  return 0;
}
