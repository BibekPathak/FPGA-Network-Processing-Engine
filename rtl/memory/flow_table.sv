module flow_table #(
    parameter int DATA_WIDTH  = 512,
    parameter int NUM_FLOWS   = 128,
    parameter int LOG2_FLOWS  = $clog2(NUM_FLOWS / 2)  // 2-way: half the indices
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

    // Flow lookup result (for test/debug)
    output logic                        flow_hit,
    output logic [47:0]                 flow_packets,
    output logic [63:0]                 flow_bytes
);

  import npe_pkg::*;

  localparam int KEEP_W = DATA_WIDTH / 8;
  localparam int NUM_WAYS = 2;
  localparam int NUM_SETS = NUM_FLOWS / NUM_WAYS;
  localparam int LOG2_SETS = $clog2(NUM_SETS);

  // -------------------------------------------------------------------------
  // Flow table BRAM: 2-way set-associative
  // -------------------------------------------------------------------------
  flow_entry_t flow_ram [NUM_WAYS-1:0][NUM_SETS-1:0];
  logic [NUM_WAYS-1:0] lru;  // per-set LRU: 0 = way0 is LRU, 1 = way1 is LRU

  // -------------------------------------------------------------------------
  // 5-tuple extraction
  // -------------------------------------------------------------------------
  flow_key_t flow_key;
  assign flow_key.src_ip   = s_meta.src_ip;
  assign flow_key.dst_ip   = s_meta.dst_ip;
  assign flow_key.protocol = s_meta.protocol;
  assign flow_key.src_port = s_meta.src_port;
  assign flow_key.dst_port = s_meta.dst_port;

  // -------------------------------------------------------------------------
  // Toeplitz hash: 32-entry random secret key
  // -------------------------------------------------------------------------
  localparam logic [31:0] TOEPLITZ_KEY [32] = '{
    32'hddaa3f5a, 32'h7c7e2b4a, 32'h8b4e9f1c, 32'hd1e3a8b6,
    32'h5f2c7d90, 32'ha1b3c4d5, 32'he6f70819, 32'h2a3b4c5d,
    32'h6e7f8091, 32'ha2b3c4d5, 32'he6f71829, 32'h3a4b5c6d,
    32'h7e8f9012, 32'hb3c4d5e6, 32'hf718293a, 32'h4b5c6d7e,
    32'h8f901234, 32'hc4d5e6f7, 32'h18293a4b, 32'h5c6d7e8f,
    32'h90123456, 32'hd5e6f718, 32'h293a4b5c, 32'h6d7e8f90,
    32'ha2345678, 32'he6f71829, 32'h3a4b5c6d, 32'h7e8f90a1,
    32'hb2345678, 32'hf718293a, 32'h4b5c6d7e, 32'h8f90a1b2
  };

  // Pad 5-tuple to 128 bits (4 words), convolve with key
  logic [31:0] tuple_words [3:0];
  assign tuple_words[0] = flow_key.src_ip;
  assign tuple_words[1] = flow_key.dst_ip;
  assign tuple_words[2] = {flow_key.protocol, flow_key.src_port, 8'h00};
  assign tuple_words[3] = {8'h00, flow_key.dst_port, 8'h00, 8'h00};

  logic [31:0] hash_accum;
  logic [LOG2_SETS-1:0] set_idx;

  always_comb begin
    hash_accum = '0;
    for (int w = 0; w < 4; w++) begin
      hash_accum = hash_accum ^ (tuple_words[w] ^ TOEPLITZ_KEY[w * 8]);
    end
    // Fold to LOG2_SETS bits
    for (int s = LOG2_SETS; s < 32; s = s + LOG2_SETS) begin
      hash_accum[LOG2_SETS-1:0] = hash_accum[LOG2_SETS-1:0] ^ hash_accum[s +: LOG2_SETS];
    end
  end
  assign set_idx = hash_accum[LOG2_SETS-1:0];

  // -------------------------------------------------------------------------
  // Lookup: check both ways
  // -------------------------------------------------------------------------
  wire update_en = s_tvalid && s_tready && s_tlast;

  flow_entry_t rd_entry [NUM_WAYS-1:0];
  logic        way_hit [NUM_WAYS-1:0];

  assign rd_entry[0] = flow_ram[0][set_idx];
  assign rd_entry[1] = flow_ram[1][set_idx];

  assign way_hit[0]  = rd_entry[0].valid && (rd_entry[0].key == flow_key);
  assign way_hit[1]  = rd_entry[1].valid && (rd_entry[1].key == flow_key);

  assign flow_hit = way_hit[0] || way_hit[1];

  // -------------------------------------------------------------------------
  // Update on packet end
  // -------------------------------------------------------------------------
  logic [47:0]  hit_pkt_cnt;
  logic [63:0]  hit_byte_cnt;

  assign hit_pkt_cnt  = way_hit[0] ? rd_entry[0].packet_count : rd_entry[1].packet_count;
  assign hit_byte_cnt = way_hit[0] ? rd_entry[0].byte_count  : rd_entry[1].byte_count;

  assign flow_packets = hit_pkt_cnt;
  assign flow_bytes   = hit_byte_cnt;

  integer w, s;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (w = 0; w < NUM_WAYS; w++) begin
        for (s = 0; s < NUM_SETS; s++) begin
          flow_ram[w][s] <= '0;
        end
      end
      lru <= '0;
    end else if (update_en) begin
      if (flow_hit) begin
        // Update hit entry
        for (w = 0; w < NUM_WAYS; w++) begin
          if (way_hit[w]) begin
            flow_ram[w][set_idx].packet_count <= hit_pkt_cnt + 1'b1;
            flow_ram[w][set_idx].byte_count   <= hit_byte_cnt + s_meta.pkt_length;
            // Update LRU: make this way the most recently used
            lru[set_idx] <= (w == 0) ? 1'b1 : 1'b0;
          end
        end
      end else begin
        // Miss: insert into LRU way
        w = lru[set_idx] ? 0 : 1;  // insert into LRU way
        flow_ram[w][set_idx].valid         <= 1'b1;
        flow_ram[w][set_idx].key           <= flow_key;
        flow_ram[w][set_idx].packet_count  <= 48'd1;
        flow_ram[w][set_idx].byte_count    <= s_meta.pkt_length;
        // Flip LRU for next eviction
        lru[set_idx] <= ~lru[set_idx];
      end
    end
  end

  // -------------------------------------------------------------------------
  // Data passthrough
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
