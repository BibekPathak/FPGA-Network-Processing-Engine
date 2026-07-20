module flow_table #(
    parameter int DATA_WIDTH  = 512,
    parameter int NUM_FLOWS   = 64,
    parameter int LOG2_FLOWS  = $clog2(NUM_FLOWS)
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

    input  packet_metadata_t            s_meta
);

  import npe_pkg::*;

  localparam int KEEP_W = DATA_WIDTH / 8;

  // -------------------------------------------------------------------------
  // Flow table BRAM
  // -------------------------------------------------------------------------
  flow_entry_t flow_ram [NUM_FLOWS-1:0];

  // -------------------------------------------------------------------------
  // 5-tuple extraction (from metadata, valid on first beat)
  // -------------------------------------------------------------------------
  flow_key_t flow_key;

  assign flow_key.src_ip   = s_meta.src_ip;
  assign flow_key.dst_ip   = s_meta.dst_ip;
  assign flow_key.protocol = s_meta.protocol;
  assign flow_key.src_port = s_meta.src_port;
  assign flow_key.dst_port = s_meta.dst_port;

  // -------------------------------------------------------------------------
  // Hash function: XOR all 32-bit words of the 5-tuple, fold to table width
  // 5-tuple = 104 bits = 4 × 32-bit + 1 × 8-bit (zero-extended)
  // -------------------------------------------------------------------------
  logic [31:0] hash_words [3:0];

  assign hash_words[0] = flow_key.src_ip;
  assign hash_words[1] = flow_key.dst_ip;
  assign hash_words[2] = {flow_key.protocol, flow_key.src_port, 8'h00};
  assign hash_words[3] = {16'h0000, flow_key.dst_port};

  logic [31:0] hash_xor;
  logic [LOG2_FLOWS-1:0] hash_idx;

  assign hash_xor = hash_words[0] ^ hash_words[1] ^ hash_words[2] ^ hash_words[3];
  assign hash_idx = hash_xor[LOG2_FLOWS-1:0] ^ hash_xor[LOG2_FLOWS+:LOG2_FLOWS];

  // -------------------------------------------------------------------------
  // Lookup and update logic
  // -------------------------------------------------------------------------
  logic        update_en;
  logic        hit;
  logic [LOG2_FLOWS-1:0] rd_idx, wr_idx;

  assign update_en = s_tvalid && s_tready && s_tlast;  // fire on packet end
  assign rd_idx    = hash_idx;
  assign wr_idx    = hash_idx;

  // Read flow entry (combinational)
  flow_entry_t rd_entry;
  assign rd_entry = flow_ram[rd_idx];

  // Hit detection
  assign hit = rd_entry.valid &&
               (rd_entry.key == flow_key);

  // -------------------------------------------------------------------------
  // Flow update on packet end
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

  // Track packet length for byte counter
  logic [15:0] pkt_len_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pkt_len_q <= '0;
    end else if (update_en) begin
      pkt_len_q <= s_meta.pkt_length;
    end
  end

  // Update flow table entry on packet end
  always_ff @(posedge clk) begin
    if (update_en) begin
      if (hit) begin
        flow_ram[wr_idx].packet_count <= rd_entry.packet_count + 1'b1;
        flow_ram[wr_idx].byte_count   <= rd_entry.byte_count + s_meta.pkt_length;
      end else begin
        flow_ram[wr_idx].valid         <= 1'b1;
        flow_ram[wr_idx].key           <= flow_key;
        flow_ram[wr_idx].packet_count  <= 48'd1;
        flow_ram[wr_idx].byte_count    <= s_meta.pkt_length;
      end
    end
  end

  // Reset all entries
  integer i;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (i = 0; i < NUM_FLOWS; i++) begin
        flow_ram[i] <= '0;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Data passthrough pipeline register
  // -------------------------------------------------------------------------
  logic                            pipe_valid;
  logic [DATA_WIDTH-1:0]           pipe_tdata;
  logic [KEEP_W-1:0]               pipe_tkeep;
  logic                            pipe_tlast;

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
