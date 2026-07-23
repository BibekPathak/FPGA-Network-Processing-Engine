module match_table #(
    parameter int NUM_RULES   = 32,
    parameter int DATA_WIDTH  = 512
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
    output packet_metadata_t            m_meta,

    // Modifier instructions for downstream modifier stage
    output modifier_action_t            m_mod_action,
    output modifier_data_t              m_mod_data
);

  import npe_pkg::*;

  localparam int KEEP_W = DATA_WIDTH / 8;

  // -------------------------------------------------------------------------
  // Match table (BRAM) — hardcoded defaults
  // -------------------------------------------------------------------------
  match_entry_t rules [NUM_RULES-1:0];

  always_comb begin
    for (int r = 0; r < NUM_RULES; r++) begin
      rules[r] = '0;
    end
    rules[0].valid = 1'b1; rules[0].protocol = PROTO_UDP;
    rules[0].dst_port = 16'd53; rules[0].action = ACTION_ALLOW;
    rules[0].class_id = 8'd1; rules[0].mod_action = MOD_NOP;
    rules[1].valid = 1'b1; rules[1].protocol = PROTO_TCP;
    rules[1].dst_port = 16'd80; rules[1].action = ACTION_ALLOW;
    rules[1].class_id = 8'd2; rules[1].mod_action = MOD_NOP;
    rules[2].valid = 1'b1; rules[2].protocol = PROTO_TCP;
    rules[2].dst_port = 16'd443; rules[2].action = ACTION_ALLOW;
    rules[2].class_id = 8'd3; rules[2].mod_action = MOD_NOP;
    rules[3].valid = 1'b1; rules[3].protocol = PROTO_TCP;
    rules[3].dst_port = 16'd22; rules[3].action = ACTION_ALLOW;
    rules[3].class_id = 8'd4; rules[3].mod_action = MOD_NOP;
    rules[4].valid = 1'b1; rules[4].action = ACTION_ALLOW;
    rules[4].class_id = 8'd0; rules[4].mod_action = MOD_TTL_DEC;
  end

  // -------------------------------------------------------------------------
  // Match logic (combinational priority encoder)
  // -------------------------------------------------------------------------
  logic        match_found;
  rule_action_t      match_action;
  logic [7:0]        match_class;
  modifier_action_t  match_mod_action;
  modifier_data_t    match_mod_data;

  always_comb begin
    match_found      = 1'b0;
    match_action     = ACTION_DROP;
    match_class      = '0;
    match_mod_action = MOD_NOP;
    match_mod_data   = '0;

    for (int r = 0; r < NUM_RULES; r++) begin
      if (rules[r].valid && !match_found) begin
        logic local_match;
        local_match = 1'b1;

        if (rules[r].protocol != '0)
          local_match = local_match && (rules[r].protocol == s_meta.protocol);
        if (rules[r].src_ip != '0)
          local_match = local_match && (rules[r].src_ip == s_meta.src_ip);
        if (rules[r].dst_ip != '0)
          local_match = local_match && (rules[r].dst_ip == s_meta.dst_ip);
        if (rules[r].src_port != '0 && (s_meta.udp_valid || s_meta.tcp_valid))
          local_match = local_match && (rules[r].src_port == s_meta.src_port);
        if (rules[r].dst_port != '0 && (s_meta.udp_valid || s_meta.tcp_valid))
          local_match = local_match && (rules[r].dst_port == s_meta.dst_port);

        if (local_match) begin
          match_found      = 1'b1;
          match_action     = rules[r].action;
          match_class      = rules[r].class_id;
          match_mod_action = rules[r].mod_action;
          match_mod_data   = rules[r].mod_data;
        end
      end
    end
  end

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
  // Pipeline register — data is registered, modifier outputs are combinational
  // -------------------------------------------------------------------------
  logic                            pipe_valid;
  logic [DATA_WIDTH-1:0]           pipe_tdata;
  logic [KEEP_W-1:0]               pipe_tkeep;
  logic                            pipe_tlast;
  packet_metadata_t                pipe_meta;
  modifier_action_t                pipe_mod_action;
  modifier_data_t                  pipe_mod_data;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pipe_valid <= '0;
    end else if (m_tready || !pipe_valid) begin
      pipe_tdata  <= s_tdata;
      pipe_tkeep  <= s_tkeep;
      pipe_tlast  <= s_tlast;
      pipe_valid  <= s_tvalid;

      if (first_beat && s_tvalid && s_tready) begin
        pipe_meta          <= s_meta;
        pipe_meta.class_id <= match_class;
        pipe_meta.drop     <= (match_action == ACTION_DROP);
        pipe_mod_action    <= match_mod_action;
        pipe_mod_data      <= match_mod_data;
      end
    end
  end

  assign s_tready        = m_tready || !pipe_valid;
  assign m_tdata         = pipe_tdata;
  assign m_tkeep         = pipe_tkeep;
  assign m_tlast         = pipe_tlast;
  assign m_tvalid        = pipe_valid;
  assign m_meta          = pipe_meta;
  assign m_mod_action    = pipe_mod_action;
  assign m_mod_data      = pipe_mod_data;

endmodule
