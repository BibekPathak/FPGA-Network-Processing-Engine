module tcp_parser #(
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

  function automatic logic [7:0] byte_at(logic [DATA_WIDTH-1:0] data, int idx);
    return data[idx*8 +: 8];
  endfunction

  function automatic logic [15:0] word16_at(logic [DATA_WIDTH-1:0] data, int idx);
    return {data[(idx+1)*8-1 -: 8], data[idx*8 +: 8]};
  endfunction

  function automatic logic [31:0] word32_at(logic [DATA_WIDTH-1:0] data, int idx);
    return {data[(idx+3)*8-1 -: 8], data[(idx+2)*8-1 -: 8],
            data[(idx+1)*8-1 -: 8], data[idx*8 +: 8]};
  endfunction

  logic [5:0] l4_off;
  assign l4_off = ETH_HDR_BYTES + (s_meta.vlan_valid ? VLAN_BYTES : 5'd0)
                  + {s_meta.ip_hdr_len, 2'b00};

  // -------------------------------------------------------------------------
  // TCP field extraction
  // -------------------------------------------------------------------------
  logic [15:0] src_port;
  logic [15:0] dst_port;
  logic [31:0] seq_num;
  logic [31:0] ack_num;
  logic [7:0]  data_offset_byte;
  logic [3:0]  tcp_flags_val;
  logic [15:0] window;
  logic        is_tcp;

  assign src_port       = word16_at(s_tdata, l4_off);
  assign dst_port       = word16_at(s_tdata, l4_off + 2);
  assign seq_num        = word32_at(s_tdata, l4_off + 4);
  assign ack_num        = word32_at(s_tdata, l4_off + 8);
  assign data_offset_byte = byte_at(s_tdata, l4_off + 12);
  assign tcp_flags_val  = byte_at(s_tdata, l4_off + 13)[3:0];
  assign window         = word16_at(s_tdata, l4_off + 14);
  assign is_tcp         = (s_meta.protocol == PROTO_TCP) && s_meta.ipv4_valid;

  // -------------------------------------------------------------------------
  // Pipeline register
  // -------------------------------------------------------------------------
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
      pipe_meta   <= s_meta;

      if (is_tcp) begin
        pipe_meta.tcp_valid  <= 1'b1;
        pipe_meta.src_port   <= src_port;
        pipe_meta.dst_port   <= dst_port;
        pipe_meta.tcp_seq    <= seq_num;
        pipe_meta.tcp_ack    <= ack_num;
        pipe_meta.tcp_flags  <= tcp_flags_val;
        pipe_meta.tcp_window <= window;
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
