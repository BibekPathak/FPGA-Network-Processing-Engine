module udp_parser #(
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

  localparam int ETH_HDR_BYTES = 14;
  localparam int VLAN_BYTES    = 4;

  function automatic logic [15:0] word16_be(logic [DATA_WIDTH-1:0] d, int idx);
    return {d[idx*8 +: 8], d[(idx+1)*8 +: 8]};
  endfunction

  logic first_beat;
  always_ff @(posedge clk) begin
    if (!rst_n) first_beat <= 1'b1;
    else if (s_tvalid && s_tready && s_tlast) first_beat <= 1'b1;
    else if (s_tvalid && s_tready && first_beat) first_beat <= 1'b0;
  end

  logic [5:0] l4_off;
  assign l4_off = ETH_HDR_BYTES + (s_meta.vlan_valid ? VLAN_BYTES : 5'd0)
                  + {s_meta.ip_hdr_len, 2'b00};

  logic [15:0] src_port, dst_port;
  logic        is_udp;

  assign src_port = word16_be(s_tdata, l4_off);
  assign dst_port = word16_be(s_tdata, l4_off + 2);
  assign is_udp   = (s_meta.protocol == PROTO_UDP) && s_meta.ipv4_valid;

  logic                            pipe_valid;
  logic [DATA_WIDTH-1:0]           pipe_tdata;
  logic [DATA_WIDTH/8-1:0]         pipe_tkeep;
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

      if (first_beat && s_tvalid && s_tready) begin
        pipe_meta <= s_meta;
        if (is_udp) begin
          pipe_meta.udp_valid <= 1'b1;
          pipe_meta.src_port  <= src_port;
          pipe_meta.dst_port  <= dst_port;
        end
      end
    end
  end

  assign s_tready = m_tready || !pipe_valid;
  assign m_tdata  = pipe_tdata;
  assign m_tkeep  = pipe_tkeep;
  assign m_tlast  = pipe_tlast;
  assign m_tvalid = pipe_valid;
  assign m_meta   = pipe_meta;

endmodule
