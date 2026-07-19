module ethernet_parser #(
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

    input  packet_metadata_t            s_meta,
    output packet_metadata_t            m_meta
);

  import npe_pkg::*;

  localparam int KEEP_W = DATA_WIDTH / 8;

  // -------------------------------------------------------------------------
  // Byte extraction helpers
  // -------------------------------------------------------------------------
  function automatic logic [7:0] byte_at(logic [DATA_WIDTH-1:0] data, int idx);
    return data[idx*8 +: 8];
  endfunction

  function automatic logic [15:0] word16_at(logic [DATA_WIDTH-1:0] data, int idx);
    return {data[(idx+1)*8-1 -: 8], data[idx*8 +: 8]};
  endfunction

  function automatic logic [47:0] mac_at(logic [DATA_WIDTH-1:0] data, int idx);
    return {data[(idx+5)*8-1 -: 8], data[(idx+4)*8-1 -: 8],
            data[(idx+3)*8-1 -: 8], data[(idx+2)*8-1 -: 8],
            data[(idx+1)*8-1 -: 8], data[idx*8 +: 8]};
  endfunction

  // -------------------------------------------------------------------------
  // Field extraction — from first beat bytes 0-13
  // -------------------------------------------------------------------------
  logic [47:0] dst_mac;
  logic [47:0] src_mac;
  logic [15:0] ethertype;
  logic        is_vlan;

  assign dst_mac   = mac_at(s_tdata, 0);
  assign src_mac   = mac_at(s_tdata, 6);
  assign ethertype = word16_at(s_tdata, 12);
  assign is_vlan   = (ethertype == ETYPE_VLAN);

  // -------------------------------------------------------------------------
  // Packet length accumulator
  // -------------------------------------------------------------------------
  logic [15:0] pkt_len_acc;
  logic        pkt_len_valid;

  function automatic int count_keep_bits(logic [KEEP_W-1:0] k);
    int c = 0;
    for (int i = 0; i < KEEP_W; i++) if (k[i]) c++;
    return c;
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pkt_len_acc   <= '0;
      pkt_len_valid <= 1'b1;
    end else if (s_tvalid && s_tready) begin
      if (s_tlast) begin
        pkt_len_acc   <= pkt_len_acc + count_keep_bits(s_tkeep);
        pkt_len_valid <= 1'b1;
      end else if (pkt_len_valid) begin
        pkt_len_acc   <= count_keep_bits(s_tkeep);
        pkt_len_valid <= 1'b0;
      end else begin
        pkt_len_acc   <= pkt_len_acc + count_keep_bits(s_tkeep);
      end
    end
  end

  // -------------------------------------------------------------------------
  // Pipeline register
  // -------------------------------------------------------------------------
  logic                            pipe_valid;
  logic [DATA_WIDTH-1:0]           pipe_tdata;
  logic [KEEP_W-1:0]               pipe_tkeep;
  logic                            pipe_tlast;
  packet_metadata_t                pipe_meta;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pipe_valid <= '0;
    end else if (m_tready || !pipe_valid) begin
      pipe_tdata  <= s_tdata;
      pipe_tkeep  <= s_tkeep;
      pipe_tlast  <= s_tlast;
      pipe_valid  <= s_tvalid;
      pipe_meta   <= s_meta;

      pipe_meta.dst_mac    <= dst_mac;
      pipe_meta.src_mac    <= src_mac;
      pipe_meta.ethertype  <= ethertype;
      pipe_meta.vlan_valid <= is_vlan;
      pipe_meta.pkt_length <= pkt_len_valid ? pkt_len_acc : s_meta.pkt_length;
    end
  end

  assign s_tready = m_tready || !pipe_valid;
  assign m_tdata  = pipe_tdata;
  assign m_tkeep  = pipe_tkeep;
  assign m_tlast  = pipe_tlast;
  assign m_tvalid = pipe_valid;
  assign m_meta   = pipe_meta;

endmodule
