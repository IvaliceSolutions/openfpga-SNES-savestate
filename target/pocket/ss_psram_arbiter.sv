//
// ss_psram_arbiter — shares one PSRAM chip (cram1) between:
//   - the SNES ARAM (16-bit, die 0 / bank_sel=0)  — the live client
//   - the save-state scratch (64-bit SS_DDR interface, die 1 / bank_sel=1)
//
// The scratch is only exercised during a save state (when the SNES is paused),
// so the arbiter is a TRANSPARENT pass-through to ARAM whenever no scratch
// request is pending (zero added latency for normal play). When the engine
// asserts a request (ss_ddr_req toggles vs ss_ddr_ack), the arbiter takes the
// bus, performs the 64-bit access as 4x 16-bit PSRAM accesses on die 1, then
// toggles ss_ddr_ack and returns to ARAM.
//
// J1b-2b. Wraps one `psram` instance and drives the real cram1 pins.
//
module ss_psram_arbiter (
    input wire clk,

    // ---- ARAM client (16-bit, die 0) — same signals the psram inst used ----
    input  wire [21:0] aram_addr,
    input  wire        aram_write_en,
    input  wire [15:0] aram_data_in,
    input  wire        aram_write_high_byte,
    input  wire        aram_write_low_byte,
    input  wire        aram_read_en,
    output wire [15:0] aram_data_out,
    output wire        aram_read_avail,

    // ---- Save-state scratch (64-bit SS_DDR interface, die 1) ----
    input  wire [21:3] ss_ddr_addr,   // 64-bit word address from the engine
    input  wire        ss_ddr_we,
    input  wire [63:0] ss_ddr_do,     // engine -> scratch (write data)
    input  wire [ 7:0] ss_ddr_be,
    input  wire        ss_ddr_req,     // toggles to request
    output reg  [63:0] ss_ddr_di,     // scratch -> engine (read data)
    output reg         ss_ddr_ack,    // toggles to acknowledge

    // ---- Real PSRAM (cram1) pins ----
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

  // Base 16-bit-word offset of the scratch within die 1 (die 1 is otherwise
  // unused). A 64-bit word maps to 4 consecutive 16-bit words.
  // scratch psram word addr = {ss_ddr_addr[20:3], sub[1:0]}  (<= 1 MiB region)

  // -- Arbiter state --
  localparam ST_IDLE   = 3'd0;  // ARAM pass-through
  localparam ST_START  = 3'd1;  // launch a 16-bit sub-access
  localparam ST_WAIT   = 3'd2;  // wait for psram to finish
  localparam ST_NEXT   = 3'd3;  // capture/advance
  localparam ST_DONE   = 3'd4;  // toggle ack

  reg  [2:0] state = ST_IDLE;
  reg  [1:0] sub;               // which 16-bit word of the 64-bit beat (0..3)
  reg        req_seen;          // latched ss_ddr_req level we're servicing
  reg [63:0] wdata;            // latched write data
  reg [21:3] waddr;           // latched 64-bit word address
  reg        wwe;
  reg [ 7:0] wbe;

  wire scratch_pending = (ss_ddr_req != ss_ddr_ack) && (state == ST_IDLE);

  // -- PSRAM driver muxing: ARAM when idle, FSM when servicing scratch --
  reg         ps_bank_sel;
  reg  [21:0] ps_addr;
  reg         ps_write_en;
  reg  [15:0] ps_data_in;
  reg         ps_wr_hi, ps_wr_lo;
  reg         ps_read_en;
  wire [15:0] ps_data_out;
  wire        ps_read_avail;
  wire        ps_busy;

  always @(*) begin
    if (state == ST_IDLE) begin
      // Transparent ARAM pass-through (die 0)
      ps_bank_sel = 1'b0;
      ps_addr     = aram_addr;
      ps_write_en = aram_write_en;
      ps_data_in  = aram_data_in;
      ps_wr_hi    = aram_write_high_byte;
      ps_wr_lo    = aram_write_low_byte;
      ps_read_en  = aram_read_en;
    end else begin
      // Scratch sub-access (die 1)
      ps_bank_sel = 1'b1;
      ps_addr     = {waddr[20:3], sub};
      ps_write_en = (state == ST_START) && wwe;
      ps_data_in  = wdata[sub*16 +: 16];
      ps_wr_hi    = wbe[sub*2+1];
      ps_wr_lo    = wbe[sub*2+0];
      ps_read_en  = (state == ST_START) && ~wwe;
    end
  end

  assign aram_data_out   = ps_data_out;
  assign aram_read_avail = (state == ST_IDLE) ? ps_read_avail : 1'b0;

  always @(posedge clk) begin
    case (state)
      ST_IDLE: begin
        if (scratch_pending && ~ps_busy) begin
          waddr <= ss_ddr_addr;
          wwe   <= ss_ddr_we;
          wdata <= ss_ddr_do;
          wbe   <= ss_ddr_be;
          sub   <= 2'd0;
          state <= ST_START;
        end
      end

      ST_START: begin
        // psram latches the op this cycle (it goes busy next cycle)
        state <= ST_WAIT;
      end

      ST_WAIT: begin
        if (~ps_busy) begin
          if (~wwe && ps_read_avail) ss_ddr_di[sub*16 +: 16] <= ps_data_out;
          state <= ST_NEXT;
        end
      end

      ST_NEXT: begin
        if (sub == 2'd3) begin
          state <= ST_DONE;
        end else begin
          sub   <= sub + 2'd1;
          state <= ST_START;
        end
      end

      ST_DONE: begin
        ss_ddr_ack <= ss_ddr_req;  // toggle to match -> request complete
        state <= ST_IDLE;
      end

      default: state <= ST_IDLE;
    endcase
  end

  psram #(
      .CLOCK_SPEED(85.9)
  ) psram (
      .clk(clk),
      .bank_sel(ps_bank_sel),
      .addr(ps_addr),
      .write_en(ps_write_en),
      .data_in(ps_data_in),
      .write_high_byte(ps_wr_hi),
      .write_low_byte(ps_wr_lo),
      .read_en(ps_read_en),
      .read_avail(ps_read_avail),
      .data_out(ps_data_out),
      .busy(ps_busy),

      .cram_a(cram_a),
      .cram_dq(cram_dq),
      .cram_wait(cram_wait),
      .cram_clk(cram_clk),
      .cram_adv_n(cram_adv_n),
      .cram_cre(cram_cre),
      .cram_ce0_n(cram_ce0_n),
      .cram_ce1_n(cram_ce1_n),
      .cram_oe_n(cram_oe_n),
      .cram_we_n(cram_we_n),
      .cram_ub_n(cram_ub_n),
      .cram_lb_n(cram_lb_n)
  );

endmodule
