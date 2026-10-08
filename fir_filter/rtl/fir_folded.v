// -----------------------------------------------------------------------------
// fir_folded : AREA-OPTIMISED FIR, symmetric (linear-phase) folding
//
// A linear-phase FIR has c[k] = c[N-1-k], so pairs of taps share a coefficient:
//
//   y = sum_{k<15} c[k] * (x[n-k] + x[n-30+k])  +  c[15] * x[n-15]
//
// A 17-bit pre-adder per pair halves the multiplier count (31 -> 16).
// Pairs whose shared coefficient is 0 (6 of 31 taps here) generate no
// pre-adder and no multiplier at all, leaving 13 multipliers.
// Integer arithmetic is exact, so the output is bit-identical to fir_direct.
// Latency 2 cycles, throughput 1 sample/clock.
// -----------------------------------------------------------------------------
module fir_folded (
    input                    clk,
    input                    rst,
    input                    in_valid,
    input      signed [15:0] x_in,
    output reg               out_valid,
    output reg signed [15:0] y_out
);
`include "fir_coeffs.vh"
    localparam ACCW = 32;
    localparam NP   = NTAP / 2;              // 15 symmetric pairs + centre tap

    reg signed [15:0] d [0:NTAP-1];
    reg               v_d;
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < NTAP; i = i + 1) d[i] <= 16'sd0;   // history = 0
        end else if (in_valid) begin
            d[0] <= x_in;
            for (i = 1; i < NTAP; i = i + 1) d[i] <= d[i-1];
        end
        v_d <= rst ? 1'b0 : in_valid;
    end

    // one product per unique non-zero coefficient
    wire signed [ACCW-1:0] prod [0:NP];
    genvar k;
    generate
        for (k = 0; k <= NP; k = k + 1) begin : g_tap
            localparam signed [15:0] C = COEF[16*k +: 16];
            if (C == 0) begin : g_zero
                assign prod[k] = 0;                       // pruned: no hardware
            end else if (k == NP) begin : g_centre
                assign prod[k] = d[k] * C;
            end else begin : g_pair
                wire signed [16:0] pre = {d[k][15], d[k]}             // 17-bit pre-add
                                       + {d[NTAP-1-k][15], d[NTAP-1-k]};
                assign prod[k] = pre * C;
            end
        end
    endgenerate

    reg signed [ACCW-1:0] acc;
    always @* begin
        acc = 0;
        for (i = 0; i <= NP; i = i + 1) acc = acc + prod[i];
    end

    wire signed [ACCW-1:0] rnd = (acc + 32'sd16384) >>> 15;
    wire signed [15:0]     sat = (rnd >  32'sd32767) ? 16'sh7fff :
                                 (rnd < -32'sd32768) ? 16'sh8000 : rnd[15:0];

    always @(posedge clk) begin
        out_valid <= rst ? 1'b0 : v_d;
        if (v_d) y_out <= sat;
    end
endmodule
