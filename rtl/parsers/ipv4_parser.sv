module ipv4_parser #(
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

  // IPv4 header starts at byte 14 (no VLAN) or byte 18 (with VLAN)
  localparam int IP_OFFSET_BASE = 14;
  localparam int VLAN_HDR_BYTES = 4;

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

  // Determine IP header byte offset
  logic [5:0] ip_off;
  assign ip_off = s_meta.vlan_valid ? IP_OFFSET_BASE + VLAN_HDR_BYTES : IP_OFFSET_BASE;

  // -------------------------------------------------------------------------
  // Field extraction
  // -------------------------------------------------------------------------
  logic [7:0]  version_ihl;
  logic [7:0]  proto;
  logic [7:0]  ttl;
  logic [15:0] total_len;
  logic [15:0] hdr_cksum;
  logic [31:0] src_ip;
  logic [31:0] dst_ip;
  logic [3:0]  hdr_len;
  logic        ip_valid;

  assign version_ihl = byte_at(s_tdata, ip_off);
  assign proto       = byte_at(s_tdata, ip_off + 9);
  assign ttl         = byte_at(s_tdata, ip_off + 8);
  assign total_len   = word16_at(s_tdata, ip_off + 2);
  assign hdr_cksum   = word16_at(s_tdata, ip_off + 10);
  assign src_ip      = word32_at(s_tdata, ip_off + 12);
  assign dst_ip      = word32_at(s_tdata, ip_off + 16);
  assign hdr_len     = version_ihl[3:0];  // in 32-bit words
  assign ip_valid    = (s_meta.ethertype == ETYPE_IPV4);

  // -------------------------------------------------------------------------
  // Checksum verification (combinational over the 20-byte header)
  // -------------------------------------------------------------------------
  function automatic logic [15:0] ip_checksum(logic [DATA_WIDTH-1:0] data,
                                                int offset);
    logic [31:0] sum = 0;
    logic [15:0] w;
    // Sum over 20 bytes (10 half-words) of the IP header
    for (int i = 0; i < 10; i++) begin
      w = word16_at(data, offset + i*2);
      sum = sum + w;
    end
    // Fold 32-bit to 16-bit
    sum = (sum & 16'hFFFF) + (sum >> 16);
    sum = (sum & 16'hFFFF) + (sum >> 16);
    return ~sum[15:0];
  endfunction

  logic       cksum_ok;
  logic [5:0] l4_offset;

  assign cksum_ok  = (ip_checksum(s_tdata, ip_off) == 16'h0000);
  assign l4_offset = ip_off + hdr_len * 4;  // L4 header start byte

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

      if (ip_valid) begin
        pipe_meta.ipv4_valid     <= 1'b1;
        pipe_meta.src_ip         <= src_ip;
        pipe_meta.dst_ip         <= dst_ip;
        pipe_meta.protocol       <= proto;
        pipe_meta.ttl            <= ttl;
        pipe_meta.ip_hdr_len     <= hdr_len;
        pipe_meta.ip_checksum_ok <= cksum_ok;
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
