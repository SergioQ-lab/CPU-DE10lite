--------------------------------------------------------------------------------
-- sdram_controller.vhd
--
-- Controlador SDRAM random-access para IS42S16320D-7TL en DE10-Lite.
-- Reescritura desde cero. La interfaz exterior se mantiene compatible
-- con la version anterior (soc.vhd no necesita tocarse).
--
-- ============================================================================
-- PROTOCOLO DE HANDSHAKE
-- ============================================================================
-- La CPU presenta su peticion mientras una instruccion load/store esta en
-- la etapa MEM:
--
--   * I_rd_en = '1'  -> leer 16 bits de I_addr
--   * I_wr_en = '1'  -> escribir I_data_in en I_addr con mascara I_byte_en
--
-- El controlador devuelve O_busy en la misma combinacion logica:
--
--   busy = 1   <=>  hay transaccion en vuelo, O estamos en IDLE con peticion
--                   pendiente (CPU debe stallear, no avanzar pipeline).
--   busy = 0   <=>  estamos en RECOVERY (un ciclo de gracia para que la CPU
--                   avance ex_mem), O en IDLE sin peticion (sistema reposo).
--
-- El bit clave es la fase RECOVERY. Sin ella habia una race condition en
-- la que la CPU veia busy=0 y avanzaba ex_mem al mismo ciclo en que la FSM
-- veia rd_en/wr_en altos y re-disparaba con el contexto viejo. Con RECOVERY
-- introducimos un ciclo aislado: la CPU avanza, y solo en el SIGUIENTE
-- ciclo (ya en IDLE) volvemos a mirar las senales, que ahora reflejan la
-- nueva instruccion.
--
-- O_data_out se mantiene estable tras cada read hasta el siguiente read.
-- O_valid pulsa un ciclo cuando el dato se acaba de capturar.
--
-- ============================================================================
-- ARQUITECTURA DE MEMORIA
-- ============================================================================
-- IS42S16320D-7TL: 32M x 16 bits, 4 bancos, 8192 filas/banco, 1024 cols/fila.
--   I_addr[24:23] = banco
--   I_addr[22:10] = fila
--   I_addr[ 9: 0] = columna
--
-- ============================================================================
-- TIMINGS @ 50 MHz (periodo 20 ns)
-- ============================================================================
--   T_INIT_WAIT = 6000  (120 us de espera inicial tras power-up)
--   T_RP        = 1     (>=15 ns Row Precharge)
--   T_RCD       = 1     (>=15 ns RAS to CAS Delay) - cubierto por S_TRCD
--   T_RC        = 3     (>=60 ns Refresh Cycle)
--   T_MRD       = 2     (Mode Register Delay)
--   T_REFRESH   = 380   (7.6 us, margen frente a tREF/8192 = 7.81 us)
--   CAS Latency = 2
--   Burst Length= 1
--
-- ============================================================================
-- TIMING DE LECTURA (clock invertido para la SDRAM, sample en T_FPGA bajada)
-- ============================================================================
-- Cmd READ emitido por el FPGA en T_FPGA=1 (rising edge), visible a la SDRAM
-- en su flanco de subida T_FPGA=1.5 (porque O_sdram_clk = not I_clk).
-- Con CL=2, el dato aparece en DQ con tAC despues de T_FPGA=3.5.
-- Capturarlo en el flanco de bajada T_FPGA=4.5 nos da casi un ciclo de
-- margen sobre tAC (~5.5 ns), elimina la metaestabilidad observada.
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
        I_addr       : in    std_logic_vector(24 downto 0);
        I_data_in    : in    std_logic_vector(15 downto 0);
        O_data_out   : out   std_logic_vector(15 downto 0);
        I_rd_en      : in    std_logic;
        I_wr_en      : in    std_logic;
        I_byte_en    : in    std_logic_vector(1 downto 0);
        O_busy       : out   std_logic;
        O_valid      : out   std_logic;  -- pulso: dato de lectura listo
        O_done       : out   std_logic;  -- pulso: transaccion (read o write) completada

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

    -- ========================================================================
    -- Comandos SDRAM (concatenacion {CS_N, RAS_N, CAS_N, WE_N})
    -- ========================================================================
    constant CMD_NOP          : std_logic_vector(3 downto 0) := "0111";
    constant CMD_ACTIVE       : std_logic_vector(3 downto 0) := "0011";
    constant CMD_READ         : std_logic_vector(3 downto 0) := "0101";
    constant CMD_WRITE        : std_logic_vector(3 downto 0) := "0100";
    constant CMD_PRECHARGE    : std_logic_vector(3 downto 0) := "0010";
    constant CMD_AUTO_REFRESH : std_logic_vector(3 downto 0) := "0001";
    constant CMD_LOAD_MODE    : std_logic_vector(3 downto 0) := "0000";

    -- ========================================================================
    -- Timings (ciclos a 50 MHz)
    -- ========================================================================
    constant T_INIT_WAIT : integer := 6000;
    constant T_RP        : integer := 1;
    constant T_RC        : integer := 3;
    constant T_MRD       : integer := 2;
    constant T_REFRESH   : integer := 380;

    -- ========================================================================
    -- Estados de la FSM
    -- ========================================================================
    type fsm_state_t is (
        -- Inicializacion
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

        -- Activacion comun a read/write
        S_ACTIVATE,
        S_TRCD,

        -- Pipeline de lectura. Con BL=8 (mode register) tras CAS=2 ciclos
        -- la SDRAM saca 8 halfwords consecutivos en 8 ciclos.
        --   S_CAS1/2/3: wait + 1 extra cycle de margen tAC antes de capturar.
        --   S_BURST_RD: capturamos 8 halfwords con un contador.
        S_READ_CMD,
        S_CAS1,
        S_CAS2,
        S_CAS3,
        S_BURST_RD,

        -- Pipeline de escritura
        S_WRITE_CMD,
        S_TWR1,
        S_TWR2,
        S_PRECHARGE_WAIT,

        -- Ciclo de gracia: busy=0, FSM ignora rd/wr_en este ciclo.
        S_RECOVERY
    );

    signal state      : fsm_state_t := S_INIT_WAIT;
    signal wait_timer : integer range 0 to 8191 := 0;
    signal ref_timer  : integer range 0 to 511  := 0;
    signal burst_idx  : integer range 0 to 7    := 0;

    -- Salidas registradas hacia la SDRAM
    signal cmd_reg  : std_logic_vector(3 downto 0)  := CMD_NOP;
    signal addr_reg : std_logic_vector(12 downto 0) := (others => '0');
    signal ba_reg   : std_logic_vector(1 downto 0)  := "00";
    signal dqm_reg  : std_logic_vector(1 downto 0)  := "11"; -- arranque enmascarado

    -- Latch de la transaccion en curso
    signal is_read    : std_logic                     := '0';
    signal saved_addr : std_logic_vector(24 downto 0) := (others => '0');
    signal saved_data : std_logic_vector(15 downto 0) := (others => '0');
    signal saved_byte : std_logic_vector(1 downto 0)  := "00";

    -- Control del tri-state DQ
    signal dq_out_en : std_logic                     := '0';
    signal dq_out    : std_logic_vector(15 downto 0) := (others => '0');

    -- Captura del bus en flanco de bajada para tener margen sobre tAC
    signal sdram_dq_falling : std_logic_vector(15 downto 0) := (others => '0');

