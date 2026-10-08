// -----------------------------------------------------------------------------
// fir_direct : BASELINE 31-tap FIR, direct form
//
//   y[n] = sat16( (sum_k c[k] * x[n-k] + 2^14) >>> 15 )
//
// One constant multiplier per tap. All products feed a single combinational
// adder tree into the output register, so the critical path is
// multiply + 5-level adder tree + round/saturate.
// Latency 2 cycles (delay line, output register), throughput 1 sample/clock.
// -----------------------------------------------------------------------------
module fir_direct (
    input                    clk,
    input                    rst,
    input                    in_valid,
    input      signed [15:0] x_in,
    output reg               out_valid,
    output reg signed [15:0] y_out
);
`include "fir_coeffs.vh"
    localparam ACCW = 32;   // worst case sum|c|*2^15 = 1.48e9 < 2^31

    reg signed [15:0] d [0:NTAP-1];          // delay line, d[k] = x[n-k]
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

    // multiply-accumulate (combinational)
    reg signed [ACCW-1:0] acc;
    always @* begin
        acc = 0;
        for (i = 0; i < NTAP; i = i + 1)
            acc = acc + d[i] * $signed(COEF[16*i +: 16]);
    end

    // round half up, then saturate to int16
    wire signed [ACCW-1:0] rnd = (acc + 32'sd16384) >>> 15;
    wire signed [15:0]     sat = (rnd >  32'sd32767) ? 16'sh7fff :
                                 (rnd < -32'sd32768) ? 16'sh8000 : rnd[15:0];

    always @(posedge clk) begin
        out_valid <= rst ? 1'b0 : v_d;
        if (v_d) y_out <= sat;
    end
endmodule
