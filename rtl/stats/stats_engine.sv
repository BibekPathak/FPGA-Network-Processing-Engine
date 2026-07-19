module stats_engine #(
    parameter int DATA_WIDTH = 512,
    parameter int C_WIDTH    = 48
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

    input  packet_metadata_t            s_meta,

    // Counter outputs (saturating 48-bit)
    output logic [C_WIDTH-1:0]          cnt_packets,
    output logic [C_WIDTH-1:0]          cnt_bytes,
    output logic [C_WIDTH-1:0]          cnt_ipv4,
    output logic [C_WIDTH-1:0]          cnt_tcp,
    output logic [C_WIDTH-1:0]          cnt_udp,
    output logic [C_WIDTH-1:0]          cnt_arp,
    output logic [C_WIDTH-1:0]          cnt_drops,
    output logic [C_WIDTH-1:0]          cnt_errors
);

  import npe_pkg::*;

  localparam int KEEP_W = DATA_WIDTH / 8;

  // -------------------------------------------------------------------------
  // Saturating counter helper
  // -------------------------------------------------------------------------
  function automatic logic [C_WIDTH-1:0] sat_inc(logic [C_WIDTH-1:0] val);
    if (val < {C_WIDTH{1'b1}}) return val + 1'b1;
    else                       return val;
  endfunction

  // -------------------------------------------------------------------------
  // Counter update: fire on every packet end (s_tvalid && s_tready && s_tlast)
  // -------------------------------------------------------------------------
  wire count_valid = s_tvalid && s_tready && s_tlast;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cnt_packets <= '0;
      cnt_bytes   <= '0;
      cnt_ipv4    <= '0;
      cnt_tcp     <= '0;
      cnt_udp     <= '0;
      cnt_arp     <= '0;
      cnt_drops   <= '0;
      cnt_errors  <= '0;
    end else if (count_valid) begin
      cnt_packets <= sat_inc(cnt_packets);
      cnt_bytes   <= cnt_bytes + s_meta.pkt_length;

      if (s_meta.ipv4_valid)        cnt_ipv4  <= sat_inc(cnt_ipv4);
      if (s_meta.tcp_valid)         cnt_tcp   <= sat_inc(cnt_tcp);
      if (s_meta.udp_valid)         cnt_udp   <= sat_inc(cnt_udp);
      if (s_meta.ethertype == ETYPE_ARP) cnt_arp <= sat_inc(cnt_arp);
      if (s_meta.drop)              cnt_drops <= sat_inc(cnt_drops);
      if (s_meta.crc_error || s_meta.parse_error) cnt_errors <= sat_inc(cnt_errors);
    end
  end

  // -------------------------------------------------------------------------
  // Data passthrough (pipeline register — no metadata updates)
  // -------------------------------------------------------------------------
  logic                            pipe_valid;
  logic [DATA_WIDTH-1:0]           pipe_tdata;
  logic [KEEP_W-1:0]               pipe_tkeep;
  logic                            pipe_tlast;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pipe_valid <= '0;
    end else if (m_tready || !pipe_valid) begin
      pipe_tdata <= s_tdata;
      pipe_tkeep <= s_tkeep;
      pipe_tlast <= s_tlast;
      pipe_valid <= s_tvalid;
    end
  end

  assign s_tready = m_tready || !pipe_valid;
  assign m_tdata  = pipe_tdata;
  assign m_tkeep  = pipe_tkeep;
  assign m_tlast  = pipe_tlast;
  assign m_tvalid = pipe_valid;

endmodule
