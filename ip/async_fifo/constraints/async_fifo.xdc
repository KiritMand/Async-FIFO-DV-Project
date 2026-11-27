# async_fifo.xdc — example AMD Vivado implementation constraints for one async_fifo instance (M10).
#
# NOT VALIDATED: Vivado is not installed on the development host (docs/toolchain.md), so this
# file has never been read by Vivado. It shows what implementation needs that verification
# cannot provide: RTL simulation and RTL formal treat every flop as ideal (plan R11), so nothing
# in this repository checks the timing of the clock-domain crossings. Check it with
# report_cdc, report_bus_skew and report_exceptions before relying on it.
#
# Usage: a scoped constraint file, applied to every instance of the module, with names local to
# the instance and clocks found from the module's ports (the way AMD's XPM macros scope theirs):
#   read_xdc async_fifo.xdc
#   set_property SCOPED_TO_REF async_fifo [get_files async_fifo.xdc]
#   set_property PROCESSING_ORDER LATE   [get_files async_fifo.xdc]
# Cell names assume Vivado's default register naming (<signal>_reg[<bit>]).
#
# Sources (AMD documentation, 2026.2, read 2026-11-27):
#   UG903 "Using Constraints": "CDC Synchronizers and ASYNC_REG Property"; "About Bus Skew
#     Constraints"; "Syntax of the set_bus_skew Command".
#   UG949 "UltraFast Design Methodology Guide": "Constraints on Individual CDC Paths".
#
# Do NOT also declare wclk and rclk asynchronous with set_clock_groups or set_false_path for
# these paths: a clock-group or false-path exception takes precedence over set_max_delay
# (UG949 "Clock Exceptions Precedence Over set_max_delay"), and the latency limits below would
# be lost. Reset synchronizers for wrst_n and rrst_n are the integrator's job (vplan A02) and
# need their own constraints.

# ---- The two clocks as they arrive at this instance's ports, and their periods (ns).
set wclk_obj    [get_clocks -of_objects [get_ports wclk]]
set rclk_obj    [get_clocks -of_objects [get_ports rclk]]
set wclk_period [get_property PERIOD $wclk_obj]
set rclk_period [get_property PERIOD $rclk_obj]
set min_period  [expr {min($wclk_period, $rclk_period)}]

# ---- Synchronizer flops: keep both stages, place them close, report them as synchronizers.
# UG903: "Set the ASYNC_REG property to true on all synchronizer flip-flops." The RTL already
# carries (* ASYNC_REG = "TRUE" *) on these four registers; this repeats it so the constraint
# survives a synthesis flow that drops RTL attributes.
set_property ASYNC_REG TRUE [get_cells {wq1_rptr_reg[*] wq2_rptr_reg[*] rq1_wptr_reg[*] rq2_wptr_reg[*]}]

# ---- Gray-coded pointer crossings: bound the latency of each crossing to the source period.
# UG949: a gray-coded CDC bus (for example a FIFO) needs set_max_delay -datapath_only, and the
# source clock period is usually sufficient, so that no more than one pointer value is in flight
# on the crossing. Source flops: wptr/rptr (the crossing nets wptr_cdc/rptr_cdc are wires to them).
set_max_delay -datapath_only -from [get_cells {wptr_reg[*]}] -to [get_cells {rq1_wptr_reg[*]}] $wclk_period
set_max_delay -datapath_only -from [get_cells {rptr_reg[*]}] -to [get_cells {wq1_rptr_reg[*]}] $rclk_period

# ---- Skew between the bits of each pointer bus (a timing assertion, checked by report_bus_skew).
# UG903: bus skew limits how many source edges can launch data captured by one destination edge;
# typical use is a gray-coded bus in an asynchronous FIFO, and the value should be larger than
# half the smaller of the two clock periods. One full minimum period is used here. UG949 names
# set_bus_skew as an alternative to the max delay above; this example applies both.
set_bus_skew -from [get_cells {wptr_reg[*]}] -to [get_cells {rq1_wptr_reg[*]}] $min_period
set_bus_skew -from [get_cells {rptr_reg[*]}] -to [get_cells {wq1_rptr_reg[*]}] $min_period

# ---- Memory read path: mem is written on wclk and read combinationally onto rdata, which the
# reader captures on rclk outside this module (the one waived structural-CDC path, vplan §8).
# The protocol makes it safe only if an entry's data settles before the pointer announcing it
# has crossed (two rclk edges after the gray pointer arrives). Bounding the data path by the
# same source period as the pointer gives that margin. The pattern covers flop- and LUTRAM-mapped
# memory cell names.
set_max_delay -datapath_only -from [get_cells -filter {NAME =~ mem_reg*}] -to $rclk_obj $wclk_period
