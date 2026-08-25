create_clock -name {CLOCK_50} -period 20.000 [get_ports {CLOCK_50}]
create_clock -name {SPI_SCK} -period 41.666 [get_ports {SPI_SCK}]

derive_pll_clocks -create_base_clocks
derive_clock_uncertainty

# Three mutually-asynchronous clock groups:
#  - SPI_SCK (RP2040 IO-controller link, user_io/data_io/osd) - crossings
#    are already handled by synchronizers inside those proven mist-modules
#    blocks, not meant to be timed as related clocks.
#  - pll's clocks (clk_1x/2x/3x - CPU/system/SDRAM)
#  - pll2's clock (clk_vid - video pixel clock)
# pll and pll2 are independent PLL instances off the same CLOCK_50
# reference with no fixed phase relationship, so crossings between them
# (e.g. the CPU-domain errorCode[] feeding gpu_overlay's video-domain
# col[] registers for the debug Error Overlay) must be false-pathed, not
# timed as synchronous. The original MiSTer PSX.sdc does exactly this
# (explicit set_false_path pairs between its pll/pll2), confirming this
# is the intended relationship, not something specific to this port.
# Grouping pll and pll2 together (as an earlier version of this file did)
# was wrong - that treats them as synchronous to each other and was
# exactly why the errorCode->gpu_overlay path showed up as a real timing
# failure instead of being excluded like upstream already excludes it.
set_clock_groups -asynchronous \
	-group [get_clocks {SPI_SCK}] \
	-group [get_clocks {pll|*}] \
	-group [get_clocks {pll2|*}]

set_false_path -to [get_ports {SDRAM_CLK}]
set_false_path -to [get_ports {SDRAM2_CLK}]