begin

    -- ========================================================================
    -- Reloj invertido a la SDRAM: nuestro flanco de bajada coincide con
    -- el flanco de subida de la SDRAM. Captura en falling_edge(I_clk)
    -- equivale a "sample en el centro del semi-ciclo SDRAM", maximo margen.
    -- ========================================================================
    O_sdram_clk <= not I_clk;
    O_sdram_cke <= '1';

    -- Pines de control hacia el chip
    O_sdram_cs_n  <= cmd_reg(3);
    O_sdram_ras_n <= cmd_reg(2);
    O_sdram_cas_n <= cmd_reg(1);
    O_sdram_we_n  <= cmd_reg(0);
    O_sdram_addr  <= addr_reg;
    O_sdram_ba    <= ba_reg;
    O_sdram_udqm  <= dqm_reg(1);
    O_sdram_ldqm  <= dqm_reg(0);

    -- Buffer tri-estado bidireccional
    IO_sdram_dq <= dq_out when dq_out_en = '1' else (others => 'Z');

    -- ========================================================================
    -- O_busy combinacional con la regla del handshake.
    --
    -- '0' SOLO si:
    --   * estamos en RECOVERY (ciclo de gracia intencional), o
    --   * estamos en IDLE y la CPU no esta pidiendo nada.
    -- En cualquier otro caso (transaccion en vuelo, init, refresh, IDLE-con-
    -- peticion-pendiente) el bus esta ocupado.
    --
    -- Que sea combinacional sobre rd_en/wr_en es lo que hace que en el ciclo
    -- IDLE con peticion la CPU YA vea busy=1 y se stallee, antes de que la
    -- FSM transicione a ACTIVATE en el siguiente flanco.
    -- ========================================================================
    O_busy <= '0' when state = S_RECOVERY else
              '0' when (state = S_IDLE and I_rd_en = '0' and I_wr_en = '0') else
              '1';

    -- ========================================================================
    -- Captura del bus DQ en el flanco de bajada del reloj FPGA.
    -- Sirve para muestrear el dato de la SDRAM con margen sobre tAC.
    -- ========================================================================
    capture_proc : process (I_clk)
    begin
        if falling_edge(I_clk) then
            sdram_dq_falling <= IO_sdram_dq;
        end if;
    end process;

    -- ========================================================================
    -- FSM principal
    -- ========================================================================
    fsm_proc : process (I_clk)
    begin
        if rising_edge(I_clk) then
            if I_reset = '1' then
                state      <= S_INIT_WAIT;
                wait_timer <= 0;
                ref_timer  <= 0;
                cmd_reg    <= CMD_NOP;
                addr_reg   <= (others => '0');
                ba_reg     <= "00";
                dqm_reg    <= "11";
                dq_out_en  <= '0';
                O_valid    <= '0';
                O_done     <= '0';
                O_data_out <= (others => '0');
            else
                -- Defaults cada ciclo. El case puede sobrescribir.
                cmd_reg   <= CMD_NOP;
                addr_reg  <= (others => '0');
                ba_reg    <= "00";
                dqm_reg   <= "00";
                dq_out_en <= '0';
                O_valid   <= '0';
                O_done    <= '0';

                -- Contador de refresco siempre corre (excepto durante el
                -- power-up wait, antes de que la SDRAM este lista).
                if state /= S_INIT_WAIT then
                    ref_timer <= ref_timer + 1;
                end if;

                case state is
                    -- ============================================
                    -- INICIALIZACION
                    -- ============================================
                    when S_INIT_WAIT =>
                        if wait_timer < T_INIT_WAIT then
                            wait_timer <= wait_timer + 1;
                        else
                            state <= S_INIT_PRECHARGE;
                        end if;

                    when S_INIT_PRECHARGE =>
                        cmd_reg    <= CMD_PRECHARGE;
                        addr_reg   <= (10 => '1', others => '0'); -- A10=1 PRECHARGE ALL
                        wait_timer <= 0;
                        state      <= S_INIT_TRP;

                    when S_INIT_TRP =>
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
                        if wait_timer < T_RC - 1 then
                            wait_timer <= wait_timer + 1;
                        else
                            state <= S_INIT_LMR;
                        end if;

                    when S_INIT_LMR =>
                        cmd_reg    <= CMD_LOAD_MODE;
                        -- Mode Register:
                        --   [2:0] = burst length = 8 -> "011"
                        --   [ 3 ] = burst type   = sequential -> '0'
                        --   [6:4] = CAS latency  = 2 -> "010"
                        --   [8:7] = op. mode     = standard -> "00"
                        --   [ 9 ] = write burst  = SINGLE -> '1'   (escrituras de 1 halfword)
                        addr_reg   <= "0001000100011";
                        wait_timer <= 0;
                        state      <= S_INIT_TMRD;

                    when S_INIT_TMRD =>
                        if wait_timer < T_MRD - 1 then
                            wait_timer <= wait_timer + 1;
                        else
                            state     <= S_IDLE;
                            ref_timer <= 0;
                        end if;

                    -- ============================================
                    -- OPERACION NORMAL
                    -- ============================================
                    when S_IDLE =>
                        -- Prioridad: refresh > read > write.
                        -- Capturamos toda la peticion (addr/data/byte/es-read)
                        -- en este ciclo. A partir del proximo flanco la CPU
                        -- puede mantener stall mientras hagamos la transaccion.
                        if ref_timer >= T_REFRESH then
                            state <= S_REFRESH_CMD;
                        elsif I_rd_en = '1' then
                            is_read    <= '1';
                            saved_addr <= I_addr;
                            saved_byte <= I_byte_en;
                            state      <= S_ACTIVATE;
                        elsif I_wr_en = '1' then
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
                        if wait_timer < T_RC - 1 then
                            wait_timer <= wait_timer + 1;
                        else
                            state <= S_IDLE;
                        end if;

                    -- ============================================
                    -- ACTIVACION (comun a read y write)
                    -- ============================================
                    when S_ACTIVATE =>
                        cmd_reg  <= CMD_ACTIVE;
                        ba_reg   <= saved_addr(24 downto 23);
                        addr_reg <= saved_addr(22 downto 10); -- fila
                        state    <= S_TRCD;

                    when S_TRCD =>
                        -- tRCD (15 ns) cubierto por este ciclo. NOP en el bus.
                        if is_read = '1' then
                            state <= S_READ_CMD;
                        else
                            state <= S_WRITE_CMD;
                        end if;

                    -- ============================================
                    -- LECTURA (CL=2 + 1 ciclo extra de margen tAC)
                    -- ============================================
                    when S_READ_CMD =>
                        cmd_reg              <= CMD_READ;
                        ba_reg               <= saved_addr(24 downto 23);
                        addr_reg(9 downto 0) <= saved_addr(9 downto 0); -- columna
                        addr_reg(10)         <= '1';                    -- Auto-Precharge
                        -- En READ, DQM controla el output-enable de la SDRAM.
                        -- Si lo levantamos, la SDRAM deja DQ en alta impedancia
                        -- y leeriamos 0xFFFF. SIEMPRE 00 en read: la extraccion
                        -- de byte/half la hace la etapa WB de la CPU.
                        dqm_reg <= "00";
                        state   <= S_CAS1;

                    when S_CAS1 =>
                        state <= S_CAS2;

                    when S_CAS2 =>
                        state <= S_CAS3;

                    when S_CAS3 =>
                        -- En este flanco la SDRAM acaba de empezar a manejar
                        -- DQ del primer halfword (tAC todavia no ha vencido).
                        -- Esperamos un ciclo mas y entramos al burst.
                        burst_idx <= 0;
                        state     <= S_BURST_RD;

                    when S_BURST_RD =>
                        -- 8 halfwords consecutivos. En cada ciclo capturamos
                        -- 'sdram_dq_falling' (que contiene el halfword cuyo
                        -- flanco de bajada FPGA correspondiente fue el ultimo,
                        -- con ~5 ns de margen sobre tAC).
                        O_data_out <= sdram_dq_falling;
                        O_valid    <= '1';
                        if burst_idx = 7 then
                            -- Ultimo halfword del burst. Pulsamos done.
                            O_done <= '1';
                            state  <= S_RECOVERY;
                        else
                            burst_idx <= burst_idx + 1;
                        end if;

                    -- ============================================
                    -- ESCRITURA + Auto-Precharge
                    -- ============================================
                    when S_WRITE_CMD =>
                        cmd_reg              <= CMD_WRITE;
                        ba_reg               <= saved_addr(24 downto 23);
                        addr_reg(9 downto 0) <= saved_addr(9 downto 0);
                        addr_reg(10)         <= '1';
                        -- En WRITE, DQM es mascara de byte (1 = no escribir
                        -- ese byte). I_byte_en es activo en alto, asi que
                        -- invertimos.
                        dqm_reg(1) <= not saved_byte(1);
                        dqm_reg(0) <= not saved_byte(0);
                        dq_out_en  <= '1';
                        dq_out     <= saved_data;
                        state      <= S_TWR1;

                    when S_TWR1 =>
                        -- Mantenemos un ciclo mas el dato y comando estables
                        -- para no violar tDPL.
                        state <= S_TWR2;

                    when S_TWR2 =>
                        wait_timer <= 0;
                        state      <= S_PRECHARGE_WAIT;

                    when S_PRECHARGE_WAIT =>
                        -- Auto-Precharge interno de la SDRAM acaba aqui.
                        if wait_timer < T_RP - 1 then
                            wait_timer <= wait_timer + 1;
                        else
                            O_done <= '1';   -- pulso unificado: write completado
                            state  <= S_RECOVERY;
                        end if;

                    -- ============================================
                    -- RECOVERY: el corazon del fix
                    --
                    -- Durante este ciclo busy=0 (asignado combinacionalmente
                    -- arriba), asi que la CPU sale del stall y avanza ex_mem
                    -- en el flanco siguiente. La FSM aqui no mira rd_en/wr_en
                    -- ni los timers de refresh: simplemente transiciona a
                    -- IDLE, donde ya veremos las senales nuevas de la CPU.
                    -- ============================================
                    when S_RECOVERY =>
                        state <= S_IDLE;

                    when others =>
                        state <= S_INIT_WAIT;
                end case;
            end if;
        end if;
    end process;

end architecture Behavioral;
