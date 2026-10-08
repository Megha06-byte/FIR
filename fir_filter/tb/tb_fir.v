// -----------------------------------------------------------------------------
// tb_fir : self-checking testbench, shared by all three FIR variants
//
//   compile with  -DDUT=fir_direct | fir_folded | fir_pipe
//   +GAPS=1   randomly deasserts in_valid (~30%) to test flow control
//   +VCD=1    dumps activity for power analysis
//
// Streams the full stimulus set (filtered test signal, impulse, negative
// full-scale step, full-scale random) and compares every output sample with
// the Python golden model. The impulse response must equal the coefficients.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "nsamp.vh"
`ifndef DUT
`define DUT fir_pipe
`endif

module tb_fir;
    localparam NS = `NSAMP;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;                         // 100 MHz

    reg                in_valid = 0;
    reg  signed [15:0] x_in = 0;
    wire               out_valid;
    wire signed [15:0] y_out;

    `DUT dut (.clk(clk), .rst(rst), .in_valid(in_valid), .x_in(x_in),
              .out_valid(out_valid), .y_out(y_out));

    reg [15:0] xm [0:NS-1];
    reg [15:0] ym [0:NS-1];
    integer n_in = 0, n_out = 0, errors = 0, gaps = 0, vcd = 0, seed = 1;
    integer first_in = -1, first_out = -1, cyc = 0;

    always @(posedge clk) cyc <= cyc + 1;

    initial begin
        $readmemh("x.hex", xm);
        $readmemh("y_gold.hex", ym);
        if (!$value$plusargs("GAPS=%d", gaps)) gaps = 0;
        if (!$value$plusargs("VCD=%d", vcd))   vcd = 0;
        if (vcd) begin $dumpfile("fir.vcd"); $dumpvars(0, tb_fir.dut); end
        // hold reset 200 ns: Xilinx netlist sims keep all flops in global
        // set/reset (GSR) for the first 100 ns, so inputs sent earlier are lost
        repeat (20) @(posedge clk);
        rst <= 0;
        @(posedge clk);
        while (n_in < NS) begin
            if (gaps && ({$random(seed)} % 10) < 3) begin
                in_valid <= 0;
            end else begin
                in_valid <= 1; x_in <= xm[n_in];
                if (first_in < 0) first_in = cyc + 1;
                n_in = n_in + 1;
            end
            @(posedge clk);
        end
        in_valid <= 0;
    end

    always @(posedge clk) if (out_valid) begin
        if (first_out < 0) first_out = cyc;
        if (y_out !== $signed(ym[n_out])) begin
            if (errors < 10)
                $display("MISMATCH sample %0d: rtl %0d golden %0d", n_out, y_out, $signed(ym[n_out]));
            errors = errors + 1;
        end
        n_out = n_out + 1;
        if (n_out == NS) begin
            $display("RESULT samples=%0d errors=%0d latency=%0d gaps=%0d",
                     NS, errors, first_out - first_in, gaps);
            if (errors == 0) $display("PASS"); else $display("FAIL");
            $finish;
        end
    end

    initial begin #10_000_000; $display("TIMEOUT n_out=%0d", n_out); $finish; end
endmodule
