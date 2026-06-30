`timescale 1ns/1ps
module tb;
  reg clk = 0;
  always #5 clk = ~clk;

  // ARAM client
  reg  [21:0] aram_addr = 0;
  reg         aram_we = 0, aram_re = 0, aram_hi = 0, aram_lo = 0;
  reg  [15:0] aram_di = 0;
  wire [15:0] aram_do;
  wire        aram_ra;

  // Scratch (SS_DDR) client
  reg  [21:3] ss_addr = 0;
  reg         ss_we = 0;
  reg  [63:0] ss_do = 0;
  reg  [ 7:0] ss_be = 8'hFF;
  reg         ss_req = 0;
  wire [63:0] ss_di;
  wire        ss_ack;

  wire [21:16] cram_a;  wire [15:0] cram_dq;
  wire cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n, cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;

  ss_psram_arbiter dut (
    .clk(clk),
    .aram_addr(aram_addr), .aram_write_en(aram_we), .aram_data_in(aram_di),
    .aram_write_high_byte(aram_hi), .aram_write_low_byte(aram_lo), .aram_read_en(aram_re),
    .aram_data_out(aram_do), .aram_read_avail(aram_ra),
    .ss_ddr_addr(ss_addr), .ss_ddr_we(ss_we), .ss_ddr_do(ss_do), .ss_ddr_be(ss_be),
    .ss_ddr_req(ss_req), .ss_ddr_di(ss_di), .ss_ddr_ack(ss_ack),
    .cram_a(cram_a), .cram_dq(cram_dq), .cram_wait(1'b0), .cram_clk(cram_clk),
    .cram_adv_n(cram_adv_n), .cram_cre(cram_cre), .cram_ce0_n(cram_ce0_n), .cram_ce1_n(cram_ce1_n),
    .cram_oe_n(cram_oe_n), .cram_we_n(cram_we_n), .cram_ub_n(cram_ub_n), .cram_lb_n(cram_lb_n)
  );

  // ARAM hammer: when enabled, grab the psram whenever the arbiter is idle,
  // modelling the SPC700 continuously reading ARAM (creates contention).
  reg aram_enable = 0;
  always @(posedge clk) begin
    aram_re <= 0;
    if (aram_enable && dut.state == 3'd0 && !dut.ps_busy && !aram_re) begin
      aram_addr <= 22'h000020;
      aram_re   <= 1'b1;
    end
  end

  // Cycle trace of the first ~90 cycles
  integer cyc = 0;
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (cyc < 90)
      $display("cyc %0d | arb.state=%0d sub=%0d ps_busy=%b ps_we=%b ps_re=%b | psram.st=%0d cnt=%0d busy=%b | ss_req=%b req_s2=%b ack=%b",
        cyc, dut.state, dut.sub, dut.ps_busy, dut.ps_write_en, dut.ps_read_en,
        dut.psram.st, dut.psram.cnt, dut.psram.busy, ss_req, dut.req_s2, ss_ack);
  end

  integer guard;
  task scratch_op(input we, input [21:3] a, input [63:0] d);
    begin
      @(posedge clk);
      ss_we   <= we;
      ss_addr <= a;
      ss_do   <= d;
      ss_req  <= ~ss_req;
      @(posedge clk);
      guard = 0;
      while (ss_ack !== ss_req && guard < 2000) begin @(posedge clk); guard = guard + 1; end
      if (guard >= 2000) $display("  [HANG] op we=%0d addr=%05x never acked", we, a);
    end
  endtask

  integer k, errors;
  reg [63:0] got, expected;

  initial begin
    repeat (5) @(posedge clk);

    $display("=== TEST A: scratch round-trip, NO ARAM contention ===");
    aram_enable = 0; errors = 0;
    for (k = 0; k < 16; k = k + 1) scratch_op(1'b1, k[18:0], {32'h534E4553, 32'(k)});
    for (k = 0; k < 16; k = k + 1) begin
      scratch_op(1'b0, k[18:0], 64'h0);
      got = ss_di; expected = {32'h534E4553, 32'(k)};
      if (got !== expected) begin $display("  MISMATCH idx %0d: got %h exp %h", k, got, expected); errors = errors + 1; end
    end
    $display("TEST A result: %0d errors", errors);

    $display("=== TEST B: scratch round-trip WITH ARAM hammering (the race) ===");
    aram_enable = 1; errors = 0;
    for (k = 0; k < 16; k = k + 1) scratch_op(1'b1, (k+100), {32'h534E4553, 32'(k+100)});
    for (k = 0; k < 16; k = k + 1) begin
      scratch_op(1'b0, (k+100), 64'h0);
      got = ss_di; expected = {32'h534E4553, 32'(k+100)};
      if (got !== expected) begin $display("  MISMATCH idx %0d: got %h exp %h", k+100, got, expected); errors = errors + 1; end
    end
    $display("TEST B result: %0d errors", errors);

    $display("DONE");
    $finish;
  end

  initial begin #500000 $display("GLOBAL TIMEOUT"); $finish; end
endmodule
