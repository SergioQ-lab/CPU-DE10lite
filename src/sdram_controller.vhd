--------------------------------------------------------------------------------
-- sdram_controller.vhd
--
-- Controlador para SDRAM IS42S16320D-7TL (64 MBytes) de la DE10-Lite.
-- Frecuencia de reloj: 50 MHz (Periodo = 20 ns).
-- 
-- Arquitectura de la RAM: 32M x 16 bits
--   - 4 Bancos (BA0, BA1)
--   - 8192 Filas (A0-A12)
--   - 512 Columnas (A0-A8)
--
-- ESTADO ACTUAL: FSM de Inicializacion y Auto-Refresco
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
        
        -- Interfaz fisica SDRAM
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

    -- Comandos SDRAM (CS_N, RAS_N, CAS_N, WE_N)
    constant CMD_NOP             : std_logic_vector(3 downto 0) := "0111";
    constant CMD_ACTIVE          : std_logic_vector(3 downto 0) := "0011";
    constant CMD_READ            : std_logic_vector(3 downto 0) := "0101";
    constant CMD_WRITE           : std_logic_vector(3 downto 0) := "0100";
    constant CMD_PRECHARGE       : std_logic_vector(3 downto 0) := "0010";
    constant CMD_AUTO_REFRESH    : std_logic_vector(3 downto 0) := "0001";
    constant CMD_LOAD_MODE       : std_logic_vector(3 downto 0) := "0000";

    -- Tiempos en ciclos a 50 MHz (Periodo = 20ns)
    -- INIT_WAIT: Minimo 100 us -> 100,000 ns / 20 ns = 5000 ciclos. Usamos 6000 por seguridad.
    constant T_INIT_WAIT : integer := 6000;
    -- TRP (Precharge to Active): Min 15ns -> 1 ciclo
    constant T_RP        : integer := 1; 
    -- TRC (Auto Refresh Cycle): Min 60ns -> 3 ciclos
    constant T_RC        : integer := 3;
    -- TMRD (Mode Register Delay): Min 2 ciclos
    constant T_MRD       : integer := 2;
    -- Intervalo de Refresco: 64ms / 8192 filas = 7.8125 us -> 390 ciclos a 50 MHz.
    constant T_REFRESH   : integer := 380; 

    -- Estados de la FSM
    type fsm_state_t is (
        S_INIT_WAIT,
        S_INIT_PRECHARGE,
        S_INIT_TRP,
        S_INIT_REF1,
        S_INIT_TRC1,
        S_INIT_REF2,
        S_INIT_TRC2,
        S_INIT_LMR,
        S_INIT_TMRD,
        S_IDLE,
        S_REFRESH_CMD,
        S_REFRESH_TRC
        -- Mas adelante anadiremos ACTIVATE, READ, WRITE, etc.
    );

    signal state        : fsm_state_t := S_INIT_WAIT;
    signal wait_timer   : integer range 0 to 8191 := 0;
    signal ref_timer    : integer range 0 to 511  := 0;
    
    signal cmd_reg      : std_logic_vector(3 downto 0) := CMD_NOP;
    signal addr_reg     : std_logic_vector(12 downto 0):= (others => '0');

