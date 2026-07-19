module rule_engine #(
    parameter int DATA_WIDTH = 512,
    parameter int NUM_CLASSES = 8
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
  // Action table (BRAM) — indexed by class_id
  // -------------------------------------------------------------------------
  action_entry_t action_table [NUM_CLASSES-1:0];

  always_comb begin
    for (int c = 0; c < NUM_CLASSES; c++) begin
      action_table[c] = '0;
      action_table[c].action = ACTION_ALLOW;
    end

    // class 1 (DNS) → ALLOW
    // class 2 (HTTP) → ALLOW
    // class 3 (HTTPS) → ALLOW
    // class 4 (SSH) → ALLOW
    // class 0 (no match) → DROP
    action_table[0].action = ACTION_DROP;
    action_table[1].action = ACTION_ALLOW;
    action_table[2].action = ACTION_ALLOW;
    action_table[3].action = ACTION_ALLOW;
    action_table[4].action = ACTION_ALLOW;
  end

  // -------------------------------------------------------------------------
  // Lookup
  // -------------------------------------------------------------------------
  logic [7:0]  class_id;
  rule_action_t class_action;
  logic        should_drop;
  logic [7:0]  queue_id;

  assign class_id     = s_meta.class_id;
  assign class_action = action_table[class_id].action;
  assign queue_id     = action_table[class_id].queue_id;
  assign should_drop  = (class_action == ACTION_DROP);

  // -------------------------------------------------------------------------
  // First-beat tracking
  // -------------------------------------------------------------------------
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

      if (first_beat && s_tvalid && s_tready) begin
        pipe_meta    <= s_meta;
        pipe_meta.drop <= should_drop;
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
