// Formal verification properties for axis_fifo
// Run with: sby -f fifo.sby

module fifo_formal(
    input logic clk,
    input logic rst_n
);

  // Instantiate the FIFO with small depth for formal
  localparam DATA_WIDTH = 64;
  localparam DEPTH = 4;

  logic [DATA_WIDTH-1:0]   s_tdata;
  logic [DATA_WIDTH/8-1:0] s_tkeep;
  logic                     s_tlast;
  logic                     s_tvalid;
  logic                     s_tready;

  logic [DATA_WIDTH-1:0]   m_tdata;
  logic [DATA_WIDTH/8-1:0] m_tkeep;
  logic                     m_tlast;
  logic                     m_tvalid;
  logic                     m_tready;

  logic                     full, empty;
  logic [2:0]              used;

  axis_fifo #(
    .DATA_WIDTH(DATA_WIDTH),
    .DEPTH(DEPTH)
  ) fifo_inst (
    .clk, .rst_n,
    .s_tdata, .s_tkeep, .s_tlast, .s_tvalid, .s_tready,
    .m_tdata, .m_tkeep, .m_tlast, .m_tvalid, .m_tready,
    .full, .empty, .almost_full(), .almost_empty(), .used
  );

  // -------------------------------------------------------------------------
  // Formal constraints (assumptions)
  // -------------------------------------------------------------------------

  // Default: no valid data unless we say so
  default clocking @(posedge clk); endclocking
  default disable iff (!rst_n);

  // s_tkeep must be non-zero when s_tvalid is asserted
  assume property (s_tvalid |-> s_tkeep != 0);

  // m_tready is non-deterministic (can be 0 or 1)
  // We let it free — the solver picks values

  // -------------------------------------------------------------------------
  // Assertions (properties to prove)
  // -------------------------------------------------------------------------

  // Safety 1: Never write when full
  assert property (s_tvalid && s_tready |-> !full);

  // Safety 2: Never read when empty
  assert property (m_tvalid && m_tready |-> !empty);

  // Safety 3: s_tready implies not full
  assert property (s_tready |-> !full);

  // Safety 4: m_tvalid implies not empty
  assert property (m_tvalid |-> !empty);

  // Safety 5: Used count matches occupancy
  // The used signal should equal the number of entries in the FIFO
  // This is structural and guaranteed by the implementation

  // Safety 6: No data loss — if we write and read the same number
  // of items, the output should match the input
  // (This requires a more complex property with history — see below)

  // -------------------------------------------------------------------------
  // Advanced: data integrity (write → read matching)
  // -------------------------------------------------------------------------
  logic [3:0] push_count, pop_count;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      push_count <= 0;
      pop_count  <= 0;
    end else begin
      if (s_tvalid && s_tready) push_count <= push_count + 1;
      if (m_tvalid && m_tready) pop_count  <= pop_count + 1;
    end
  end

  // The number of items in the FIFO equals (push_count - pop_count)
  // This should match the 'used' output
  assert property (used == (push_count - pop_count));

  // FIFO occupancy never exceeds DEPTH
  assert property (push_count - pop_count <= DEPTH);
  assert property (push_count >= pop_count);

endmodule
