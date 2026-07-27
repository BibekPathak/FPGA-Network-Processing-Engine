module register_iface #(
    parameter int NUM_RULES = 16
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic [31:0]             s_axi_awaddr,
    input  logic                    s_axi_awvalid,
    output logic                    s_axi_awready,

    input  logic [31:0]             s_axi_wdata,
    input  logic                    s_axi_wvalid,
    output logic                    s_axi_wready,

    output logic [1:0]              s_axi_bresp,
    output logic                    s_axi_bvalid,
    input  logic                    s_axi_bready,

    input  logic [31:0]             s_axi_araddr,
    input  logic                    s_axi_arvalid,
    output logic                    s_axi_arready,

    output logic [31:0]             s_axi_rdata,
    output logic [1:0]              s_axi_rresp,
    output logic                    s_axi_rvalid,
    input  logic                    s_axi_rready,

    input  logic [47:0]             cnt_packets,
    input  logic [47:0]             cnt_bytes,
    input  logic [47:0]             cnt_ipv4,
    input  logic [47:0]             cnt_tcp,
    input  logic [47:0]             cnt_udp,
    input  logic [47:0]             cnt_arp,
    input  logic [47:0]             cnt_drops,
    input  logic [47:0]             cnt_errors
);

  logic [31:0] regs [64];

  // ---------------------------------------------------------------------------
  // Combined AXI-Lite Write: FSM + register write in one always_ff block
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] { W_IDLE, W_RESP } wstate_t;
  wstate_t wstate;
  logic [7:0]  waddr_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < 64; i++) regs[i] <= '0;
      wstate        <= W_IDLE;
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_bvalid  <= 1'b0;
      s_axi_bresp   <= 2'b00;
      waddr_q       <= '0;
    end else begin
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_bvalid  <= 1'b0;

      case (wstate)
        W_IDLE: begin
          if (s_axi_awvalid) begin
            s_axi_awready <= 1'b1;
            waddr_q       <= s_axi_awaddr[7:0];
            if (s_axi_wvalid) begin
              s_axi_wready  <= 1'b1;
              regs[s_axi_awaddr[7:0]] <= s_axi_wdata;
              wstate        <= W_RESP;
            end
          end else if (s_axi_wvalid) begin
            s_axi_wready <= 1'b1;
            if (wstate == W_IDLE && s_axi_awvalid) begin
              // handled above
            end
          end
        end

        W_RESP: begin
          s_axi_bvalid <= 1'b1;
          s_axi_bresp  <= 2'b00;
          if (s_axi_bready) begin
            wstate <= W_IDLE;
          end
        end
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // AXI-Lite Read FSM
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] { R_IDLE, R_DATA } rstate_t;
  rstate_t rstate;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rstate        <= R_IDLE;
      s_axi_arready <= 1'b0;
      s_axi_rvalid  <= 1'b0;
      s_axi_rdata   <= '0;
      s_axi_rresp   <= 2'b00;
    end else begin
      s_axi_arready <= 1'b0;
      s_axi_rvalid  <= 1'b0;

      case (rstate)
        R_IDLE: begin
          if (s_axi_arvalid) begin
            s_axi_arready <= 1'b1;
            s_axi_rdata   <= read_mux(s_axi_araddr[7:0]);
            s_axi_rvalid  <= 1'b1;
            rstate        <= R_DATA;
          end
        end

        R_DATA: begin
          s_axi_rvalid <= 1'b1;
          if (s_axi_rready) begin
            rstate <= R_IDLE;
          end
        end
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Read mux
  // ---------------------------------------------------------------------------
  function automatic logic [31:0] read_mux(logic [7:0] addr);
    if (addr >= 8'h50 && addr < 8'h60) begin
      unique case (addr)
        8'h50: return cnt_packets[31:0];
        8'h51: return {16'h0000, cnt_packets[47:32]};
        8'h52: return cnt_bytes[31:0];
        8'h53: return {16'h0000, cnt_bytes[47:32]};
        8'h54: return cnt_ipv4[31:0];
        8'h55: return {16'h0000, cnt_ipv4[47:32]};
        8'h56: return cnt_tcp[31:0];
        8'h57: return {16'h0000, cnt_tcp[47:32]};
        8'h58: return cnt_udp[31:0];
        8'h59: return {16'h0000, cnt_udp[47:32]};
        8'h5A: return cnt_arp[31:0];
        8'h5B: return {16'h0000, cnt_arp[47:32]};
        8'h5C: return cnt_drops[31:0];
        8'h5D: return {16'h0000, cnt_drops[47:32]};
        8'h5E: return cnt_errors[31:0];
        8'h5F: return {16'h0000, cnt_errors[47:32]};
        default: return '0;
      endcase
    end else begin
      return regs[addr];
    end
  endfunction

endmodule
