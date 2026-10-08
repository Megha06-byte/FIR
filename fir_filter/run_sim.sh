#!/usr/bin/env bash
# Regenerate coefficients/golden vectors, then check all three FIR variants
# bit-exact (continuous input and random input gaps). Needs python3 + numpy +
# scipy and Icarus Verilog.
set -euo pipefail
cd "$(dirname "$0")"
python3 model/fir_model.py > /dev/null
cd sim
for d in fir_direct fir_folded fir_pipe; do
  iverilog -g2005 -I../rtl -I. -DDUT=$d -o tb_$d.vvp ../rtl/$d.v ../tb/tb_fir.v
  for g in 0 1; do echo -n "$d gaps=$g: "; vvp -n tb_$d.vvp +GAPS=$g | grep RESULT; done
done
rm -f *.vvp
