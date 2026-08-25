create_clock -name {CLOCK_50} -period 20.000 [get_ports {CLOCK_50}]
create_clock -name {SPI_SCK} -period 41.666 [get_ports {SPI_SCK}]

derive_pll_clocks -create_base_clocks
derive_clock_uncertainty

# SPI_SCK (the RP2040 IO-controller link, user_io/data_io/osd) is a fully
# independent, asynchronous clock domain relative to the system/video
# clocks - crossings are already handled by synchronizers inside those
# proven mist-modules blocks, not meant to be timed as related clocks.
# Per-port false-paths alone (as this file used to have) don't cover the
# internal SPI_SCK-clocked registers, which is almost certainly why the
# first real compile showed a huge pile of "failing" paths landing on the
# clk_1x domain - those were bogus CDC paths TimeQuest tried to time as
# synchronous. This group declaration replaces that piecemeal approach.
set_clock_groups -asynchronous \
	-group [get_clocks {SPI_SCK}] \
	-group [get_clocks {pll*}]

set_false_path -to [get_ports {SDRAM_CLK}]
set_false_path -to [get_ports {SDRAM2_CLK}]
