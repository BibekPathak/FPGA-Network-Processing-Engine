module crc32 #(
    parameter int DATA_WIDTH = 32
) (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic [DATA_WIDTH-1:0]   data_in,
    input  logic                    data_valid,
    input  logic                    data_last,
    output logic [31:0]             crc_out,
    output logic                    crc_valid
);

  logic [31:0] crc_state;
  logic [31:0] crc_next;

  always_comb begin
    crc_next = crc_state;
    for (int i = 0; i < DATA_WIDTH; i++) begin
      logic fb;
      fb = crc_next[0] ^ data_in[i];
      crc_next = {1'b0, crc_next[31:1]};
      if (fb) crc_next = crc_next ^ 32'hEDB88320;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      crc_state <= 32'hFFFFFFFF;
      crc_out   <= '0;
      crc_valid <= 1'b0;
    end else begin
      crc_valid <= 1'b0;
      if (data_valid) begin
        if (data_last) begin
          // Last beat: compute final CRC
          crc_state <= 32'hFFFFFFFF;  // reset for next packet
          crc_out   <= ~crc_next;     // final XOR
          crc_valid <= 1'b1;
        end else begin
          crc_state <= crc_next;
        end
      end
    end
  end

endmodule
