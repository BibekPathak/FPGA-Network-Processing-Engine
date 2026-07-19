module vlan_parser #(
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

  function automatic logic [15:0] word16_be(logic [DATA_WIDTH-1:0] d, int idx);
    return {d[idx*8 +: 8], d[(idx+1)*8 +: 8]};
  endfunction

  localparam int VLAN_TCI_OFFSET  = 14;
  localparam int VLAN_ETYPE_OFFSET = 16;

  logic first_beat;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      first_beat <= 1'b1;
    end else if (s_tvalid && s_tready && s_tlast) begin
      first_beat <= 1'b1;
    end else if (s_tvalid && s_tready && first_beat) begin
      first_beat <= 1'b0;
    end
  end

  logic [11:0] vlan_id;
  logic [2:0]  vlan_prio;
  logic        vlan_cfi;
  logic [15:0] inner_ethertype;
  logic        has_vlan;

  assign has_vlan = s_meta.vlan_valid;
  assign vlan_id  = word16_be(s_tdata, VLAN_TCI_OFFSET)[11:0];
  assign vlan_prio = word16_be(s_tdata, VLAN_TCI_OFFSET)[15:13];
  assign vlan_cfi  = word16_be(s_tdata, VLAN_TCI_OFFSET)[12];
  assign inner_ethertype = word16_be(s_tdata, VLAN_ETYPE_OFFSET);

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

      if (first_beat && s_tvalid && s_tready) begin
        pipe_meta <= s_meta;
        if (has_vlan) begin
          pipe_meta.vlan_id   <= vlan_id;
          pipe_meta.vlan_prio <= vlan_prio;
          pipe_meta.vlan_cfi  <= vlan_cfi;
          pipe_meta.ethertype <= inner_ethertype;
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
