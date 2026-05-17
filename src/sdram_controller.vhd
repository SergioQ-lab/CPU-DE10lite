--------------------------------------------------------------------------------
-- sdram_controller.vhd
--
-- Controlador para SDRAM IS42S16320D-7TL (64 MBytes) de la DE10-Lite.
-- Frecuencia de reloj: 50 MHz (Periodo = 20 ns).
-- 
-- Arquitectura de la RAM: 32M x 16 bits
--   - 4 Bancos (BA0, BA1) -> bits [24:23]
--   - 8192 Filas (A0-A12) -> bits [22:10]
--   - 1024 Columnas (A0-A9) -> bits [9:0]
--
-- CARACTERISTICAS:
--   - Inicializacion automatica al encender.
--   - Auto-Refresco cada 7.8 us.
--   - Accesos de Lectura/Escritura mediante Auto-Precharge (A10=1).
--   - CAS Latency = 2, Burst Length = 1.
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
        I_byte_en    : in    std_logic_vector(1 downto 0); -- (1) = High Byte, (0) = Low Byte
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
    constant T_INIT_WAIT : integer := 6000; -- 120 us
    constant T_RP        : integer := 1;    -- Precharge Time (Min 15ns)
    constant T_RC        : integer := 3;    -- Refresh Cycle (Min 60ns)
    constant T_MRD       : integer := 2;    -- Mode Register Delay (2 ciclos)
    constant T_REFRESH   : integer := 380;  -- Auto-Refresh interval (7.8 us)

    -- Estados de la FSM
    type fsm_state_t is (
        -- Init
        S_INIT_WAIT,
        S_INIT_PRECHARGE,
        S_INIT_TRP,
        S_INIT_REF1,
        S_INIT_TRC1,
        S_INIT_REF2,
        S_INIT_TRC2,
        S_INIT_LMR,
        S_INIT_TMRD,
        
        -- Operacion normal
        S_IDLE,
        S_REFRESH_CMD,
        S_REFRESH_TRC,
        
        -- Accesos de lectura/escritura
        S_ACTIVATE,
        S_TRCD,
        S_READ_CMD,
        S_CAS1,
        S_CAS2,
        S_CAS3,
        S_WRITE_CMD,
        S_TWR1,
        S_TWR2,
        S_PRECHARGE_WAIT
    );

    signal state        : fsm_state_t := S_INIT_WAIT;
    signal wait_timer   : integer range 0 to 8191 := 0;
    signal ref_timer    : integer range 0 to 511  := 0;
    
    signal cmd_reg      : std_logic_vector(3 downto 0) := CMD_NOP;
    signal addr_reg     : std_logic_vector(12 downto 0):= (others => '0');
    signal ba_reg       : std_logic_vector(1 downto 0) := "00";
    signal dqm_reg      : std_logic_vector(1 downto 0) := "00";
    
    signal is_read      : std_logic := '0';
    signal saved_addr   : std_logic_vector(24 downto 0) := (others => '0');
    signal saved_data   : std_logic_vector(15 downto 0) := (others => '0');
    signal saved_byte   : std_logic_vector(1 downto 0) := "00";
    
    signal prev_rd_en   : std_logic := '0';
    signal prev_wr_en   : std_logic := '0';

    -- Control de pines inout
    signal dq_out_en    : std_logic := '0';
    signal dq_out       : std_logic_vector(15 downto 0) := (others => '0');
    signal sdram_dq_falling : std_logic_vector(15 downto 0) := (others => '0');

