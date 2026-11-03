# Gowin full flow: top_ble_fsr (小程序 0x87/0x88 单音 + 板上 FSR 力度, 2026-10-31)
#   = top_ble_echo 的完整副本 + FSR 码值锁存(力度) + top 传 FSR_KEYS_EN(0) + GTR_DEMO=0
# 引脚用**专用**约束 top_ble_fsr.cst (照抄 top_ble_echo.cst, I2C 在 F1/A1)
#
# 注意: 相对旧的 syn_ble_echo.tcl, 本清单补了两个 2026-10-30 起 top.v 实际例化、
#       但旧 tcl 漏掉的模块: gtr_body_lead.v (u_gtr_body) 与 dc_block.v (u_gtr_dc)。
#       (rtl/gtr_body.v 已不被 top.v 例化, 保留在清单里无害)
set_device GW5A-LV25MG121NC1/I0 -name GW5A-25A
set_option -use_sspi_as_gpio 1
set_option -use_cpu_as_gpio 1
add_file lowlat/top_ble_fsr_keys.v
add_file lowlat/keymatrix.v
add_file rtl/top.v
add_file rtl/note_ctrl.v
add_file rtl/partial_engine.v
add_file rtl/gtr_ks_engine.v
add_file rtl/gtr_body.v
add_file rtl/gtr_body_lead.v
add_file rtl/dc_block.v
add_file rtl/gtr_demo.v
add_file rtl/sine_lut_full.v
add_file rtl/i2s_48k.v
add_file rtl/i2s_48k_int.v
add_file rtl/viz_led.v
add_file rtl/ws2812_phy.v
add_file rtl/ws2812_mono.v
add_file rtl/led_guide.v
add_file rtl/rvb_mono.v
add_file rtl/viz_lissa.v
add_file rtl/fb_128x64.v
add_file rtl/ssd1306.v
add_file rtl/spi_master.v
add_file rtl/test_pattern.v
add_file rtl/UART_Receiver.v
add_file rtl/uart_key.v
add_file rtl/uart_rx_off.v
add_file rtl/uart_tx_off.v
add_file rtl/ads1115_if.v
add_file rtl/fsr_key.v
add_file rtl/ble_cmd.v
add_file rtl/ack_tx.v
add_file rtl/keyhub.v
add_file rtl/song_player.v
add_file rtl/guide_ctrl.v
add_file rtl/song_ram.v
add_file rtl/engine.sdc
add_file lowlat/top_ble_fsr_keys.cst
set_option -top_module top_ble_fsr_keys
set_option -verilog_std sysv2017
run all
