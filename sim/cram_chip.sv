`timescale 1ns/1ps
// Behavioural model of the async cellular PSRAM chip (2 dies via ce0_n/ce1_n)
// as driven by the real psram.sv:
//   - address is latched on the RISING edge of adv_n while a die is selected
//     (high bits on cram_a[21:16], low bits on cram_dq[15:0])
//   - reads: while oe_n low (we_n high) the chip drives cram_dq = mem[addr]
//   - writes: data on cram_dq is committed to mem on the rising edge of we_n
//   - ub_n/lb_n are the byte enables
module cram_chip (
    input  wire [21:16] cram_a,
    inout  wire [15:0]  cram_dq,
    output wire         cram_wait,
    input  wire         cram_clk,
    input  wire         cram_adv_n,
    input  wire         cram_cre,
    input  wire         cram_ce0_n,
    input  wire         cram_ce1_n,
    input  wire         cram_oe_n,
    input  wire         cram_we_n,
    input  wire         cram_ub_n,
    input  wire         cram_lb_n
);
  assign cram_wait = 1'b0;

  reg [15:0] mem0 [0:65535];
  reg [15:0] mem1 [0:65535];
  reg [21:0] addr_l;
  reg        bank_l;
  reg [15:0] wdata_hold;
  integer i;

  wire ce0 = ~cram_ce0_n;
  wire ce1 = ~cram_ce1_n;
  wire ce  = ce0 | ce1;

  initial begin
    for (i = 0; i < 65536; i = i + 1) begin mem0[i] = 16'hFFFF; mem1[i] = 16'hFFFF; end
    addr_l = 0; bank_l = 0; wdata_hold = 0;
  end

  // Latch address on adv_n rising edge while a die is selected
  always @(posedge cram_adv_n) begin
    if (ce) begin
      addr_l <= {cram_a, cram_dq};
      bank_l <= ce1;
    end
  end

  // Read: drive dq when output-enabled and selected (and not writing)
  wire        do_read = ce && ~cram_oe_n && cram_we_n;
  wire [15:0] rdata   = bank_l ? mem1[addr_l[15:0]] : mem0[addr_l[15:0]];
  assign cram_dq = do_read ? rdata : 16'hzzzz;
  always @(negedge cram_oe_n) if (ce) $display("  CRAM READ die%0d addr=%05x => %04x", bank_l, addr_l, rdata);

  // Track write data AND byte enables while we_n is low (the controller drives
  // them); commit on the rising edge using the held values.
  reg ub_hold, lb_hold;
  always @(*) if (ce && ~cram_we_n) begin
    wdata_hold = cram_dq;
    ub_hold = ~cram_ub_n;
    lb_hold = ~cram_lb_n;
  end
  always @(posedge cram_we_n) begin
    if (ce) begin
      $display("  CRAM WRITE die%0d addr=%05x <= %04x (ub=%b lb=%b)", bank_l, addr_l, wdata_hold, ub_hold, lb_hold);
      if (bank_l) begin
        if (ub_hold) mem1[addr_l[15:0]][15:8] <= wdata_hold[15:8];
        if (lb_hold) mem1[addr_l[15:0]][7:0]  <= wdata_hold[7:0];
      end else begin
        if (ub_hold) mem0[addr_l[15:0]][15:8] <= wdata_hold[15:8];
        if (lb_hold) mem0[addr_l[15:0]][7:0]  <= wdata_hold[7:0];
      end
    end
  end
endmodule
