#
# user core constraints
#
# put your clock groups in here as well as any net assignments
#

set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|*[0].*|divclk \
          ic|mp1|mf_pllbase_inst|altera_pll_i|*[1].*|divclk } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|*[2].*|divclk } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|*[3].*|divclk } \
 -group { ic|audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk }

derive_clock_uncertainty

set_multicycle_path -from {ic|nes|sdram|*} -to [get_clocks {ic|mp1|mf_pllbase_inst|altera_pll_i|*[1].*|divclk}] -start -setup 2
set_multicycle_path -from {ic|nes|sdram|*} -to [get_clocks {ic|mp1|mf_pllbase_inst|altera_pll_i|*[1].*|divclk}] -start -hold 1

set_multicycle_path -from [get_clocks {ic|mp1|mf_pllbase_inst|altera_pll_i|*[1].*|divclk}] -to {ic|nes|sdram|*} -setup 2
set_multicycle_path -from [get_clocks {ic|mp1|mf_pllbase_inst|altera_pll_i|*[1].*|divclk}] -to {ic|nes|sdram|*} -hold 1

set_false_path -from {ic|nes|mapper_flags*}
#set_false_path -from {ic|nes|downloading*}

# Save-state scratch path: glue (clk_sys_21_48) <-> arbiter/psram (clk_mem_85_9).
# Handshakes are synchronized (2-FF) and data is held stable across them, so
# these crossings are multicycle, not single-cycle. (J1b-2c)
set_multicycle_path -from {*ss_glue_fsm:*} -to {*ss_psram_arbiter:*} -setup 3
set_multicycle_path -from {*ss_glue_fsm:*} -to {*ss_psram_arbiter:*} -hold 2
set_multicycle_path -from {*ss_psram_arbiter:*} -to {*ss_glue_fsm:*} -setup 3
set_multicycle_path -from {*ss_psram_arbiter:*} -to {*ss_glue_fsm:*} -hold 2
set_multicycle_path -from {*savestates:*} -to {*ss_psram_arbiter:*} -setup 3
set_multicycle_path -from {*savestates:*} -to {*ss_psram_arbiter:*} -hold 2
set_multicycle_path -from {*ss_psram_arbiter:*} -to {*savestates:*} -setup 3
set_multicycle_path -from {*ss_psram_arbiter:*} -to {*savestates:*} -hold 2
# Synchronizer first stages are false paths (metastability handled by the 2-FF).
set_false_path -to {*ss_psram_arbiter:*|req_s1}
set_false_path -to {*ss_glue_fsm:*|ack_s1}

# Clients (ARAM on clk_sys_21_48 = divclk[1]) hold their address/data stable for
# the whole multi-cycle PSRAM access (they wait on `busy`), so the clk_sys ->
# PSRAM (clk_mem_85_9) paths are multicycle, not single-cycle. This was the
# dominant -9.6ns violation (CPU MCode -> psram latched_data_in).
set_multicycle_path -from [get_clocks {ic|mp1|mf_pllbase_inst|altera_pll_i|*[1].*|divclk}] -to {*ss_psram_arbiter:*|psram:psram|*} -setup 4
set_multicycle_path -from [get_clocks {ic|mp1|mf_pllbase_inst|altera_pll_i|*[1].*|divclk}] -to {*ss_psram_arbiter:*|psram:psram|*} -hold 3
