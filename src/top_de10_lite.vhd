--------------------------------------------------------------------------------
-- top_de10_lite.vhd
--
-- Entidad top del diseno para la placa DE10-Lite. Recibe los pines fisicos
-- de la placa y los enlaza con el SoC.
--   - KEY0 = reset asincrono activo en bajo (sincronizado al reloj de 50 MHz
--     con dos FFs para evitar metaestabilidad al soltar el boton).
--   - UART_TX en el pin GPIO Arduino IO[1] (= PIN_AB17). Salida pura, sin
--     inout, para que Quartus no inserte buffers tri-state.
--
-- Pin assignments en CPU-RISC-V.qsf.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity top_de10_lite is
    port (
        MAX10_CLK1_50 : in  std_logic;
        KEY           : in  std_logic_vector(1 downto 0);
        SW            : in  std_logic_vector(9 downto 0);
        LEDR          : out std_logic_vector(9 downto 0);
        HEX0          : out std_logic_vector(7 downto 0);
        HEX1          : out std_logic_vector(7 downto 0);
        HEX2          : out std_logic_vector(7 downto 0);
        HEX3          : out std_logic_vector(7 downto 0);
        HEX4          : out std_logic_vector(7 downto 0);
        HEX5          : out std_logic_vector(7 downto 0);
        VGA_HS        : out std_logic;
        VGA_VS        : out std_logic;
        VGA_R         : out std_logic_vector(3 downto 0);
        VGA_G         : out std_logic_vector(3 downto 0);
        VGA_B         : out std_logic_vector(3 downto 0);
        UART_TX       : out std_logic
    );
end entity top_de10_lite;

architecture Behavioral of top_de10_lite is

    component soc is
        port (
            I_clk_50  : in  std_logic;
            I_reset_n : in  std_logic;
            I_sw      : in  std_logic_vector(9 downto 0);
            I_key     : in  std_logic_vector(1 downto 0);
            O_ledr    : out std_logic_vector(9 downto 0);
            O_hex0    : out std_logic_vector(7 downto 0);
            O_hex1    : out std_logic_vector(7 downto 0);
            O_hex2    : out std_logic_vector(7 downto 0);
            O_hex3    : out std_logic_vector(7 downto 0);
            O_hex4    : out std_logic_vector(7 downto 0);
            O_hex5    : out std_logic_vector(7 downto 0);
            O_vga_hs  : out std_logic;
            O_vga_vs  : out std_logic;
            O_vga_r   : out std_logic_vector(3 downto 0);
            O_vga_g   : out std_logic_vector(3 downto 0);
            O_vga_b   : out std_logic_vector(3 downto 0);
            O_uart_tx : out std_logic
        );
    end component;

    -- Sincronizador de reset (dos FFs en cascada)
    signal rst_sync0 : std_logic := '0';
    signal rst_sync1 : std_logic := '0';
    signal reset_n   : std_logic;

begin

    sync_reset : process (MAX10_CLK1_50)
    begin
        if rising_edge(MAX10_CLK1_50) then
            rst_sync0 <= KEY(0);
            rst_sync1 <= rst_sync0;
        end if;
    end process;
    reset_n <= rst_sync1;

    soc_inst : soc port map (
        I_clk_50  => MAX10_CLK1_50,
        I_reset_n => reset_n,
        I_sw      => SW,
        I_key     => KEY,
        O_ledr    => LEDR,
        O_hex0    => HEX0,
        O_hex1    => HEX1,
        O_hex2    => HEX2,
        O_hex3    => HEX3,
        O_hex4    => HEX4,
        O_hex5    => HEX5,
        O_vga_hs  => VGA_HS,
        O_vga_vs  => VGA_VS,
        O_vga_r   => VGA_R,
        O_vga_g   => VGA_G,
        O_vga_b   => VGA_B,
        O_uart_tx => UART_TX
    );

end architecture Behavioral;
