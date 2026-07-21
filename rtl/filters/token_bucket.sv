module token_bucket #(
    parameter int C_WIDTH = 48
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic                    pkt_valid,   // strobe: packet arrival
    input  logic [15:0]             pkt_length,  // packet size in bytes
    output logic                    pkt_allow,   // 1 = pass, 0 = drop

    // Configuration (AXI-Lite writable)
    input  logic [C_WIDTH-1:0]      cfg_rate,    // tokens added per refill (bytes)
    input  logic [C_WIDTH-1:0]      cfg_burst,   // max token accumulation (bytes)
    input  logic [31:0]             cfg_interval // refill interval in cycles
);

  // -------------------------------------------------------------------------
  // Token bucket state
  // -------------------------------------------------------------------------
  logic [C_WIDTH-1:0] tokens;
  logic [31:0]        timer;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tokens <= cfg_burst;  // start full
      timer  <= '0;
    end else begin
      // Timer-based refill every cfg_interval cycles
      if (timer >= cfg_interval) begin
        timer <= '0;
        // Add cfg_rate tokens, saturate at cfg_burst
        if (tokens + cfg_rate < cfg_burst)
          tokens <= tokens + cfg_rate;
        else
          tokens <= cfg_burst;
      end else begin
        timer <= timer + 1'b1;
      end

      // Packet consumes tokens
      if (pkt_valid) begin
        if (tokens >= pkt_length) begin
          tokens <= tokens - pkt_length;
        end
        // else: no tokens, pkt_allow will be 0, tokens unchanged
      end
    end
  end

  assign pkt_allow = pkt_valid && (tokens >= pkt_length);

endmodule
