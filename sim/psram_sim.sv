// Behavioural model of psram.sv for simulation: same module-facing interface
// and the same busy/read_avail HANDSHAKE semantics as the real cellular PSRAM
// driver, but backed by a simple memory array (no physical cram protocol).
// Memory is initialised to 0xFFFF to mimic uninitialised PSRAM.
module psram #(
    parameter CLOCK_SPEED = 85.9
) (
    input  wire        clk,
    input  wire        bank_sel,
    input  wire [21:0] addr,
    input  wire        write_en,
    input  wire [15:0] data_in,
    input  wire        write_high_byte,
    input  wire        write_low_byte,
    input  wire        read_en,
    output reg         read_avail,
    output reg  [15:0] data_out,
    output reg         busy,
    // cram pins (ignored in sim)
    output wire [21:16] cram_a,
    inout  wire [15:0]  cram_dq,
    input  wire         cram_wait,
    output wire         cram_clk,
    output wire         cram_adv_n,
    output wire         cram_cre,
    output wire         cram_ce0_n,
    output wire         cram_ce1_n,
    output wire         cram_oe_n,
    output wire         cram_we_n,
    output wire         cram_ub_n,
    output wire         cram_lb_n
);
  // 64K-word window per die is plenty for the test
  reg [15:0] mem0 [0:65535];
  reg [15:0] mem1 [0:65535];
  integer i;

  localparam IDLE = 0, WBUSY = 1, RBUSY = 2;
  reg [1:0] st;
  reg [7:0] cnt;
  reg [21:0] a_l;
  reg [15:0] d_l;
  reg        b_l, hi_l, lo_l;

  initial begin
    for (i = 0; i < 65536; i = i + 1) begin mem0[i] = 16'hFFFF; mem1[i] = 16'hFFFF; end
    st = IDLE; busy = 0; read_avail = 0; data_out = 0;
  end

  always @(posedge clk) begin
    read_avail <= 0;
    case (st)
      IDLE: begin
        busy <= 0;
        if (write_en) begin
          a_l <= addr; d_l <= data_in; b_l <= bank_sel;
          hi_l <= write_high_byte; lo_l <= write_low_byte;
          st <= WBUSY; cnt <= 6; busy <= 1;       // ~7-cycle write
        end else if (read_en) begin
          a_l <= addr; b_l <= bank_sel;
          st <= RBUSY; cnt <= 21; busy <= 1;       // ~22-cycle read
        end
      end
      WBUSY: begin
        if (cnt == 0) begin
          if (b_l) begin
            if (hi_l) mem1[a_l[15:0]][15:8] <= d_l[15:8];
            if (lo_l) mem1[a_l[15:0]][7:0]  <= d_l[7:0];
          end else begin
            if (hi_l) mem0[a_l[15:0]][15:8] <= d_l[15:8];
            if (lo_l) mem0[a_l[15:0]][7:0]  <= d_l[7:0];
          end
          busy <= 0; st <= IDLE;
        end else cnt <= cnt - 1;
      end
      RBUSY: begin
        if (cnt == 0) begin
          data_out   <= b_l ? mem1[a_l[15:0]] : mem0[a_l[15:0]];
          read_avail <= 1; busy <= 0; st <= IDLE;
        end else cnt <= cnt - 1;
      end
    endcase
  end

  assign cram_a = 0; assign cram_dq = 16'hzzzz; assign cram_clk = 0;
  assign cram_adv_n = 1; assign cram_cre = 0; assign cram_ce0_n = 1;
  assign cram_ce1_n = 1; assign cram_oe_n = 1; assign cram_we_n = 1;
  assign cram_ub_n = 1; assign cram_lb_n = 1;
endmodule
