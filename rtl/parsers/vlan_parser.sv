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

  function automatic logic [7:0] byte_at(logic [DATA_WIDTH-1:0] data, int idx);
    return data[idx*8 +: 8];
  endfunction

  function automatic logic [15:0] word16_at(logic [DATA_WIDTH-1:0] data, int idx);
    return {data[(idx+1)*8-1 -: 8], data[idx*8 +: 8]};
  endfunction

  // VLAN tag is at bytes 14-17 (immediately after Ethernet header)
  localparam int VLAN_TCI_OFFSET = 14;
  localparam int VLAN_ETYPE_OFFSET = 16;

  logic [11:0] vlan_id;
  logic [2:0]  vlan_prio;
  logic        vlan_cfi;
  logic [15:0] inner_ethertype;
  logic        has_vlan;

  always_comb begin
    vlan_id  = word16_at(s_tdata, VLAN_TCI_OFFSET)[11:0];
    vlan_prio = word16_at(s_tdata, VLAN_TCI_OFFSET)[15:13];
    vlan_cfi  = word16_at(s_tdata, VLAN_TCI_OFFSET)[12];
    inner_ethertype = word16_at(s_tdata, VLAN_ETYPE_OFFSET);
    has_vlan = s_meta.vlan_valid;
  end

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

      if (has_vlan) begin
        pipe_meta.vlan_id   <= vlan_id;
        pipe_meta.vlan_prio <= vlan_prio;
        pipe_meta.vlan_cfi  <= vlan_cfi;
        pipe_meta.ethertype <= inner_ethertype;
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
