module register_iface #(
    parameter int NUM_RULES = 16
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // Register access
    input  logic                    reg_wen,
    input  logic [7:0]              reg_addr,
    input  logic [31:0]             reg_wdata,
    input  logic                    reg_ren,
    output logic [31:0]             reg_rdata,

    // Match table rule configuration (combinational read, registered write)
    output logic [NUM_RULES-1:0]    rule_valid,
    output logic [7:0]              rule_protocol   [NUM_RULES-1:0],
    output logic [31:0]             rule_src_ip     [NUM_RULES-1:0],
    output logic [31:0]             rule_dst_ip     [NUM_RULES-1:0],
    output logic [15:0]             rule_src_port   [NUM_RULES-1:0],
    output logic [15:0]             rule_dst_port   [NUM_RULES-1:0],
    output logic [1:0]              rule_action     [NUM_RULES-1:0],
    output logic [7:0]              rule_class_id   [NUM_RULES-1:0],
    output logic [2:0]              rule_mod_action [NUM_RULES-1:0],

    // Stats readout
    input  logic [47:0]             cnt_packets,
    input  logic [47:0]             cnt_bytes,
    input  logic [47:0]             cnt_ipv4,
    input  logic [47:0]             cnt_tcp,
    input  logic [47:0]             cnt_udp,
    input  logic [47:0]             cnt_arp,
    input  logic [47:0]             cnt_drops,
    input  logic [47:0]             cnt_errors
);

  // -------------------------------------------------------------------------
  // Register address map
  // -------------------------------------------------------------------------
  localparam ADDR_CTRL      = 8'h00;
  localparam ADDR_RULE_BASE = 8'h10;  // 16 rules × 4 regs each = 0x10-0x4F
  localparam ADDR_STATS_BASE = 8'h50; // 8 stats × 2 regs each = 0x50-0x5F
  localparam ADDR_SCHED     = 8'h60;

  // Rule register layout (4 × 32-bit registers per rule):
  //   reg 0: {8'd0, protocol, src_port, dst_port}  (aligned for match)
  //   reg 1: src_ip
  //   reg 2: dst_ip
  //   reg 3: {valid, 8'd0, mod_action, action, class_id}

  // -------------------------------------------------------------------------
  // Register file
  // -------------------------------------------------------------------------
  logic [31:0] regs [64];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < 64; i++) regs[i] <= '0;
    end else if (reg_wen) begin
      regs[reg_addr] <= reg_wdata;
    end
  end

  assign reg_rdata = reg_ren ? regs[reg_addr] : '0;

  // -------------------------------------------------------------------------
  // Wire registers to rule configuration outputs
  // -------------------------------------------------------------------------
  always_comb begin
    for (int r = 0; r < NUM_RULES; r++) begin
      rule_valid[r]      = regs[ADDR_RULE_BASE + r*4 + 3][31];
      rule_class_id[r]   = regs[ADDR_RULE_BASE + r*4 + 3][15:8];
      rule_action[r]     = regs[ADDR_RULE_BASE + r*4 + 3][7:6];
      rule_mod_action[r] = regs[ADDR_RULE_BASE + r*4 + 3][2:0];
      rule_protocol[r]   = regs[ADDR_RULE_BASE + r*4 + 0][31:24];
      rule_src_port[r]   = regs[ADDR_RULE_BASE + r*4 + 0][23:8];
      rule_dst_port[r]   = regs[ADDR_RULE_BASE + r*4 + 0][7:0];
      rule_src_ip[r]     = regs[ADDR_RULE_BASE + r*4 + 1];
      rule_dst_ip[r]     = regs[ADDR_RULE_BASE + r*4 + 2];
    end
  end

endmodule
