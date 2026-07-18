#ifndef NPE_PACKET_GEN_H
#define NPE_PACKET_GEN_H

#include <cstdint>
#include <vector>
#include <random>
#include <array>
#include <cstring>
#include <algorithm>

// ---------------------------------------------------------------------------
// PacketGen — builds raw Ethernet/IP/UDP/TCP packets byte vectors
// for driving into a Verilator DUT over AXI-Stream.
// ---------------------------------------------------------------------------
class PacketGen {
public:
  PacketGen(uint32_t seed = 42) : rng_(seed) {}

  // --- Builder helpers -----------------------------------------------------
  struct EthHdr {
    uint8_t  dst_mac[6];
    uint8_t  src_mac[6];
    uint16_t ethertype;
  };

  struct Ipv4Hdr {
    uint8_t  ver_ihl;       // 0x45 for IPv4, no options
    uint8_t  dscp_ecn;
    uint16_t total_length;
    uint16_t identification;
    uint16_t flags_frag_offset;
    uint8_t  ttl;
    uint8_t  protocol;
    uint16_t header_checksum;
    uint32_t src_ip;
    uint32_t dst_ip;
  };

  struct UdpHdr {
    uint16_t src_port;
    uint16_t dst_port;
    uint16_t length;
    uint16_t checksum;
  };

  struct TcpHdr {
    uint16_t src_port;
    uint16_t dst_port;
    uint32_t seq_number;
    uint32_t ack_number;
    uint8_t  data_offset;   // upper nibble, e.g. 0x50
    uint8_t  flags;
    uint16_t window_size;
    uint16_t checksum;
    uint16_t urgent_ptr;
  };

  // --- Packet generation ---------------------------------------------------

  // Build a complete Ethernet + IPv4 + UDP packet with payload
  std::vector<uint8_t> make_udp_packet(
      const uint8_t src_mac[6],
      const uint8_t dst_mac[6],
      uint32_t      src_ip,
      uint32_t      dst_ip,
      uint16_t      src_port,
      uint16_t      dst_port,
      const std::vector<uint8_t>& payload
  );

  // Build a complete Ethernet + IPv4 + TCP packet with payload
  std::vector<uint8_t> make_tcp_packet(
      const uint8_t src_mac[6],
      const uint8_t dst_mac[6],
      uint32_t      src_ip,
      uint32_t      dst_ip,
      uint16_t      src_port,
      uint16_t      dst_port,
      const std::vector<uint8_t>& payload,
      uint8_t       tcp_flags = 0x02  // SYN by default
  );

  // Build a random valid Ethernet/IP/UDP packet of given total size
  std::vector<uint8_t> make_random_packet(size_t total_bytes);

  // Build an Ethernet + ARP packet
  std::vector<uint8_t> make_arp_packet(
      const uint8_t src_mac[6],
      const uint8_t dst_mac[6],
      uint32_t      sender_ip,
      uint32_t      target_ip
  );

  // --- Utility -------------------------------------------------------------
  static uint16_t ip_checksum(const uint8_t* data, size_t len);
  static uint16_t ntohs(uint16_t x) { return __builtin_bswap16(x); }
  static uint32_t ntohl(uint32_t x) { return __builtin_bswap32(x); }
  static uint16_t htons(uint16_t x) { return __builtin_bswap16(x); }
  static uint32_t htonl(uint32_t x) { return __builtin_bswap32(x); }

private:
  std::mt19937 rng_;
  uint16_t      ip_id_counter_ = 0;

  void fill_eth(std::vector<uint8_t>& pkt, const uint8_t src_mac[6],
                const uint8_t dst_mac[6], uint16_t ethertype);
  void fill_ipv4(std::vector<uint8_t>& pkt, size_t payload_offset,
                 Ipv4Hdr& hdr);
};

// ---------------------------------------------------------------------------
// Inline implementations
// ---------------------------------------------------------------------------

inline void PacketGen::fill_eth(std::vector<uint8_t>& pkt,
                                const uint8_t src_mac[6],
                                const uint8_t dst_mac[6],
                                uint16_t ethertype) {
  pkt.resize(14);
  std::memcpy(pkt.data(), dst_mac, 6);
  std::memcpy(pkt.data() + 6, src_mac, 6);
  pkt[12] = (ethertype >> 8) & 0xFF;
  pkt[13] = ethertype & 0xFF;
}

inline uint16_t PacketGen::ip_checksum(const uint8_t* data, size_t len) {
  uint32_t sum = 0;
  for (size_t i = 0; i < len; i += 2) {
    uint16_t word = (data[i] << 8) | (i + 1 < len ? data[i + 1] : 0);
    sum += word;
  }
  while (sum >> 16) sum = (sum & 0xFFFF) + (sum >> 16);
  return ~sum & 0xFFFF;
}

inline void PacketGen::fill_ipv4(std::vector<uint8_t>& pkt,
                                 size_t payload_offset,
                                 Ipv4Hdr& hdr) {
  hdr.ver_ihl         = 0x45;
  hdr.dscp_ecn        = 0;
  hdr.total_length    = htons(static_cast<uint16_t>(pkt.size() - payload_offset));
  hdr.identification  = htons(ip_id_counter_++);
  hdr.flags_frag_offset = 0;
  hdr.ttl             = 64;
  hdr.header_checksum = 0;

  // Compute checksum over the IPv4 header (20 bytes)
  uint8_t hdr_bytes[20];
  std::memcpy(hdr_bytes, &hdr, 20);
  hdr.header_checksum = ip_checksum(hdr_bytes, 20);

  std::memcpy(pkt.data() + payload_offset, &hdr, 20);
}

