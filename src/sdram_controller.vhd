--------------------------------------------------------------------------------
-- sdram_controller.vhd
--
-- Controlador para SDRAM IS42S16320D-7TL (64 MBytes) de la placa DE10-Lite.
-- Frecuencia de reloj: 50 MHz.
-- 
-- Arquitectura de la RAM: 32M x 16 bits
--   - 4 Bancos (BA0, BA1)
--   - 8192 Filas (A0-A12)
--   - 512 Columnas (A0-A8)
--
-- ESTADO ACTUAL: SKELETON (Esqueleto)
-- Esta es la interfaz del controlador. La maquina de estados de 
-- inicializacion, auto-refresh y rafagas (bursts) se implementara a 
-- continuacion.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity sdram_controller is
    port (
        -- Sistema
        I_clk        : in    std_logic;
        I_reset      : in    std_logic;
        
        -- Bus interno del SoC
        I_addr       : in    std_logic_vector(24 downto 0); -- 32M words = 25 bits
        I_data_in    : in    std_logic_vector(15 downto 0);
        O_data_out   : out   std_logic_vector(15 downto 0);
        I_rd_en      : in    std_logic;
        I_wr_en      : in    std_logic;
        I_byte_en    : in    std_logic_vector(1 downto 0);
        O_busy       : out   std_logic;
        O_valid      : out   std_logic;
        
        -- SDRAM Physical Interface
        O_sdram_clk  : out   std_logic;
        O_sdram_cke  : out   std_logic;
        O_sdram_cs_n : out   std_logic;
        O_sdram_ras_n: out   std_logic;
        O_sdram_cas_n: out   std_logic;
        O_sdram_we_n : out   std_logic;
        O_sdram_addr : out   std_logic_vector(12 downto 0);
        O_sdram_ba   : out   std_logic_vector(1 downto 0);
        O_sdram_ldqm : out   std_logic;
        O_sdram_udqm : out   std_logic;
        IO_sdram_dq  : inout std_logic_vector(15 downto 0)
    );
end entity sdram_controller;

architecture Behavioral of sdram_controller is

begin
    -- TODO: Implementar Maquina de Estados (INIT, IDLE, PRECHARGE, REFRESH, ACTIVATE, READ, WRITE)
    
    -- Pasamos el reloj directamente por ahora (lo ideal sera un PLL con -3ns de fase)
    O_sdram_clk   <= not I_clk; 
    
    -- Desactivamos la SDRAM (modo NOP constante) para que no haya colisiones
    O_sdram_cke   <= '1';
    O_sdram_cs_n  <= '1'; 
    O_sdram_ras_n <= '1';
    O_sdram_cas_n <= '1';
    O_sdram_we_n  <= '1';
    O_sdram_addr  <= (others => '0');
    O_sdram_ba    <= "00";
    O_sdram_ldqm  <= '0';
    O_sdram_udqm  <= '0';
    IO_sdram_dq   <= (others => 'Z');
    
    -- Mantenemos ocupado el bus para bloquear cualquier intento de lectura
    O_busy        <= '1'; 
    O_valid       <= '0';
    O_data_out    <= (others => '0');

end architecture Behavioral;
