# Resource-only clock targets; NOT a physical clock/CDC signoff.
create_clock -name core_clk -period 10 [get_ports core_clk]
create_clock -name cam_clk -period 14.286 [get_ports cam_clk]
create_clock -name phy_sdram_clk -period 2.5 [get_ports phy_sdram_clk]
create_clock -name phy_rx_cal_clk -period 2.5 [get_ports phy_rx_cal_clk]
create_clock -name phy_tx_cal_clk -period 2.5 [get_ports phy_tx_cal_clk]
create_clock -name phy_tx_cal_clk_90edge -period 2.5 [get_ports phy_tx_cal_clk_90edge]