inline std::vector<uint8_t> PacketGen::make_udp_packet(
    const uint8_t src_mac[6], const uint8_t dst_mac[6],
    uint32_t src_ip, uint32_t dst_ip,
    uint16_t src_port, uint16_t dst_port,
    const std::vector<uint8_t>& payload) {
  std::vector<uint8_t> pkt;
  fill_eth(pkt, src_mac, dst_mac, 0x0800);

  // Space for IPv4 header
  size_t ip_offset = pkt.size();
  pkt.resize(pkt.size() + 20);

  // UDP header
  size_t udp_offset = pkt.size();
  pkt.resize(pkt.size() + 8);

  // Payload
  pkt.insert(pkt.end(), payload.begin(), payload.end());

  // Fill UDP header
  UdpHdr udp;
  udp.src_port = htons(src_port);
  udp.dst_port = htons(dst_port);
  udp.length   = htons(static_cast<uint16_t>(8 + payload.size()));
  udp.checksum = 0;  // UDP checksum optional in IPv4
  std::memcpy(pkt.data() + udp_offset, &udp, 8);

  // Fill IPv4 header
  Ipv4Hdr ip;
  ip.src_ip        = htonl(src_ip);
  ip.dst_ip        = htonl(dst_ip);
  ip.protocol      = 17;  // UDP
  fill_ipv4(pkt, ip_offset, ip);

  return pkt;
}

inline std::vector<uint8_t> PacketGen::make_tcp_packet(
    const uint8_t src_mac[6], const uint8_t dst_mac[6],
    uint32_t src_ip, uint32_t dst_ip,
    uint16_t src_port, uint16_t dst_port,
    const std::vector<uint8_t>& payload,
    uint8_t tcp_flags) {
  std::vector<uint8_t> pkt;
  fill_eth(pkt, src_mac, dst_mac, 0x0800);

  size_t ip_offset = pkt.size();
  pkt.resize(pkt.size() + 20);

  size_t tcp_offset = pkt.size();
  pkt.resize(pkt.size() + 20);

  pkt.insert(pkt.end(), payload.begin(), payload.end());

  // TCP header
  TcpHdr tcp;
  tcp.src_port     = htons(src_port);
  tcp.dst_port     = htons(dst_port);
  tcp.seq_number   = htonl(1000);
  tcp.ack_number   = 0;
  tcp.data_offset  = 0x50;
  tcp.flags        = tcp_flags;
  tcp.window_size  = htons(65535);
  tcp.checksum     = 0;
  tcp.urgent_ptr   = 0;
  std::memcpy(pkt.data() + tcp_offset, &tcp, 20);

  // IPv4 header
  Ipv4Hdr ip;
  ip.src_ip        = htonl(src_ip);
  ip.dst_ip        = htonl(dst_ip);
  ip.protocol      = 6;  // TCP
  fill_ipv4(pkt, ip_offset, ip);

  return pkt;
}

inline std::vector<uint8_t> PacketGen::make_arp_packet(
    const uint8_t src_mac[6], const uint8_t dst_mac[6],
    uint32_t sender_ip, uint32_t target_ip) {
  std::vector<uint8_t> pkt;
  fill_eth(pkt, src_mac, dst_mac, 0x0806);

  // ARP header (28 bytes)
  pkt.resize(pkt.size() + 28);
  size_t off = 14;
  pkt[off + 0]  = 0x00; pkt[off + 1]  = 0x01;  // HTYPE = Ethernet
  pkt[off + 2]  = 0x08; pkt[off + 3]  = 0x00;  // PTYPE = IPv4
  pkt[off + 4]  = 6;    // HLEN
  pkt[off + 5]  = 4;    // PLEN
  pkt[off + 6]  = 0x00; pkt[off + 7]  = 0x01;  // OPER = Request
  std::memcpy(&pkt[off + 8],  src_mac, 6);
  uint32_t sip = htonl(sender_ip);
  std::memcpy(&pkt[off + 14], &sip, 4);
  std::memcpy(&pkt[off + 18], dst_mac, 6);
  uint32_t tip = htonl(target_ip);
  std::memcpy(&pkt[off + 24], &tip, 4);

  return pkt;
}

inline std::vector<uint8_t> PacketGen::make_random_packet(size_t total_bytes) {
  uint8_t src_mac[6] = {0x02, 0x00, 0x00, 0x00, 0x00, 0x01};
  uint8_t dst_mac[6] = {0x02, 0x00, 0x00, 0x00, 0x00, 0x02};

  std::uniform_int_distribution<uint32_t> ip_dist(0xC0A80001, 0xC0A800FF);
  std::uniform_int_distribution<uint16_t> port_dist(1024, 65535);
  std::uniform_int_distribution<int>      proto_dist(0, 1);

  size_t payload_len = total_bytes - 42;  // eth + ip + udp headers
  std::vector<uint8_t> payload(payload_len);
  for (auto& b : payload) b = rng_() & 0xFF;

  if (proto_dist(rng_) == 0) {
    return make_udp_packet(src_mac, dst_mac,
                           ip_dist(rng_), ip_dist(rng_),
                           port_dist(rng_), port_dist(rng_),
                           payload);
  } else {
    return make_tcp_packet(src_mac, dst_mac,
                           ip_dist(rng_), ip_dist(rng_),
                           port_dist(rng_), port_dist(rng_),
                           payload);
  }
}

#endif  // NPE_PACKET_GEN_H
