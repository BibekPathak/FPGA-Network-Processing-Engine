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

    output packet_metadata_t            m_meta
);

  import npe_pkg::*;

  // Inter-stage connections
  packet_metadata_t meta_eth, meta_vlan, meta_ip, meta_l4;
  logic [DATA_WIDTH-1:0]   d_eth, d_vlan, d_ip;
  logic [DATA_WIDTH/8-1:0] k_eth, k_vlan, k_ip;
  logic                     l_eth, l_vlan, l_ip;
  logic                     v_eth, v_vlan, v_ip;
  logic                     r_eth, r_vlan, r_ip, r_l4;

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

  // Stage 4: TCP/UDP parsers — instantiate both, last write wins
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
    .m_tvalid(v_udp), .m_tready(m_tready),
    .s_meta(meta_ip), .m_meta(meta_udp)
  );

  tcp_parser #(.DATA_WIDTH(DATA_WIDTH)) tcp_inst (
    .clk, .rst_n,
    .s_tdata(d_ip), .s_tkeep(k_ip), .s_tlast(l_ip),
    .s_tvalid(v_ip), .s_tready(r_tcp),
    .m_tdata(d_tcp), .m_tkeep(k_tcp), .m_tlast(l_tcp),
    .m_tvalid(v_tcp), .m_tready(m_tready),
    .s_meta(meta_ip), .m_meta(meta_tcp)
  );

  // Both UDP and TCP parsers read from the same input (d_ip).
  // The ready signal from the downstream stage must account for both.
  // For simplicity: both parsers are always ready if the output is ready.
  assign r_ip      = r_udp && r_tcp;

  // Both parsers output simultaneously — merge metadata
  // (only one will have tcp_valid or udp_valid set)
  assign m_tdata   = v_tcp ? d_tcp : d_udp;
  assign m_tkeep   = v_tcp ? k_tcp : k_udp;
  assign m_tlast   = v_tcp ? l_tcp : l_udp;
  assign m_tvalid  = v_tcp || v_udp;
  assign m_meta    = meta_tcp.tcp_valid ? meta_tcp : meta_udp;

endmodule
