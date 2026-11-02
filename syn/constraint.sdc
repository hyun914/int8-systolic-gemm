# 클럭 100 MHz, 입출력 지연은 주기의 20%
current_design gemm_core

set clk_period 10.0
set clk_io_pct 0.2

create_clock -name clk -period $clk_period [get_ports clk]

set non_clock_inputs [delete_from_list [all_inputs] [get_ports clk]]
set_input_delay  [expr $clk_period * $clk_io_pct] -clock clk $non_clock_inputs
set_output_delay [expr $clk_period * $clk_io_pct] -clock clk [all_outputs]
