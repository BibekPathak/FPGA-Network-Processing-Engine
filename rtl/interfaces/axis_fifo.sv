module axis_fifo #(
    parameter int DATA_WIDTH       = 512,
    parameter int DEPTH            = 16,
    parameter int ALMOST_FULL_TH   = DEPTH - 2,
    parameter int ALMOST_EMPTY_TH  = 2
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic [DATA_WIDTH-1:0]   s_tdata,
    input  logic [DATA_WIDTH/8-1:0] s_tkeep,
    input  logic                    s_tlast,
    input  logic                    s_tvalid,
    output logic                    s_tready,

    output logic [DATA_WIDTH-1:0]   m_tdata,
    output logic [DATA_WIDTH/8-1:0] m_tkeep,
    output logic                    m_tlast,
    output logic                    m_tvalid,
    input  logic                    m_tready,

    output logic                    full,
    output logic                    empty,
    output logic                    almost_full,
    output logic                    almost_empty,
    output logic [$clog2(DEPTH+1)-1:0] used
);

  localparam int WIDTH  = DATA_WIDTH + DATA_WIDTH/8 + 1;
  localparam int A_WIDTH = $clog2(DEPTH);

  logic [A_WIDTH:0] wr_ptr, rd_ptr;

  // ---------------------------------------------------------------------------
  // Dual-port RAM — combinational read (distributed RAM for small depths)
  // ---------------------------------------------------------------------------
  logic [WIDTH-1:0] ram [DEPTH-1:0];

  wire wren = s_tvalid && s_tready;

  // ---------------------------------------------------------------------------
  // Single always_ff: write pointer, read pointer, and m_tvalid all update
  // together so evaluation order is deterministic.
  // ---------------------------------------------------------------------------
  wire rden = m_tvalid && m_tready;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_ptr   <= '0;
      rd_ptr   <= '0;
      m_tvalid <= 1'b0;
    end else begin
      // Write (independent of read)
      if (wren) begin
        wr_ptr <= wr_ptr + 1'b1;
        ram[wr_ptr[A_WIDTH-1:0]] <= {s_tlast, s_tkeep, s_tdata};
      end

      // Read (independent of write)
      if (rden && wren) begin
        // Simultaneous read and write — occupancy unchanged
        rd_ptr <= rd_ptr + 1'b1;
        // m_tvalid stays as-is (data was read and written)
        // If there was exactly 1 entry before, after read it's 0,
        // but after write it's 1 again. So m_tvalid stays 1.
      end else if (rden) begin
        rd_ptr <= rd_ptr + 1'b1;
        if (ptr_diff <= 1) begin
          m_tvalid <= 1'b0;
        end
      end else if (wren) begin
        // Written but not read — data available at output
        m_tvalid <= 1'b1;
      end else if (!m_tvalid && !empty) begin
        // Data already in FIFO but output not yet valid
        m_tvalid <= 1'b1;
      end
    end
  end

  // Combinational read
  wire [WIDTH-1:0] rd_raw = ram[rd_ptr[A_WIDTH-1:0]];
  assign {m_tlast, m_tkeep, m_tdata} = rd_raw;

  // ---------------------------------------------------------------------------
  // Flags
  // ---------------------------------------------------------------------------
  logic [A_WIDTH:0] ptr_diff;

  assign ptr_diff    = wr_ptr - rd_ptr;
  assign used        = ptr_diff;
  assign empty       = (ptr_diff == 0);
  assign full        = (ptr_diff == DEPTH);
  assign almost_full = (ptr_diff >= ALMOST_FULL_TH);
  assign almost_empty = (ptr_diff <= ALMOST_EMPTY_TH);

  assign s_tready = !full;

endmodule
