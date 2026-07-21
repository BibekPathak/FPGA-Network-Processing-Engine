module packet_modifier #(
    parameter int DATA_WIDTH = 512
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
    input  modifier_action_t            s_mod_action,
    input  modifier_data_t              s_mod_data
);

  import npe_pkg::*;

  localparam int KEEP_W = DATA_WIDTH / 8;

  function automatic logic [7:0]  byte_at(logic [DATA_WIDTH-1:0] d, int i);
    return d[i*8 +: 8];
  endfunction
  function automatic logic [15:0] word16_be(logic [DATA_WIDTH-1:0] d, int i);
    return {d[i*8 +: 8], d[(i+1)*8 +: 8]};
  endfunction

  logic [5:0] ip_off;
  assign ip_off = s_meta.vlan_valid ? 18 : 14;

  // -------------------------------------------------------------------------
  // First-beat detection: prev_tlast is 1 when the PREVIOUS cycle's tlast was
  // asserted, meaning the current cycle is the first beat of a new packet.
  // -------------------------------------------------------------------------
  logic prev_tlast;
  always_ff @(posedge clk) begin
    if (!rst_n) prev_tlast <= 1'b1;
    else if (s_tvalid) prev_tlast <= s_tlast;
  end

  wire do_mod = s_tvalid && s_tready && prev_tlast;

  // -------------------------------------------------------------------------
  // Modification logic (combinational, applied to s_tdata)
  // The result (mod_tdata) is captured by the pipeline register on the
  // same posedge — so the modification takes effect immediately.
  // -------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0]  mod_tdata;
  logic [KEEP_W-1:0]      mod_tkeep;
  logic [7:0]  ttl_val;
  logic [15:0] csum_val;

  always_comb begin
    mod_tdata = s_tdata;
    mod_tkeep = s_tkeep;

    if (do_mod) begin
      case (s_mod_action)
        MOD_TTL_DEC: begin
          ttl_val = byte_at(s_tdata, ip_off + 8);
          mod_tdata[(ip_off+8)*8 +: 8] = ttl_val - 1'b1;
          csum_val = word16_be(s_tdata, ip_off + 10);
          mod_tdata[(ip_off+11)*8-1 -: 8] = csum_val[15:8] + 1'b1;
          mod_tdata[(ip_off+10)*8 +: 8] = csum_val[7:0];
        end
        MOD_MAC_SWAP: begin
          mod_tdata[0*8 +: 8] = byte_at(s_tdata, 6);
          mod_tdata[1*8 +: 8] = byte_at(s_tdata, 7);
          mod_tdata[2*8 +: 8] = byte_at(s_tdata, 8);
          mod_tdata[3*8 +: 8] = byte_at(s_tdata, 9);
          mod_tdata[4*8 +: 8] = byte_at(s_tdata, 10);
          mod_tdata[5*8 +: 8] = byte_at(s_tdata, 11);
          mod_tdata[6*8 +: 8] = byte_at(s_tdata, 0);
          mod_tdata[7*8 +: 8] = byte_at(s_tdata, 1);
          mod_tdata[8*8 +: 8] = byte_at(s_tdata, 2);
          mod_tdata[9*8 +: 8] = byte_at(s_tdata, 3);
          mod_tdata[10*8 +: 8] = byte_at(s_tdata, 4);
          mod_tdata[11*8 +: 8] = byte_at(s_tdata, 5);
        end
        MOD_MAC_SET: begin
          mod_tdata[0*8 +: 8] = s_mod_data.new_dst_mac[47:40];
          mod_tdata[1*8 +: 8] = s_mod_data.new_dst_mac[39:32];
          mod_tdata[2*8 +: 8] = s_mod_data.new_dst_mac[31:24];
          mod_tdata[3*8 +: 8] = s_mod_data.new_dst_mac[23:16];
          mod_tdata[4*8 +: 8] = s_mod_data.new_dst_mac[15:8];
          mod_tdata[5*8 +: 8] = s_mod_data.new_dst_mac[7:0];
          mod_tdata[6*8 +: 8] = s_mod_data.new_src_mac[47:40];
          mod_tdata[7*8 +: 8] = s_mod_data.new_src_mac[39:32];
          mod_tdata[8*8 +: 8] = s_mod_data.new_src_mac[31:24];
          mod_tdata[9*8 +: 8] = s_mod_data.new_src_mac[23:16];
          mod_tdata[10*8 +: 8] = s_mod_data.new_src_mac[15:8];
          mod_tdata[11*8 +: 8] = s_mod_data.new_src_mac[7:0];
        end
        MOD_IP_SET: begin
          mod_tdata[(ip_off+12)*8 +: 8] = s_mod_data.new_src_ip[31:24];
          mod_tdata[(ip_off+13)*8 +: 8] = s_mod_data.new_src_ip[23:16];
          mod_tdata[(ip_off+14)*8 +: 8] = s_mod_data.new_src_ip[15:8];
          mod_tdata[(ip_off+15)*8 +: 8] = s_mod_data.new_src_ip[7:0];
          mod_tdata[(ip_off+16)*8 +: 8] = s_mod_data.new_dst_ip[31:24];
          mod_tdata[(ip_off+17)*8 +: 8] = s_mod_data.new_dst_ip[23:16];
          mod_tdata[(ip_off+18)*8 +: 8] = s_mod_data.new_dst_ip[15:8];
          mod_tdata[(ip_off+19)*8 +: 8] = s_mod_data.new_dst_ip[7:0];
        end
        MOD_VLAN_PUSH: begin
          for (int i = KEEP_W-1; i >= 12; i--)
            mod_tdata[i*8 +: 8] = (i >= 16) ? byte_at(s_tdata, i-4) : 8'h00;
          mod_tdata[12*8 +: 8] = 8'h81;
          mod_tdata[13*8 +: 8] = 8'h00;
          mod_tdata[14*8 +: 8] = {s_mod_data.vlan_prio, 1'b0, s_mod_data.vlan_id[11:8]};
          mod_tdata[15*8 +: 8] = s_mod_data.vlan_id[7:0];
          for (int i = KEEP_W-1; i >= 12; i--)
            mod_tkeep[i] = (i >= 16) ? s_tkeep[i-4] : 1'b1;
        end
        MOD_VLAN_POP: begin
          for (int i = 12; i < KEEP_W; i++)
            mod_tdata[i*8 +: 8] = (i+4 < KEEP_W) ? byte_at(s_tdata, i+4) : 8'h00;
          for (int i = 12; i < KEEP_W; i++)
            mod_tkeep[i] = (i+4 < KEEP_W) ? s_tkeep[i+4] : 1'b0;
        end
        default: ;
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Pipeline register
  // -------------------------------------------------------------------------
  logic                            pipe_valid;
  logic [DATA_WIDTH-1:0]           pipe_tdata;
  logic [KEEP_W-1:0]               pipe_tkeep;
  logic                            pipe_tlast;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pipe_valid <= '0;
    end else if (m_tready || !pipe_valid) begin
      pipe_tdata <= mod_tdata;
      pipe_tkeep <= mod_tkeep;
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