begin
    
    -- Inversion de fase para reloj externo (Mejora setup/hold times)
    O_sdram_clk <= not I_clk;
    
    -- Pines fijos por ahora
    O_sdram_cke  <= '1';
    O_sdram_ba   <= "00";
    O_sdram_ldqm <= '0';
    O_sdram_udqm <= '0';
    IO_sdram_dq  <= (others => 'Z');

    O_sdram_cs_n  <= cmd_reg(3);
    O_sdram_ras_n <= cmd_reg(2);
    O_sdram_cas_n <= cmd_reg(1);
    O_sdram_we_n  <= cmd_reg(0);
    O_sdram_addr  <= addr_reg;

    -- Mantener CPU ocupada mientras no estemos en IDLE
    O_busy  <= '1' when state /= S_IDLE else '0';
    O_valid <= '0';
    O_data_out <= (others => '0');

    -- Maquina de estados principal
    process (I_clk)
    begin
        if rising_edge(I_clk) then
            if I_reset = '1' then
                state       <= S_INIT_WAIT;
                wait_timer  <= 0;
                ref_timer   <= 0;
                cmd_reg     <= CMD_NOP;
                addr_reg    <= (others => '0');
            else
                -- Por defecto, inyectamos NOP para que la SDRAM no haga nada
                -- a menos que el estado diga lo contrario.
                cmd_reg  <= CMD_NOP;
                addr_reg <= (others => '0');
                
                -- El temporizador de refresco siempre avanza (excepto en init)
                if state = S_IDLE or state = S_REFRESH_CMD or state = S_REFRESH_TRC then
                    ref_timer <= ref_timer + 1;
                end if;

                case state is
                    -- ========================================================
                    -- FASE DE INICIALIZACION (Power-Up)
                    -- ========================================================
                    when S_INIT_WAIT =>
                        -- Esperar 100 us con NOPs
                        if wait_timer < T_INIT_WAIT then
                            wait_timer <= wait_timer + 1;
                        else
                            state <= S_INIT_PRECHARGE;
                        end if;

                    when S_INIT_PRECHARGE =>
                        cmd_reg    <= CMD_PRECHARGE;
                        addr_reg   <= (10 => '1', others => '0'); -- A10 = 1 para Precharge ALL banks
                        wait_timer <= 0;
                        state      <= S_INIT_TRP;

                    when S_INIT_TRP =>
                        -- Esperar tiempo de Precharge
                        if wait_timer < T_RP - 1 then
                            wait_timer <= wait_timer + 1;
                        else
                            state <= S_INIT_REF1;
                        end if;

                    when S_INIT_REF1 =>
                        cmd_reg    <= CMD_AUTO_REFRESH;
                        wait_timer <= 0;
                        state      <= S_INIT_TRC1;

                    when S_INIT_TRC1 =>
                        -- Esperar ciclo de refresco
                        if wait_timer < T_RC - 1 then
                            wait_timer <= wait_timer + 1;
                        else
                            state <= S_INIT_REF2;
                        end if;

                    when S_INIT_REF2 =>
                        cmd_reg    <= CMD_AUTO_REFRESH;
                        wait_timer <= 0;
                        state      <= S_INIT_TRC2;

                    when S_INIT_TRC2 =>
                        -- Esperar ciclo de refresco
                        if wait_timer < T_RC - 1 then
                            wait_timer <= wait_timer + 1;
                        else
                            state <= S_INIT_LMR;
                        end if;

                    when S_INIT_LMR =>
                        cmd_reg    <= CMD_LOAD_MODE;
                        -- Mode Register: CAS Latency = 2, Burst Length = 1, Sequential
                        -- A2-A0 = 000 (Burst 1)
                        -- A3 = 0 (Sequential)
                        -- A6-A4 = 010 (CAS 2)
                        -- A8-A7 = 00 (Standard)
                        -- A9 = 0 (Burst Read / Single Write) -> vamos a usar Burst Read / Burst Write (0)
                        addr_reg   <= "0000000100000"; 
                        wait_timer <= 0;
                        state      <= S_INIT_TMRD;

                    when S_INIT_TMRD =>
                        -- Esperar que se configure el Mode Register
                        if wait_timer < T_MRD - 1 then
                            wait_timer <= wait_timer + 1;
                        else
                            state     <= S_IDLE;
                            ref_timer <= 0;
                        end if;

                    -- ========================================================
                    -- FASE OPERATIVA Y AUTO-REFRESCO
                    -- ========================================================
                    when S_IDLE =>
                        -- Si toca refresco, priorizamos esto
                        if ref_timer >= T_REFRESH then
                            state <= S_REFRESH_CMD;
                        else
                            -- (Aqui iran las transiciones a ACTIVATE para READ/WRITE)
                            null;
                        end if;

                    when S_REFRESH_CMD =>
                        cmd_reg    <= CMD_AUTO_REFRESH;
                        wait_timer <= 0;
                        ref_timer  <= 0;
                        state      <= S_REFRESH_TRC;

                    when S_REFRESH_TRC =>
                        -- Esperar ciclo de refresco antes de volver a IDLE
                        if wait_timer < T_RC - 1 then
                            wait_timer <= wait_timer + 1;
                        else
                            state <= S_IDLE;
                        end if;

                    when others =>
                        state <= S_INIT_WAIT;
                end case;
            end if;
        end if;
    end process;

end architecture Behavioral;
