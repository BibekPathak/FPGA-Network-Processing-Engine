module packet_scheduler #(
    parameter int DATA_WIDTH = 512,
    parameter int FIFO_DEPTH = 16,
    parameter int SCHED_MODE = 0  // 0 = STRICT priority, 1 = Weighted Round-Robin
) (
    input  logic                        clk,
    input  logic                        rst_n,

    input  logic [DATA_WIDTH-1:0]       s_tdata,
    input  logic [DATA_WIDTH/8-1:0]     s_tkeep,
    input  logic                        s_tlast,
    input  logic                        s_tvalid,
    output logic                        s_tready,

    input  packet_metadata_t            s_meta,

    output logic [DATA_WIDTH-1:0]       m_tdata,
    output logic [DATA_WIDTH/8-1:0]     m_tkeep,
    output logic                        m_tlast,
    output logic                        m_tvalid,
    input  logic                        m_tready,

    // Per-queue weights for WRR mode (0 = no service)
    input  logic [7:0]                  weight_high,
    input  logic [7:0]                  weight_med,
    input  logic [7:0]                  weight_low
);

  import npe_pkg::*;

  localparam int KEEP_W = DATA_WIDTH / 8;

  // -------------------------------------------------------------------------
  // Priority assignment
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] {
    Q_HIGH = 2'd0,
    Q_MED  = 2'd1,
    Q_LOW  = 2'd2
  } queue_id_t;

  queue_id_t dest_queue;

  always_comb begin
    case (s_meta.class_id)
      8'd0:           dest_queue = Q_LOW;
      8'd1, 8'd2:     dest_queue = Q_MED;
      8'd3, 8'd4:     dest_queue = Q_HIGH;
      default:        dest_queue = Q_MED;
    endcase
  end

  // -------------------------------------------------------------------------
  // 3 FIFOs
  // -------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0]   fifo_din, fifo_dout [3];
  logic [KEEP_W-1:0]       fifo_kin, fifo_kout [3];
  logic                    fifo_lin, fifo_lout [3];
  logic                    fifo_vin [3], fifo_vout [3];
  logic                    fifo_rin [3], fifo_rdy [3];
  logic                    fifo_empty [3], fifo_full [3];

  assign fifo_din = s_tdata;
  assign fifo_kin = s_tkeep;
  assign fifo_lin = s_tlast;

  always_comb begin
    fifo_vin[0] = 1'b0; fifo_vin[1] = 1'b0; fifo_vin[2] = 1'b0;
    if (s_tvalid && s_tready) begin
      fifo_vin[dest_queue] = 1'b1;
    end
  end

  generate
    for (genvar q = 0; q < 3; q++) begin : gen_fifos
      axis_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(FIFO_DEPTH)
      ) queue_fifo (
        .clk, .rst_n,
        .s_tdata(fifo_din), .s_tkeep(fifo_kin), .s_tlast(fifo_lin),
        .s_tvalid(fifo_vin[q]), .s_tready(fifo_rdy[q]),
        .m_tdata(fifo_dout[q]), .m_tkeep(fifo_kout[q]), .m_tlast(fifo_lout[q]),
        .m_tvalid(fifo_vout[q]), .m_tready(fifo_rin[q]),
        .full(fifo_full[q]), .empty(fifo_empty[q]),
        .almost_full(), .almost_empty(), .used()
      );
    end
  endgenerate

  assign s_tready = !fifo_full[dest_queue];
  assign arb_state_out = arb_state;
  assign arb_ready_out = arb_ready_q;

  // -------------------------------------------------------------------------
  // Arbitration
  // -------------------------------------------------------------------------
  logic [1:0] arb_state, arb_next;
  logic [2:0] arb_ready;
  logic [7:0] wrr_count [3];
  logic [7:0] wrr_weight [3];

  assign arb_ready = {!fifo_empty[2], !fifo_empty[1], !fifo_empty[0]};
  assign wrr_weight[0] = weight_high;
  assign wrr_weight[1] = weight_med;
  assign wrr_weight[2] = weight_low;

  always_comb begin
    arb_next = arb_state;

    if (SCHED_MODE == 0) begin
      if (arb_ready[0])      arb_next = 0;
      else if (arb_ready[1]) arb_next = 1;
      else if (arb_ready[2]) arb_next = 2;
    end else begin
      // WRR: check if current queue has credits and data
      if (arb_ready[arb_state] && wrr_count[arb_state] < wrr_weight[arb_state]) begin
        arb_next = arb_state;
      end else begin
        // Round-robin: try next queues in order
        if (arb_state == 0) begin
          if (arb_ready[1] && wrr_weight[1] != 0) arb_next = 1;
          else if (arb_ready[2] && wrr_weight[2] != 0) arb_next = 2;
          else if (arb_ready[0] && wrr_weight[0] != 0) arb_next = 0;
        end else if (arb_state == 1) begin
          if (arb_ready[2] && wrr_weight[2] != 0) arb_next = 2;
          else if (arb_ready[0] && wrr_weight[0] != 0) arb_next = 0;
          else if (arb_ready[1] && wrr_weight[1] != 0) arb_next = 1;
        end else begin
          if (arb_ready[0] && wrr_weight[0] != 0) arb_next = 0;
          else if (arb_ready[1] && wrr_weight[1] != 0) arb_next = 1;
          else if (arb_ready[2] && wrr_weight[2] != 0) arb_next = 2;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      arb_state  <= 0;
      wrr_count[0] <= 0; wrr_count[1] <= 0; wrr_count[2] <= 0;
    end else begin
      arb_state <= arb_next;

      // Update WRR counters
      if (SCHED_MODE == 1) begin
        for (int q = 0; q < 3; q++) begin
          if (arb_state == q && fifo_vout[q] && m_tready) begin
            // A packet was served from this queue
            if (wrr_count[q] + 1 >= wrr_weight[q] || !arb_ready[q]) begin
              wrr_count[q] <= 0;  // exhausted or empty
            end else begin
              wrr_count[q] <= wrr_count[q] + 1;
            end
          end
        end
      end
    end
  end

  // Route selected FIFO to output
  always_comb begin
    fifo_rin[0] = 1'b0; fifo_rin[1] = 1'b0; fifo_rin[2] = 1'b0;
    if (arb_state < 3) begin
      fifo_rin[arb_state] = m_tready;
    end
  end

  always_comb begin
    m_tdata = '0; m_tkeep = '0; m_tlast = 1'b0; m_tvalid = 1'b0;
    if (arb_state < 3 && fifo_vout[arb_state]) begin
      m_tdata  = fifo_dout[arb_state];
      m_tkeep  = fifo_kout[arb_state];
      m_tlast  = fifo_lout[arb_state];
      m_tvalid = 1'b1;
    end
  end

endmodule
