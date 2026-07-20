module parser_pipeline #(
    parameter int DATA_WIDTH = 512
) (
    input  logic                        clk,
    input  logic                        rst_n,

    input  logic [DATA_WIDTH-1:0]       s_tdata,
    input  logic [DATA_WIDTH/8-1:0]     s_tkeep,
    input  logic                        s_tlast,
    input  logic                        s_tvalid,
    output logic                        s_tready,

    output logic [DATA_WIDTH-1:0]       m_tdata,
    output logic [DATA_WIDTH/8-1:0]     m_tkeep,
    output logic                        m_tlast,
    output logic                        m_tvalid,
    input  logic                        m_tready,

    output packet_metadata_t            m_meta,

    // Statistics counters
    output logic [47:0]                 cnt_packets,
    output logic [47:0]                 cnt_bytes,
    output logic [47:0]                 cnt_ipv4,
    output logic [47:0]                 cnt_tcp,
    output logic [47:0]                 cnt_udp,
    output logic [47:0]                 cnt_arp,
    output logic [47:0]                 cnt_drops,
    output logic [47:0]                 cnt_errors
);

  import npe_pkg::*;

  // Inter-stage connections
  packet_metadata_t meta_eth, meta_vlan, meta_ip, meta_l4, meta_class, meta_rule, meta_stats;
  logic [DATA_WIDTH-1:0]   d_eth, d_vlan, d_ip, d_l4, d_class, d_rule, d_stats, d_flow;
  logic [DATA_WIDTH/8-1:0] k_eth, k_vlan, k_ip, k_l4, k_class, k_rule, k_stats, k_flow;
  logic                     l_eth, l_vlan, l_ip, l_l4, l_class, l_rule, l_stats, l_flow;
  logic                     v_eth, v_vlan, v_ip, v_l4, v_class, v_rule, v_stats, v_flow;
  logic                     r_eth, r_vlan, r_ip, r_l4, r_class, r_rule, r_stats, r_flow;

  // Stage 1: Ethernet parser
  ethernet_parser #(.DATA_WIDTH(DATA_WIDTH)) eth_inst (
    .clk, .rst_n,
    .s_tdata, .s_tkeep, .s_tlast, .s_tvalid, .s_tready,
    .m_tdata(d_eth), .m_tkeep(k_eth), .m_tlast(l_eth),
    .m_tvalid(v_eth), .m_tready(r_eth),
    .s_meta('0), .m_meta(meta_eth)
  );

  // Stage 2: VLAN parser
  vlan_parser #(.DATA_WIDTH(DATA_WIDTH)) vlan_inst (
    .clk, .rst_n,
    .s_tdata(d_eth), .s_tkeep(k_eth), .s_tlast(l_eth),
    .s_tvalid(v_eth), .s_tready(r_eth),
    .m_tdata(d_vlan), .m_tkeep(k_vlan), .m_tlast(l_vlan),
    .m_tvalid(v_vlan), .m_tready(r_vlan),
    .s_meta(meta_eth), .m_meta(meta_vlan)
  );

  // Stage 3: IPv4 parser
  ipv4_parser #(.DATA_WIDTH(DATA_WIDTH)) ip_inst (
    .clk, .rst_n,
    .s_tdata(d_vlan), .s_tkeep(k_vlan), .s_tlast(l_vlan),
    .s_tvalid(v_vlan), .s_tready(r_vlan),
    .m_tdata(d_ip), .m_tkeep(k_ip), .m_tlast(l_ip),
    .m_tvalid(v_ip), .m_tready(r_ip),
    .s_meta(meta_vlan), .m_meta(meta_ip)
  );

  // Stage 4: TCP/UDP parsers (parallel)
  packet_metadata_t meta_udp, meta_tcp;
  logic [DATA_WIDTH-1:0]   d_udp, d_tcp;
  logic [DATA_WIDTH/8-1:0] k_udp, k_tcp;
  logic                     l_udp, l_tcp;
  logic                     v_udp, v_tcp;
  logic                     r_udp, r_tcp;

  udp_parser #(.DATA_WIDTH(DATA_WIDTH)) udp_inst (
    .clk, .rst_n,
    .s_tdata(d_ip), .s_tkeep(k_ip), .s_tlast(l_ip),
    .s_tvalid(v_ip), .s_tready(r_udp),
    .m_tdata(d_udp), .m_tkeep(k_udp), .m_tlast(l_udp),
    .m_tvalid(v_udp), .m_tready(r_rule),
    .s_meta(meta_ip), .m_meta(meta_udp)
  );

  tcp_parser #(.DATA_WIDTH(DATA_WIDTH)) tcp_inst (
    .clk, .rst_n,
    .s_tdata(d_ip), .s_tkeep(k_ip), .s_tlast(l_ip),
    .s_tvalid(v_ip), .s_tready(r_tcp),
    .m_tdata(d_tcp), .m_tkeep(k_tcp), .m_tlast(l_tcp),
    .m_tvalid(v_tcp), .m_tready(r_rule),
    .s_meta(meta_ip), .m_meta(meta_tcp)
  );

  assign r_ip = r_udp && r_tcp;

  // Merge UDP/TCP output
  assign d_l4    = v_tcp ? d_tcp : d_udp;
  assign k_l4    = v_tcp ? k_tcp : k_udp;
  assign l_l4    = v_tcp ? l_tcp : l_udp;
  assign v_l4    = v_tcp || v_udp;
  assign meta_l4 = meta_tcp.tcp_valid ? meta_tcp : meta_udp;

  // Stage 5: Packet classifier
  packet_classifier #(.DATA_WIDTH(DATA_WIDTH)) class_inst (
    .clk, .rst_n,
    .s_tdata(d_l4), .s_tkeep(k_l4), .s_tlast(l_l4),
    .s_tvalid(v_l4), .s_tready(r_class),
    .m_tdata(d_class), .m_tkeep(k_class), .m_tlast(l_class),
    .m_tvalid(v_class), .m_tready(r_rule),
    .s_meta(meta_l4), .m_meta(meta_class)
  );

  // Stage 6: Rule engine
  rule_engine #(.DATA_WIDTH(DATA_WIDTH)) rule_inst (
    .clk, .rst_n,
    .s_tdata(d_class), .s_tkeep(k_class), .s_tlast(l_class),
    .s_tvalid(v_class), .s_tready(r_rule),
    .m_tdata(d_rule), .m_tkeep(k_rule), .m_tlast(l_rule),
    .m_tvalid(v_rule), .m_tready(r_stats),
    .s_meta(meta_class), .m_meta(meta_rule)
  );

  // Stage 7: Statistics engine
  stats_engine #(.DATA_WIDTH(DATA_WIDTH)) stats_inst (
    .clk, .rst_n,
    .s_tdata(d_rule), .s_tkeep(k_rule), .s_tlast(l_rule),
    .s_tvalid(v_rule), .s_tready(r_stats),
    .m_tdata(d_stats), .m_tkeep(k_stats), .m_tlast(l_stats),
    .m_tvalid(v_stats), .m_tready(r_flow),
    .s_meta(meta_rule),
    .cnt_packets, .cnt_bytes, .cnt_ipv4, .cnt_tcp,
    .cnt_udp, .cnt_arp, .cnt_drops, .cnt_errors
  );

  // Stage 8: Flow table
  flow_table #(.DATA_WIDTH(DATA_WIDTH)) flow_inst (
    .clk, .rst_n,
    .s_tdata(d_stats), .s_tkeep(k_stats), .s_tlast(l_stats),
    .s_tvalid(v_stats), .s_tready(r_flow),
    .m_tdata(d_flow), .m_tkeep(k_flow), .m_tlast(l_flow),
    .m_tvalid(v_flow), .m_tready(m_tready),
    .s_meta(meta_rule)
  );

  assign m_tdata  = d_flow;
  assign m_tkeep  = k_flow;
  assign m_tlast  = l_flow;
  assign m_tvalid = v_flow;
  assign m_meta   = meta_rule;

endmodule
