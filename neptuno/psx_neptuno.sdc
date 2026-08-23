create_clock -name {CLOCK_50} -period 20.000 [get_ports {CLOCK_50}]
create_clock -name {SPI_SCK} -period 41.666 [get_ports {SPI_SCK}]

derive_pll_clocks -create_base_clocks
derive_clock_uncertainty

set_false_path -to [get_ports {SDRAM_CLK}]
set_false_path -to [get_ports {SDRAM2_CLK}]
set_false_path -from [get_ports {SPI_SCK}] -to [get_ports {SPI_DO}]
set_false_path -from [get_ports {SPI_DI}] -to *
set_false_path -from [get_ports {CONF_DATA0}] -to *
set_false_path -from [get_ports {SPI_SS2}] -to *
set_false_path -from [get_ports {SPI_SS3}] -to *
set_false_path -from [get_ports {SPI_SS4}] -to *