begin
    
    -- Inversion de fase para reloj externo (Mejora drastica de Setup/Hold times)
    O_sdram_clk <= not I_clk;
    
    O_sdram_cke  <= '1';
    
    -- Asignacion de pines fijos al exterior
    O_sdram_cs_n  <= cmd_reg(3);
    O_sdram_ras_n <= cmd_reg(2);
    O_sdram_cas_n <= cmd_reg(1);
    O_sdram_we_n  <= cmd_reg(0);
    O_sdram_addr  <= addr_reg;
    O_sdram_ba    <= ba_reg;
    O_sdram_udqm  <= dqm_reg(1);
    O_sdram_ldqm  <= dqm_reg(0);

    -- Buffer tri-estado bidireccional para el bus de datos
    IO_sdram_dq   <= dq_out when dq_out_en = '1' else (others => 'Z');

    -- Mantenemos ocupado el bus si no estamos en IDLE (stalls de CPU)
    O_busy  <= '1' when state /= S_IDLE else '0';

    -- =========================================================================
    -- Captura de datos en el flanco de BAJADA (mitad del ciclo)
    -- =========================================================================
    -- Como usamos O_sdram_clk <= not I_clk, la SDRAM escupe el dato tras
    -- su flanco de subida (que coincide con nuestro flanco de bajada).
    -- Capturarlo en nuestro flanco de bajada garantiza estar justo en el 
    -- centro de la ventana de validez.
    process (I_clk)
    begin
        if falling_edge(I_clk) then
            sdram_dq_falling <= IO_sdram_dq;
        end if;
    end process;

    process (I_clk)
    begin
        if rising_edge(I_clk) then
            if I_reset = '1' then
                state       <= S_INIT_WAIT;
                wait_timer  <= 0;
                ref_timer   <= 0;
                cmd_reg     <= CMD_NOP;
                addr_reg    <= (others => '0');
                ba_reg      <= "00";
                dqm_reg     <= "00";
                dq_out_en   <= '0';
                O_valid     <= '0';
                O_data_out  <= (others => '0');
            else
                -- Por defecto en cada ciclo
                cmd_reg   <= CMD_NOP;
                addr_reg  <= (others => '0');
                ba_reg    <= "00";
                dqm_reg   <= "00";
                dq_out_en <= '0';
                O_valid   <= '0';
                
                prev_rd_en <= I_rd_en;
                prev_wr_en <= I_wr_en;
                
                -- El temporizador de refresco siempre avanza (excepto en init)
                if state /= S_INIT_WAIT and state /= S_INIT_PRECHARGE and state /= S_INIT_LMR then
                    ref_timer <= ref_timer + 1;
                end if;

                case state is
                    -- ========================================================
                    -- FASE DE INICIALIZACION
                    -- ========================================================
                    when S_INIT_WAIT =>
                        if wait_timer < T_INIT_WAIT then
                            wait_timer <= wait_timer + 1;
                        else
                            state <= S_INIT_PRECHARGE;
                        end if;

                    when S_INIT_PRECHARGE =>
                        cmd_reg    <= CMD_PRECHARGE;
                        addr_reg   <= (10 => '1', others => '0'); -- A10 = 1 para Precharge ALL
                        wait_timer <= 0;
                        state      <= S_INIT_TRP;

                    when S_INIT_TRP =>
                        if wait_timer < T_RP - 1 then wait_timer <= wait_timer + 1; else state <= S_INIT_REF1; end if;

                    when S_INIT_REF1 =>
                        cmd_reg    <= CMD_AUTO_REFRESH;
                        wait_timer <= 0;
                        state      <= S_INIT_TRC1;

                    when S_INIT_TRC1 =>
                        if wait_timer < T_RC - 1 then wait_timer <= wait_timer + 1; else state <= S_INIT_REF2; end if;

                    when S_INIT_REF2 =>
                        cmd_reg    <= CMD_AUTO_REFRESH;
                        wait_timer <= 0;
                        state      <= S_INIT_TRC2;

                    when S_INIT_TRC2 =>
                        if wait_timer < T_RC - 1 then wait_timer <= wait_timer + 1; else state <= S_INIT_LMR; end if;

                    when S_INIT_LMR =>
                        cmd_reg    <= CMD_LOAD_MODE;
                        -- Mode Register: CAS Latency = 2, Burst Length = 1, Sequential
                        addr_reg   <= "0000000100000"; 
                        wait_timer <= 0;
                        state      <= S_INIT_TMRD;

                    when S_INIT_TMRD =>
                        if wait_timer < T_MRD - 1 then wait_timer <= wait_timer + 1; else state <= S_IDLE; ref_timer <= 0; end if;

                    -- ========================================================
                    -- FASE OPERATIVA: IDLE Y AUTO-REFRESCO
                    -- ========================================================
                    when S_IDLE =>
                        if ref_timer >= T_REFRESH then
                            state <= S_REFRESH_CMD;
                        elsif I_rd_en = '1' and prev_rd_en = '0' then
                            is_read    <= '1';
                            saved_addr <= I_addr;
                            saved_byte <= I_byte_en;
                            state      <= S_ACTIVATE;
                        elsif I_wr_en = '1' and prev_wr_en = '0' then
                            is_read    <= '0';
                            saved_addr <= I_addr;
                            saved_data <= I_data_in;
                            saved_byte <= I_byte_en;
                            state      <= S_ACTIVATE;
                        end if;

                    when S_REFRESH_CMD =>
                        cmd_reg    <= CMD_AUTO_REFRESH;
                        wait_timer <= 0;
                        ref_timer  <= 0;
                        state      <= S_REFRESH_TRC;

                    when S_REFRESH_TRC =>
                        if wait_timer < T_RC - 1 then wait_timer <= wait_timer + 1; else state <= S_IDLE; end if;

                    -- ========================================================
                    -- FASE OPERATIVA: READ / WRITE
                    -- ========================================================
                    when S_ACTIVATE =>
                        -- Mandamos comando ACTIVATE para abrir la fila
                        cmd_reg  <= CMD_ACTIVE;
                        ba_reg   <= saved_addr(24 downto 23);
                        addr_reg <= saved_addr(22 downto 10);
                        state    <= S_TRCD;

                    when S_TRCD =>
                        -- tRCD: RAS to CAS delay = 15ns = 1 ciclo @ 50 MHz
                        if is_read = '1' then
                            state <= S_READ_CMD;
                        else
                            state <= S_WRITE_CMD;
                        end if;

                    when S_READ_CMD =>
                        cmd_reg <= CMD_READ;
                        ba_reg  <= saved_addr(24 downto 23);
                        -- La columna son los 10 bits bajos. Ponemos A10=1 para Auto-Precharge
                        addr_reg(9 downto 0) <= saved_addr(9 downto 0);
                        addr_reg(10) <= '1'; -- Auto-Precharge!
                        
                        -- Filtros de bytes invertidos (0 activa, 1 oculta)
                        dqm_reg(1) <= not saved_byte(1);
                        dqm_reg(0) <= not saved_byte(0);
                        
                        state <= S_CAS1;

                    when S_CAS1 =>
                        -- Primer ciclo de espera CAS
                        state <= S_CAS2;

                    when S_CAS2 =>
                        -- T2.0 a T3.0
                        state <= S_CAS3;

                    when S_CAS3 =>
                        -- En T3.5 (falling_edge), 'sdram_dq_falling' atrapo el dato.
                        -- Ahora en T4.0 (este flanco de subida), lo guardamos.
                        O_data_out <= sdram_dq_falling;
                        O_valid    <= '1';
                        
                        -- El Auto-Precharge ya esta cerrando la fila.
                        state      <= S_IDLE;

                    when S_WRITE_CMD =>
                        cmd_reg <= CMD_WRITE;
                        ba_reg  <= saved_addr(24 downto 23);
                        -- Columna y A10=1 para Auto-Precharge
                        addr_reg(9 downto 0) <= saved_addr(9 downto 0);
                        addr_reg(10) <= '1';
                        
                        -- Sacamos los datos y mascara de bytes
                        dq_out_en <= '1';
                        dq_out    <= saved_data;
                        dqm_reg(1)<= not saved_byte(1);
                        dqm_reg(0)<= not saved_byte(0);
                        
                        state <= S_TWR1;

                    when S_TWR1 =>
                        -- Write Recovery (tDPL/tWR). Mantenemos DQ por seguridad si hiciera falta
                        state <= S_TWR2;

                    when S_TWR2 =>
                        -- Fin de Write Recovery. Comienza Auto-Precharge internamente
                        wait_timer <= 0;
                        state      <= S_PRECHARGE_WAIT;

                    when S_PRECHARGE_WAIT =>
                        -- tRP = 15ns (1 ciclo). Al acabar volvemos a IDLE
                        if wait_timer < T_RP - 1 then 
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
