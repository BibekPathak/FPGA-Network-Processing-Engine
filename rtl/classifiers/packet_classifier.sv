module packet_classifier #(
    parameter int NUM_RULES = 32,
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
  // Rule table (BRAM)
  // -------------------------------------------------------------------------
  classifier_rule_t rules [NUM_RULES-1:0];

  // Default rules: DNS (UDP/53), HTTP (TCP/80), HTTPS (TCP/443), SSH (TCP/22)
  localparam int NUM_DEFAULT_RULES = 4;

  always_comb begin
    // Initialize all rules to invalid
    for (int r = 0; r < NUM_RULES; r++) begin
      rules[r] = '0;
    end
    // Default rule 0: DNS
    rules[0].valid    = 1'b1;
    rules[0].protocol = PROTO_UDP;
    rules[0].dst_port = 16'd53;
    rules[0].class_id = 8'd1;
    // Default rule 1: HTTP
    rules[1].valid    = 1'b1;
    rules[1].protocol = PROTO_TCP;
    rules[1].dst_port = 16'd80;
    rules[1].class_id = 8'd2;
    // Default rule 2: HTTPS
    rules[2].valid    = 1'b1;
    rules[2].protocol = PROTO_TCP;
    rules[2].dst_port = 16'd443;
    rules[2].class_id = 8'd3;
    // Default rule 3: SSH
    rules[3].valid    = 1'b1;
    rules[3].protocol = PROTO_TCP;
    rules[3].dst_port = 16'd22;
    rules[3].class_id = 8'd4;
  end

  // -------------------------------------------------------------------------
  // Match logic (combinational priority encoder)
  // -------------------------------------------------------------------------
  logic [7:0]  match_class;
  logic        match_drop;
  logic        match_found;

  always_comb begin
    match_found = 1'b0;
    match_class = '0;
    match_drop  = 1'b0;

    for (int r = 0; r < NUM_RULES; r++) begin
      if (rules[r].valid && !match_found) begin
        logic match;
        match = 1'b1;

        if (rules[r].protocol != '0)
          match = match && (rules[r].protocol == s_meta.protocol);

        if (rules[r].src_ip != '0)
          match = match && (rules[r].src_ip == s_meta.src_ip);

        if (rules[r].dst_ip != '0)
          match = match && (rules[r].dst_ip == s_meta.dst_ip);

        if (rules[r].src_port != '0 && (s_meta.udp_valid || s_meta.tcp_valid))
          match = match && (rules[r].src_port == s_meta.src_port);

        if (rules[r].dst_port != '0 && (s_meta.udp_valid || s_meta.tcp_valid))
          match = match && (rules[r].dst_port == s_meta.dst_port);

        if (match) begin
          match_found = 1'b1;
          match_class = rules[r].class_id;
          match_drop  = rules[r].drop;
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
        pipe_meta          <= s_meta;
        pipe_meta.class_id <= match_found ? match_class : 8'd0;
        pipe_meta.drop     <= match_drop;
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
