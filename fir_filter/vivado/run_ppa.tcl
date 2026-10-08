# -----------------------------------------------------------------------------
# run_ppa.tcl : area, timing and power for all three FIR variants (Vivado batch)
#
#   cd fir_asic/vivado
#   vivado -mode batch -source run_ppa.tcl
#
# For each design:
#   Pass 1 (Fmax)  : out-of-context synth + place + route against an aggressive
#                    clock (T_FMAX). Fmax = 1000 / (T_FMAX - WNS).
#   Pass 2 (power) : implement at T_PWR (100 MHz), write the routed netlist,
#                    simulate it in xsim with the self-checking testbench
#                    (proves the netlist is correct) and record switching
#                    activity (SAIF), then report_power with that activity.
#
# Output: out/summary.csv plus full reports in out/<design>/
# -----------------------------------------------------------------------------
set PART    xc7k70tfbv676-1          ;# Kintex-7 70T, speed grade -1
set DESIGNS {fir_direct fir_folded fir_pipe}
set T_FMAX  3.0                      ;# ns, deliberately tight so the tool works hard
set T_PWR   10.0                     ;# ns, 100 MHz operating point for power

set ROOT [file normalize [file dirname [info script]]/..]
set RTL  $ROOT/rtl
set OUT  [file normalize [file dirname [info script]]/out]
file mkdir $OUT

# ---------------------------------------------------------------- helpers
proc build {top period odir} {
    global PART RTL
    catch {close_project}
    create_project -in_memory -part $PART
    read_verilog $RTL/$top.v
    set xdc $odir/clk_[string map {. p} $period].xdc
    set f [open $xdc w]
    puts $f "create_clock -name clk -period $period \[get_ports clk\]"
    close $f
    read_xdc -mode out_of_context $xdc
    synth_design -top $top -part $PART -mode out_of_context -include_dirs $RTL
    opt_design
    place_design
    phys_opt_design
    route_design
}

proc count {filter} { return [llength [get_cells -quiet -hierarchical -filter $filter]] }

set csv [open $OUT/summary.csv w]
puts $csv "design,LUT,FF,DSP48,T_fmax_ns,WNS_ns,Fmax_MHz,P_dynamic_mW@100MHz,P_static_mW,power_confidence,netlist_sim"

foreach top $DESIGNS {
    set odir $OUT/$top
    file mkdir $odir

    # ======================= pass 1: Fmax ===================================
    build $top $T_FMAX $odir
    report_utilization     -file $odir/util.rpt
    report_timing_summary  -file $odir/timing_fmax.rpt -max_paths 10
    set wns  [get_property SLACK [get_timing_paths -setup -max_paths 1]]
    set fmax [format %.1f [expr {1000.0 / ($T_FMAX - $wns)}]]
    set lut  [count {PRIMITIVE_GROUP == LUT}]
    set ff   [count {PRIMITIVE_GROUP == FLOP_LATCH}]
    set dsp  [count {REF_NAME =~ DSP48*}]

    # ======================= pass 2: power @ 100 MHz ========================
    build $top $T_PWR $odir
    report_timing_summary -file $odir/timing_100MHz.rpt
    set netlist $odir/${top}_funcsim.v
    write_verilog -mode funcsim -force $netlist

    # --- post-route functional simulation with SAIF dump
    set sdir $odir/xsim
    file delete -force $sdir
    file mkdir $sdir
    foreach fn {x.hex y_gold.hex} { file copy -force $ROOT/sim/$fn $sdir/$fn }
    set f [open $sdir/saif.tcl w]
    puts $f "open_saif dut.saif"
    puts $f "log_saif \[get_objects -r /tb_fir/dut/*\]"
    puts $f "run all"
    puts $f "close_saif"
    puts $f "quit"
    close $f
    set glbl $::env(XILINX_VIVADO)/data/verilog/src/glbl.v
    set here [pwd]
    cd $sdir
    exec xvlog -i $ROOT/sim -d DUT=$top $netlist $ROOT/tb/tb_fir.v $glbl >& xvlog.log
    exec xelab -debug typical -L unisims_ver tb_fir glbl -s snap >& xelab.log
    catch {exec xsim snap -tclbatch saif.tcl >& xsim.log}
    cd $here
    set simlog [read [open $sdir/xsim.log]]
    set simres [expr {[string match "*PASS*" $simlog] ? "PASS" : "FAIL"}]

    # --- annotate activity and report power
    reset_switching_activity -all
    read_saif -strip_path tb_fir/dut $sdir/dut.saif
    report_power -file $odir/power_100MHz.rpt
    set prpt [report_power -return_string]
    regexp {Dynamic \(W\)\s*\|\s*([0-9.]+)}      $prpt -> pdyn
    regexp {Device Static \(W\)\s*\|\s*([0-9.]+)} $prpt -> pstat
    regexp {Confidence Level\s*\|\s*(\w+)}       $prpt -> conf

    puts $csv [join [list $top $lut $ff $dsp $T_FMAX [format %.3f $wns] $fmax \
        [format %.2f [expr {$pdyn * 1000}]] [format %.1f [expr {$pstat * 1000}]] \
        $conf $simres] ,]
    flush $csv
    puts "### $top : LUT=$lut FF=$ff DSP=$dsp Fmax=${fmax}MHz Pdyn=[expr {$pdyn*1000}]mW sim=$simres conf=$conf"
}
close $csv
puts "\nSummary written to $OUT/summary.csv"
