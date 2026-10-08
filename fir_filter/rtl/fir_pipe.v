// -----------------------------------------------------------------------------
// fir_pipe : AREA + TIMING + POWER optimised FIR
//
// Same arithmetic as fir_folded (symmetric folding, zero taps pruned), with
// the long combinational path cut by pipeline registers:
//
//   S0 delay line -> S1 pre-add -> S2 multiply -> S3 4 partial sums
//                 -> S4 final add + round + saturate
//
// Each stage register loads only when its valid tag is set. When the input
// stream has gaps (in_valid low), the pipeline holds its values, so the
// datapath doesn't toggle and no dynamic power is spent.
// Latency 5 cycles, throughput 1 sample/clock, output bit-identical.
// -----------------------------------------------------------------------------
module fir_pipe (
    input                    clk,
    input                    rst,
    input                    in_valid,
    input      signed [15:0] x_in,
    output reg               out_valid,
    output reg signed [15:0] y_out
);
`include "fir_coeffs.vh"
    localparam ACCW = 32;
    localparam NP   = NTAP / 2;
    localparam NG   = 4;                     // partial-sum groups in S3

    reg signed [15:0] d [0:NTAP-1];
    reg v0, v1, v2, v3;
    integer i;

    // ---------------- S0: delay line
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < NTAP; i = i + 1) d[i] <= 16'sd0;   // history = 0
        end else if (in_valid) begin
            d[0] <= x_in;
            for (i = 1; i < NTAP; i = i + 1) d[i] <= d[i-1];
        end
    end

    // ---------------- S1 + S2: pre-add and multiply, one lane per non-zero coeff
    wire signed [ACCW-1:0] prod [0:NP];
    genvar k;
    generate
        for (k = 0; k <= NP; k = k + 1) begin : g_tap
            localparam signed [15:0] C = COEF[16*k +: 16];
            if (C == 0) begin : g_zero
                assign prod[k] = 0;
            end else begin : g_lane
                wire signed [16:0]     pre;
                reg  signed [16:0]     pre_q;
                reg  signed [ACCW-1:0] mul_q;
                if (k == NP) begin : g_centre
                    assign pre = {d[k][15], d[k]};             // sign-extend
                end else begin : g_pair
                    assign pre = {d[k][15], d[k]} + {d[NTAP-1-k][15], d[NTAP-1-k]};
                end
                always @(posedge clk) begin
                    if (v0) pre_q <= pre;
                    if (v1) mul_q <= pre_q * C;
                end
                assign prod[k] = mul_q;
            end
        end
    endgenerate

    // ---------------- S3: partial sums (lanes k = g, g+NG, g+2NG, ...)
    reg signed [ACCW-1:0] part   [0:NG-1];
    reg signed [ACCW-1:0] part_d [0:NG-1];
    integer g;
    always @* begin
        for (g = 0; g < NG; g = g + 1) begin
            part_d[g] = 0;
            for (i = g; i <= NP; i = i + NG) part_d[g] = part_d[g] + prod[i];
        end
    end
    always @(posedge clk)
        if (v2) for (g = 0; g < NG; g = g + 1) part[g] <= part_d[g];

    // ---------------- S4: final add, round, saturate
    reg signed [ACCW-1:0] acc;
    always @* begin
        acc = 0;
        for (g = 0; g < NG; g = g + 1) acc = acc + part[g];
    end
    wire signed [ACCW-1:0] rnd = (acc + 32'sd16384) >>> 15;
    wire signed [15:0]     sat = (rnd >  32'sd32767) ? 16'sh7fff :
                                 (rnd < -32'sd32768) ? 16'sh8000 : rnd[15:0];

    always @(posedge clk) begin
        if (rst) {v0, v1, v2, v3, out_valid} <= 5'b0;
        else     {v0, v1, v2, v3, out_valid} <= {in_valid, v0, v1, v2, v3};
        if (v3) y_out <= sat;
    end
endmodule
