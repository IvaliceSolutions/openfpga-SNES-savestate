//
// ss_glue_fsm — bridges the openFPGA save_state_controller (sequential FIFO
// streaming) to paulb-nl's engine (self-driven, random-access PSRAM scratch).
//
//   SAVE: controller pulses ss_save -> glue pulses engine eng_save -> engine
//         writes the blob to PSRAM scratch (eng_busy) -> glue reads the scratch
//         word by word and streams it to the controller (ss_din/ss_req) -> the
//         controller ships it to the SD "Memory" file.
//   LOAD: reverse — glue pulls the blob from the controller into the scratch,
//         then pulses engine eng_load to restore.
//
// The single arbiter SS_DDR port is time-multiplexed: the engine owns it during
// capture/restore, the glue owns it during the blob transfer (never both).
//
// Controller ss_ bus = PULSE handshake (ss_req high 1 cyc, ss_ack pulses).
// Arbiter SS_DDR     = TOGGLE handshake (req != ack means busy). Glue adapts.
//
// J1b-2c. Runs on the core clock (= controller ss_ bus clock = engine MCLK).
// NOTE: first-cut bring-up module — expect hardware-debug iterations.
//
module ss_glue_fsm #(
    parameter [31:0] SS_SIZE_BYTES = 32'h00100000  // must match core.json savestate_size
) (
    input  wire        clk,
    input  wire        reset_n,

    // ---- save_state_controller side (glue is the "core") ----
    input  wire        ss_save,
    input  wire        ss_load,
    input  wire [63:0] ss_dout,    // controller -> glue (load data)
    output reg  [63:0] ss_din,     // glue -> controller (save data)
    output reg  [25:0] ss_addr,
    output reg         ss_rnw,
    output reg         ss_req,
    output reg  [ 7:0] ss_be,
    input  wire        ss_ack,
    output reg         ss_busy,

    // ---- engine trigger side ----
    output reg         eng_save,
    output reg         eng_load,
    input  wire        eng_busy,

    // ---- engine's SS_DDR (passthrough when engine owns the bus) ----
    input  wire [21:3] eng_ddr_addr,
    input  wire        eng_ddr_we,
    input  wire [63:0] eng_ddr_do,
    input  wire [ 7:0] eng_ddr_be,
    input  wire        eng_ddr_req,
    output wire [63:0] eng_ddr_di,
    output wire        eng_ddr_ack,

    // ---- arbiter SS_DDR (PSRAM scratch) ----
    output wire [21:3] arb_ddr_addr,
    output wire        arb_ddr_we,
    output wire [63:0] arb_ddr_do,
    output wire [ 7:0] arb_ddr_be,
    output wire        arb_ddr_req,
    input  wire [63:0] arb_ddr_di,
    input  wire        arb_ddr_ack
);
  localparam [25:0] SS_WORDS = SS_SIZE_BYTES[28:3];  // number of 64-bit words

  reg        glue_owns_ddr;
  reg [21:3] g_addr;
  reg        g_we;
  reg [63:0] g_do;
  reg        g_req;          // toggles to launch an arbiter access

  // SS_DDR mux (engine passthrough vs glue)
  assign arb_ddr_addr = glue_owns_ddr ? g_addr : eng_ddr_addr;
  assign arb_ddr_we   = glue_owns_ddr ? g_we   : eng_ddr_we;
  assign arb_ddr_do   = glue_owns_ddr ? g_do   : eng_ddr_do;
  assign arb_ddr_be   = glue_owns_ddr ? 8'hFF  : eng_ddr_be;
  assign arb_ddr_req  = glue_owns_ddr ? g_req  : eng_ddr_req;
  assign eng_ddr_di   = arb_ddr_di;
  assign eng_ddr_ack  = glue_owns_ddr ? 1'b0   : arb_ddr_ack;

  wire arb_busy = (g_req != arb_ddr_ack);  // toggle handshake

  localparam S_IDLE      = 4'd0;
  localparam S_SAVE_WAIT = 4'd1;   // wait engine capture done
  localparam S_SAVE_RD   = 4'd2;   // launch scratch read
  localparam S_SAVE_RDW  = 4'd3;   // wait read ack
  localparam S_SAVE_PUSH = 4'd4;   // push word to controller
  localparam S_SAVE_PUSHW= 4'd5;   // wait controller ack
  localparam S_LOAD_PULL = 4'd6;   // request word from controller
  localparam S_LOAD_PULLW= 4'd7;   // wait controller ack
  localparam S_LOAD_WR   = 4'd8;   // launch scratch write
  localparam S_LOAD_WRW  = 4'd9;   // wait write ack
  localparam S_LOAD_ENG  = 4'd10;  // pulse engine load, wait done
  localparam S_DONE      = 4'd11;

  reg [3:0]  state;
  reg [25:0] idx;
  reg        eng_busy_d;
  reg        eng_load_started;

  always @(posedge clk or negedge reset_n) begin
    if (~reset_n) begin
      state <= S_IDLE; ss_busy <= 0; ss_req <= 0; eng_save <= 0; eng_load <= 0;
      glue_owns_ddr <= 0; g_req <= 0; g_we <= 0; idx <= 0; eng_load_started <= 0;
    end else begin
      eng_save <= 0;
      eng_load <= 0;
      ss_req   <= 0;
      eng_busy_d <= eng_busy;

      case (state)
        S_IDLE: begin
          ss_busy <= 0; glue_owns_ddr <= 0; idx <= 0; eng_load_started <= 0;
          if (ss_save) begin
            ss_busy <= 1; eng_save <= 1; state <= S_SAVE_WAIT;
          end else if (ss_load) begin
            ss_busy <= 1; glue_owns_ddr <= 1; ss_rnw <= 1; state <= S_LOAD_PULL;
          end
        end

        // ---------------- SAVE ----------------
        S_SAVE_WAIT: begin
          // engine asserts eng_busy during capture; falling edge = done
          if (eng_busy_d && ~eng_busy) begin
            glue_owns_ddr <= 1; idx <= 0; state <= S_SAVE_RD;
          end
        end
        S_SAVE_RD: begin
          if (~arb_busy) begin
            g_addr <= idx[18:0]; g_we <= 0; g_req <= ~g_req; state <= S_SAVE_RDW;
          end
        end
        S_SAVE_RDW: begin
          if (~arb_busy) begin
            ss_din <= arb_ddr_di; ss_addr <= idx; ss_rnw <= 0; ss_be <= 8'hFF;
            ss_req <= 1; state <= S_SAVE_PUSHW;
          end
        end
        S_SAVE_PUSHW: begin
          if (ss_ack) begin
            if (idx == SS_WORDS - 1) state <= S_DONE;
            else begin idx <= idx + 1'b1; state <= S_SAVE_RD; end
          end
        end

        // ---------------- LOAD ----------------
        S_LOAD_PULL: begin
          ss_addr <= idx; ss_rnw <= 1; ss_req <= 1; state <= S_LOAD_PULLW;
        end
        S_LOAD_PULLW: begin
          if (ss_ack) begin
            g_do <= ss_dout; state <= S_LOAD_WR;
          end
        end
        S_LOAD_WR: begin
          if (~arb_busy) begin
            g_addr <= idx[18:0]; g_we <= 1; g_req <= ~g_req; state <= S_LOAD_WRW;
          end
        end
        S_LOAD_WRW: begin
          if (~arb_busy) begin
            if (idx == SS_WORDS - 1) begin
              glue_owns_ddr <= 0; state <= S_LOAD_ENG;
            end else begin
              idx <= idx + 1'b1; state <= S_LOAD_PULL;
            end
          end
        end
        S_LOAD_ENG: begin
          if (~eng_load_started) begin
            eng_load <= 1; eng_load_started <= 1;
          end else if (eng_busy_d && ~eng_busy) begin
            state <= S_DONE;
          end
        end

        S_DONE: begin
          ss_busy <= 0; glue_owns_ddr <= 0; state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
