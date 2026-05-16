# =========================================================================
# CPU-RISC-V.sdc
#
# Restricciones de timing (Synopsys Design Constraints) para el SoC
# RISC-V sobre DE10-Lite. Quartus las usa durante place&route y para el
# analisis de timing (TimeQuest).
# =========================================================================

# Reloj principal: 50 MHz del oscilador onboard
create_clock -name "MAX10_CLK1_50" -period 20.000 [get_ports {MAX10_CLK1_50}]

# Deriva automaticamente la incertidumbre del reloj (PLL skew, jitter)
derive_clock_uncertainty

# Las entradas (KEY, SW) y salidas (LEDR, HEX, VGA) son async respecto
# al reloj del core - no se restringen para evitar fallos de timing
# espurios. Si se quisiera apurar el VGA, se puede crear una input/
# output delay para los pines VGA_*.
set_false_path -from [get_ports {KEY[*] SW[*]}] -to [all_registers]
set_false_path -from [all_registers] -to [get_ports {LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*] VGA_HS VGA_VS VGA_R[*] VGA_G[*] VGA_B[*] UART_TX}]
