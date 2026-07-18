module axis_register #(
    parameter int DATA_WIDTH = 512
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
    input  logic                    m_tready
);

  logic [DATA_WIDTH-1:0]   pipe_tdata;
  logic [DATA_WIDTH/8-1:0] pipe_tkeep;
  logic                    pipe_tlast;
  logic                    pipe_valid;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pipe_valid <= '0;
    end else if (m_tready || !pipe_valid) begin
      pipe_tdata <= s_tdata;
      pipe_tkeep <= s_tkeep;
      pipe_tlast <= s_tlast;
      pipe_valid <= s_tvalid;
    end
  end

  assign s_tready = m_tready || !pipe_valid;
  assign m_tdata  = pipe_tdata;
  assign m_tkeep  = pipe_tkeep;
  assign m_tlast  = pipe_tlast;
  assign m_tvalid = pipe_valid;

endmodule
