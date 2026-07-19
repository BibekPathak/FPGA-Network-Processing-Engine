package npe_pkg;

  // ---------------------------------------------------------------------------
  // AXI-Stream forward bus (no tready — that flows backwards as a scalar)
  // ---------------------------------------------------------------------------
  parameter int AXIS_DATA_WIDTH = 512;
  parameter int AXIS_KEEP_WIDTH = AXIS_DATA_WIDTH / 8;

  typedef struct packed {
    logic [AXIS_DATA_WIDTH-1:0] tdata;
    logic [AXIS_KEEP_WIDTH-1:0] tkeep;
    logic                       tlast;
    logic                       tvalid;
  } axis_fwd_t;

  // ---------------------------------------------------------------------------
  // Metadata bus — carried alongside packet data through every pipeline stage
  // ---------------------------------------------------------------------------
  typedef struct packed {
    // L2
    logic [47:0]  dst_mac;
    logic [47:0]  src_mac;
    logic [15:0]  ethertype;

    // VLAN
    logic         vlan_valid;
    logic [11:0]  vlan_id;
    logic [2:0]   vlan_prio;
    logic         vlan_cfi;

    // L3
    logic         ipv4_valid;
    logic [31:0]  src_ip;
    logic [31:0]  dst_ip;
    logic [7:0]   protocol;
    logic [7:0]   ttl;
    logic [3:0]   ip_hdr_len;
    logic         ip_checksum_ok;

    // L4
    logic         tcp_valid;
    logic         udp_valid;
    logic [15:0]  src_port;
    logic [15:0]  dst_port;
    logic [3:0]   tcp_flags;
    logic [31:0]  tcp_seq;
    logic [31:0]  tcp_ack;
    logic [15:0]  tcp_window;

    // Classification
    logic [7:0]   class_id;
    logic         drop;

    // Error / length
    logic         crc_error;
    logic         parse_error;
    logic [15:0]  pkt_length;
  } packet_metadata_t;

  // ---------------------------------------------------------------------------
  // Pipeline stage input / output bundle (data + metadata + valid)
  // ---------------------------------------------------------------------------
  typedef struct packed {
    axis_fwd_t        axis;
    packet_metadata_t meta;
  } pipe_stage_t;

  // ---------------------------------------------------------------------------
  // Classifier rule
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic         valid;
    logic [7:0]   protocol;   // 0 = wildcard
    logic [31:0]  src_ip;     // 0 = wildcard
    logic [31:0]  dst_ip;     // 0 = wildcard
    logic [15:0]  src_port;   // 0 = wildcard
    logic [15:0]  dst_port;   // 0 = wildcard
    logic [7:0]   class_id;
    logic         drop;
  } classifier_rule_t;

  // ---------------------------------------------------------------------------
  // Rule engine action
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    ACTION_ALLOW    = 2'd0,
    ACTION_DROP     = 2'd1,
    ACTION_REDIRECT = 2'd2,
    ACTION_MIRROR   = 2'd3
  } rule_action_t;

  typedef struct packed {
    rule_action_t   action;
    logic [7:0]     queue_id;   // used by REDIRECT
  } action_entry_t;

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------
  parameter int  MAX_PKT_BYTES    = 1518;
  parameter int  MIN_PKT_BYTES    = 64;
  parameter int  ETH_HDR_BYTES    = 14;
  parameter int  VLAN_HDR_BYTES   = 4;
  parameter int  IPV4_HDR_MIN     = 20;
  parameter int  TCP_HDR_MIN      = 20;
  parameter int  UDP_HDR_BYTES    = 8;
  parameter int  FCS_BYTES        = 4;

  parameter logic [15:0] ETYPE_IPV4 = 16'h0800;
  parameter logic [15:0] ETYPE_ARP  = 16'h0806;
  parameter logic [15:0] ETYPE_VLAN = 16'h8100;

  parameter logic [7:0]  PROTO_TCP  = 8'h06;
  parameter logic [7:0]  PROTO_UDP  = 8'h11;
  parameter logic [7:0]  PROTO_ICMP = 8'h01;

endpackage
