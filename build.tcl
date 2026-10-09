set root [file dirname [file normalize [info script]]]
file mkdir "$root/build"
cd "$root/build"
set_device -name GW1NR-9C GW1NR-LV9QN88PC6/I5
add_file "$root/rtl/spi_byte.v"
add_file "$root/rtl/max31855_reader.v"
add_file "$root/rtl/uart.v"
add_file "$root/rtl/button.v"
add_file "$root/rtl/sd_spi.v"
add_file "$root/rtl/templog.v"
add_file "$root/tang_nano_9k.cst"
add_file "$root/clock.sdc"
set_option -top_module templog
set_option -verilog_std v2001
run all
