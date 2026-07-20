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
#include "packet_mon.h"

static void set32(uint32_t* dst, const uint8_t* src, size_t n) {
  for (size_t i = 0; i < (n + 3) / 4; i++) {
    uint32_t w = 0;
    for (size_t j = 0; j < 4 && i * 4 + j < n; j++)
      w |= static_cast<uint32_t>(src[i * 4 + j]) << (j * 8);
    dst[i] = w;
  }
}

// ---------------------------------------------------------------------------
// Environment: shared DUT + monitor + scoreboard
// ---------------------------------------------------------------------------
struct Sim {
  std::unique_ptr<Vparser_pipeline> dut;
  Sim() : dut(std::make_unique<Vparser_pipeline>()) {}
  void pre()  { dut->clk = 0; dut->eval(); }
  void post() { dut->clk = 1; dut->eval(); }
  void reset() {
    dut->rst_n = 0;
    for (int i = 0; i < 8; i++) { pre(); post(); }
    dut->rst_n = 1; pre(); post();
  }
};

struct Env {
  Sim       sim;
  PacketMon mon;
  int       dw = 8;
  bool      verbose = false;

  void reset() { sim.reset(); mon.reset(); }

  // Generate a random packet of the given type
  std::vector<uint8_t> gen_pkt(PacketGen& gen, int type) {
    uint8_t sm[6] = {0x02, 0x00, 0x00, 0x00, 0x00, 0x01};
    uint8_t dm[6] = {0x02, 0x00, 0x00, 0x00, 0x00, 0x02};
    std::mt19937 rng(std::rand());
    std::uniform_int_distribution<uint32_t> ip(0xC0A80001, 0xC0A800FF);
    std::uniform_int_distribution<uint16_t> port(1024, 65535);
    std::uniform_int_distribution<int>      len(10, 200);

    size_t payload_len = len(rng);
    std::vector<uint8_t> payload(payload_len);
    for (auto& b : payload) b = rng() & 0xFF;

    switch (type % 4) {
      case 0:
        return gen.make_udp_packet(sm, dm, ip(rng), ip(rng),
                                    port(rng), port(rng), payload);
      case 1:
        return gen.make_tcp_packet(sm, dm, ip(rng), ip(rng),
                                    port(rng), port(rng), payload);
      case 2:
        return gen.make_arp_packet(sm, dm, ip(rng), ip(rng));
      default:
        return gen.make_udp_packet(sm, dm, ip(rng), ip(rng),
                                    port(rng), 53, payload);  // DNS
    }
  }

  // Push a packet and drain all output beats into the monitor
  void push_and_drain(const std::vector<uint8_t>& pkt) {
    sim.dut->m_tready = 1;
    size_t pos = 0;
    while (pos < pkt.size()) {
      size_t nb = (pkt.size() - pos < (size_t)dw) ? (pkt.size() - pos) : dw;
      sim.pre();
      set32(sim.dut->s_tdata.data(), &pkt[pos], nb);
      sim.dut->s_tkeep = (1ULL << nb) - 1;
      sim.dut->s_tlast = (pos + nb >= pkt.size());
      sim.dut->s_tvalid = 1;
      // Capture output beat at pre
      if (sim.dut->m_tvalid && sim.dut->m_tready) {
        size_t nbytes = 0;
        uint64_t keep = sim.dut->m_tkeep;
        for (int b = 0; b < dw; b++) if (keep & (1ULL << b)) nbytes++;
        uint8_t bdata[64] = {};
        for (size_t i = 0; i < nbytes; i++) {
          uint32_t w = sim.dut->m_tdata.data()[i / 4];
          bdata[i] = (w >> ((i % 4) * 8)) & 0xFF;
        }
        mon.push_beat(bdata, nbytes, sim.dut->m_tlast);
      }
      sim.post();
      while (!sim.dut->s_tready) { sim.pre(); sim.post(); }
      pos += nb;
    }

    // Idle + drain remaining
    sim.pre();
    if (sim.dut->m_tvalid && sim.dut->m_tready) {
      size_t nbytes = 0;
      uint64_t keep = sim.dut->m_tkeep;
      for (int b = 0; b < dw; b++) if (keep & (1ULL << b)) nbytes++;
      uint8_t bdata[64] = {};
      for (size_t i = 0; i < nbytes; i++) {
        uint32_t w = sim.dut->m_tdata.data()[i / 4];
        bdata[i] = (w >> ((i % 4) * 8)) & 0xFF;
      }
      mon.push_beat(bdata, nbytes, sim.dut->m_tlast);
    }
    sim.dut->s_tvalid = 0;
    sim.post();

    int timeout = 100000;
    while (timeout--) {
      sim.pre();
      if (sim.dut->m_tvalid && sim.dut->m_tready) {
        bool last = sim.dut->m_tlast;
        size_t nbytes = 0;
        uint64_t keep = sim.dut->m_tkeep;
        for (int b = 0; b < dw; b++) if (keep & (1ULL << b)) nbytes++;
        uint8_t bdata[64] = {};
        for (size_t i = 0; i < nbytes; i++) {
          uint32_t w = sim.dut->m_tdata.data()[i / 4];
          bdata[i] = (w >> ((i % 4) * 8)) & 0xFF;
        }
        mon.push_beat(bdata, nbytes, last);
        sim.post();
        if (last) break;
      } else {
        sim.post();
        if (!sim.dut->m_tvalid) break;
      }
    }
    sim.dut->m_tready = 0;
  }

  // Run N random packets through the pipeline
  bool run(int num_packets) {
    PacketGen gen(42);
    std::mt19937 rng(12345);
    std::uniform_int_distribution<int> type_dist(0, 3);

    for (int i = 0; i < num_packets; i++) {
      int type = type_dist(rng);
      auto pkt = gen_pkt(gen, type);
      mon.expect(pkt);
      push_and_drain(pkt);
      if (verbose) {
        std::cout << "  packet " << i << ": " << pkt.size() << " bytes, type=" << type << "\n";
      }
    }

    bool pass = (mon.error_count() == 0 && mon.pending() == 0);
    if (verbose) {
      std::cout << "  packets=" << mon.pkt_count()
                << " errors=" << mon.error_count()
                << " pending=" << mon.pending() << "\n";
    }
    return pass;
  }
};

// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
  setbuf(stdout, NULL); setbuf(stderr, NULL);
  Verilated::commandArgs(argc, argv);

  int num_packets = 100;
  bool verbose = false;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-n") == 0 && i + 1 < argc)
      num_packets = atoi(argv[++i]);
    if (strcmp(argv[i], "-v") == 0)
      verbose = true;
  }

  std::cout << "=== Random verification: " << num_packets << " packets ===\n";
  Env env;
  env.verbose = verbose;
  env.reset();
  bool pass = env.run(num_packets);

  std::cout << "  packets=" << env.mon.pkt_count()
            << " errors=" << env.mon.error_count()
            << (pass ? "\nPASS" : "\nFAIL") << "\n";
  return pass ? 0 : 1;
}
