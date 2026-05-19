--------------------------------------------------------------------------------
-- dcache.vhd
--
-- Cache de datos para la region SDRAM (0x2000_0000..0x23FF_FFFF).
--
-- ============================================================================
-- PARAMETROS
-- ============================================================================
--   Tamano total      : 4 KB (1024 entradas de 32 bits)
--   Topologia         : Direct-mapped
--   Tamano de linea   : 4 bytes (1 palabra de 32 bits)
--   Politica escritura: Write-through, no-write-allocate
--   Politica lectura  : Read-allocate (al miss se cachea)
--
-- ============================================================================
-- ADDRESS DECODING (direccion byte de 32 bits)
-- ============================================================================
--   [31:12] = tag        (20 bits)
--   [11: 2] = index      (10 bits -> 1024 entradas)
--   [ 1: 0] = byte offset (lo gestiona la CPU en WB)
--
-- ============================================================================
-- PROTOCOLO DE HANDSHAKE
-- ============================================================================
-- La CPU presenta I_req (= sel_sdram desde el SoC) + I_we + I_addr + I_be + ...
-- El cache responde con O_rdata (lectura) y O_busy (stallea la CPU mientras
-- procesa).
--
-- O_busy es combinacional para evitar la race condition clasica:
--   '0' SOLO cuando estamos en IDLE sin peticion, o cuando estamos en
--   LOOKUP y hemos resuelto un HIT de lectura. En cualquier otro caso '1'.
--
-- ============================================================================
-- ESTRATEGIA EN MISSES
-- ============================================================================
-- En un miss de lectura: pedimos al SDRAM dos halfwords (low + high), los
-- combinamos en una palabra de 32 bits y la ESCRIBIMOS en el cache. Luego
-- volvemos a IDLE. Como la CPU sigue stalleada con la misma instruccion en
-- ex_mem, en el siguiente ciclo presenta la misma peticion y el cache hace
-- otro LOOKUP -- esta vez con hit, devolviendo el dato recien cacheado.
--
-- Esto evita la complejidad del read-during-write del BRAM en el ciclo del
-- propio fill: por el doble lookup, cuando re-leemos el dato ya esta
-- propagado en el BRAM (un ciclo entero ha pasado).
--
-- Coste: 2 lookups por miss en lugar de 1. Los contadores marcan tanto la
-- miss inicial como el hit del re-lookup; en codigo de usuario esto se
-- traduce en miss+1 y hit+1 por cada miss real. No es enganoso, pero hay
-- que tener esto en cuenta al interpretar las cifras.
--
-- ============================================================================
-- INTERFAZ AL SDRAM
-- ============================================================================
-- Identica al SoC: addr 25-bit + data 16-bit + rd/wr_en + busy + valid.
-- El cache hace de capa de abstraccion 32<->16: cada acceso de 32 bits
-- corresponde a dos transacciones de 16 bits al controlador.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity dcache is
    generic (
        INDEX_BITS : integer := 10;   -- 2^10 = 1024 entradas
        TAG_BITS   : integer := 20    -- tag de 20 bits
    );
    port (
        I_clk        : in  std_logic;
        I_reset      : in  std_logic;

        -- Lado CPU
        I_req        : in  std_logic;
        I_addr       : in  std_logic_vector(31 downto 0);
        I_wdata      : in  std_logic_vector(31 downto 0);
        O_rdata      : out std_logic_vector(31 downto 0);
        I_we         : in  std_logic;
        I_be         : in  std_logic_vector(3 downto 0);
        O_busy       : out std_logic;

        -- Lado SDRAM controller (16-bit)
        O_mem_addr   : out std_logic_vector(24 downto 0);
        O_mem_wdata  : out std_logic_vector(15 downto 0);
        I_mem_rdata  : in  std_logic_vector(15 downto 0);
        O_mem_rd_en  : out std_logic;
        O_mem_wr_en  : out std_logic;
        O_mem_be     : out std_logic_vector(1 downto 0);
        I_mem_busy   : in  std_logic;
        I_mem_valid  : in  std_logic;

        -- Contadores
        O_hit_count  : out std_logic_vector(31 downto 0);
        O_miss_count : out std_logic_vector(31 downto 0)
    );
end entity dcache;

architecture Behavioral of dcache is

    constant N_LINES : integer := 2**INDEX_BITS;

    ------------------------------------------------------------------------
    -- Storage
    ------------------------------------------------------------------------
    type valid_array_t is array (0 to N_LINES-1) of std_logic;
    type tag_array_t   is array (0 to N_LINES-1) of std_logic_vector(TAG_BITS-1 downto 0);
    type data_array_t  is array (0 to N_LINES-1) of std_logic_vector(31 downto 0);

    signal cache_valid : valid_array_t := (others => '0');
    signal cache_tag   : tag_array_t;
    signal cache_data  : data_array_t;

    attribute ramstyle : string;
    -- valid es pequeno -> registros (lectura combinacional inmediata).
    attribute ramstyle of cache_valid : signal is "logic";
    -- tag y data van a M9K.
    attribute ramstyle of cache_tag  : signal is "M9K";
    attribute ramstyle of cache_data : signal is "M9K";

    ------------------------------------------------------------------------
    -- Salidas registradas de la BRAM
    ------------------------------------------------------------------------
    signal cache_d_r : std_logic_vector(31 downto 0);
    signal cache_t_r : std_logic_vector(TAG_BITS-1 downto 0);
    signal cache_v_r : std_logic;

    ------------------------------------------------------------------------
    -- Indices y tag de la peticion actual
    ------------------------------------------------------------------------
    signal idx_in    : integer range 0 to N_LINES-1;
    signal tag_in    : std_logic_vector(TAG_BITS-1 downto 0);

    ------------------------------------------------------------------------
    -- Estados del FSM
    ------------------------------------------------------------------------
    type state_t is (
        S_IDLE,        -- esperando peticion
        S_LOOKUP,      -- BRAM acaba de entregar, decidimos hit/miss
        S_FILL_REQ,    -- arrancar peticion 16-bit a SDRAM
        S_FILL_WAIT,   -- esperando valid pulse
        S_WR_REQ,      -- arrancar escritura 16-bit a SDRAM
        S_WR_WAIT,     -- esperando fin de escritura SDRAM
        S_RECOVERY     -- ciclo de gracia post-write: busy=0 pero no aceptamos
                       -- peticiones, para que la CPU avance ex_mem fuera del
                       -- stall antes de que volvamos a mirar I_req
    );
    signal state : state_t := S_IDLE;

    ------------------------------------------------------------------------
    -- Auxiliares de la transaccion en curso
    ------------------------------------------------------------------------
    signal pend_addr  : std_logic_vector(31 downto 0);
    signal pend_wdata : std_logic_vector(31 downto 0);
    signal pend_be    : std_logic_vector(3 downto 0);
    signal pend_is_wr : std_logic;

    -- Latch del halfword bajo mientras pedimos el alto
    signal refill_lo : std_logic_vector(15 downto 0);

    -- 0 = procesar low halfword, 1 = procesar high halfword
    signal halfword_idx : std_logic;

    -- Estado del handshake con la SDRAM
    signal mem_in_flight : std_logic;

    -- Flag: el proximo LOOKUP es el re-lookup que sigue a un fill.
    -- Lo usamos para NO contar ese hit (es del mismo acceso que ya conto
    -- como miss). Asi los contadores reflejan accesos reales.
    signal post_fill : std_logic := '0';

    ------------------------------------------------------------------------
    -- Hit combinacional valido cuando estamos en LOOKUP
    ------------------------------------------------------------------------
    signal lookup_hit : std_logic;

    ------------------------------------------------------------------------
    -- Salidas combinacionales
    ------------------------------------------------------------------------
    signal busy_int  : std_logic;

    ------------------------------------------------------------------------
    -- Contadores
    ------------------------------------------------------------------------
    signal hit_count_reg  : unsigned(31 downto 0) := (others => '0');
    signal miss_count_reg : unsigned(31 downto 0) := (others => '0');

begin

    ---------------------------------------------------------------------------
    -- Decodificacion combinacional del address
    ---------------------------------------------------------------------------
    idx_in <= to_integer(unsigned(I_addr(INDEX_BITS + 1 downto 2)));
    tag_in <= I_addr(31 downto INDEX_BITS + 2);

    ---------------------------------------------------------------------------
    -- Lectura de las memorias del cache. Salida registrada (1 ciclo latencia).
    ---------------------------------------------------------------------------
    cache_read_proc : process (I_clk)
    begin
        if rising_edge(I_clk) then
            cache_d_r <= cache_data(idx_in);
            cache_t_r <= cache_tag(idx_in);
            cache_v_r <= cache_valid(idx_in);
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Hit/miss combinacional usando los valores registrados de BRAM
    -- y el tag de la peticion latcheada en pend_addr.
    ---------------------------------------------------------------------------
    lookup_hit <= '1' when (cache_v_r = '1' and cache_t_r = pend_addr(31 downto INDEX_BITS + 2))
                  else '0';

    ---------------------------------------------------------------------------
    -- O_busy combinacional. La CPU se stallea siempre que estemos haciendo
    -- algo que no sea "IDLE-sin-peticion" o "LOOKUP-resuelto-hit-read".
    -- Esto incluye el ciclo IDLE-con-peticion-pendiente, igual que en el
    -- SDRAM: asi la CPU no avanza por delante de nosotros.
    ---------------------------------------------------------------------------
    -- busy=0 en:
    --   - IDLE sin peticion (sistema en reposo)
    --   - LOOKUP con hit-read resuelto en este ciclo (la CPU consumira
    --     cache_d_r y avanzara)
    --   - RECOVERY (ciclo de gracia post-write: la CPU avanza ex_mem y en
    --     el proximo ciclo veremos una peticion nueva, no la vieja)
    busy_int <= '0' when state = S_RECOVERY else
                '0' when (state = S_IDLE   and I_req = '0') else
                '0' when (state = S_LOOKUP and lookup_hit = '1' and pend_is_wr = '0') else
                '1';
    O_busy   <= busy_int;

    ---------------------------------------------------------------------------
    -- O_rdata: cache_d_r en cualquier ciclo donde la CPU consume. En LOOKUP
    -- el dato es directamente el del BRAM; en IDLE (post-fill), tambien
    -- (ha pasado un ciclo, el write se ha propagado y el re-lookup leera
    -- el valor recien escrito).
    ---------------------------------------------------------------------------
    O_rdata <= cache_d_r;

    ---------------------------------------------------------------------------
    -- FSM principal
    ---------------------------------------------------------------------------
    fsm_proc : process (I_clk)
        variable sd_addr_word : std_logic_vector(24 downto 0);
        variable update_word  : std_logic_vector(31 downto 0);
        variable idx_int      : integer range 0 to N_LINES-1;
    begin
        if rising_edge(I_clk) then
            if I_reset = '1' then
                state          <= S_IDLE;
                halfword_idx   <= '0';
                mem_in_flight  <= '0';
                post_fill      <= '0';
                hit_count_reg  <= (others => '0');
                miss_count_reg <= (others => '0');
                pend_addr      <= (others => '0');
                pend_wdata     <= (others => '0');
                pend_be        <= (others => '0');
                pend_is_wr     <= '0';
                refill_lo      <= (others => '0');
                O_mem_rd_en    <= '0';
                O_mem_wr_en    <= '0';
                O_mem_addr     <= (others => '0');
                O_mem_wdata    <= (others => '0');
                O_mem_be       <= "00";
                -- Limpiar validez del cache (cache frio en reset)
                for i in 0 to N_LINES-1 loop
                    cache_valid(i) <= '0';
                end loop;
            else
                -- Defaults
                O_mem_rd_en <= '0';
                O_mem_wr_en <= '0';

                case state is
                    -- ----------------------------------------------------
                    when S_IDLE =>
                        if I_req = '1' then
                            pend_addr  <= I_addr;
                            pend_wdata <= I_wdata;
                            pend_be    <= I_be;
                            pend_is_wr <= I_we;
                            state      <= S_LOOKUP;
                        end if;

                    -- ----------------------------------------------------
                    when S_LOOKUP =>
                        idx_int := to_integer(unsigned(pend_addr(INDEX_BITS+1 downto 2)));
                        if lookup_hit = '1' then
                            -- Solo contamos hit si NO es el re-lookup que sigue
                            -- inmediatamente a un fill (esos pertenecen al mismo
                            -- acceso que ya conto como miss).
                            if post_fill = '0' then
                                hit_count_reg <= hit_count_reg + 1;
                            end if;
                            post_fill <= '0';
                            if pend_is_wr = '0' then
                                -- HIT-READ. Volvemos a IDLE; la CPU consumira
                                -- cache_d_r combinacionalmente en este ciclo.
                                state <= S_IDLE;
                            else
                                -- HIT-WRITE. Actualizamos el cache con los
                                -- bytes seleccionados y arrancamos write-through.
                                update_word := cache_d_r;
                                if pend_be(0) = '1' then update_word( 7 downto  0) := pend_wdata( 7 downto  0); end if;
                                if pend_be(1) = '1' then update_word(15 downto  8) := pend_wdata(15 downto  8); end if;
                                if pend_be(2) = '1' then update_word(23 downto 16) := pend_wdata(23 downto 16); end if;
                                if pend_be(3) = '1' then update_word(31 downto 24) := pend_wdata(31 downto 24); end if;
                                cache_data(idx_int) <= update_word;
                                halfword_idx  <= '0';
                                mem_in_flight <= '0';
                                state         <= S_WR_REQ;
                            end if;
                        else
                            -- MISS
                            miss_count_reg <= miss_count_reg + 1;
                            halfword_idx   <= '0';
                            mem_in_flight  <= '0';
                            if pend_is_wr = '0' then
                                state <= S_FILL_REQ;
                            else
                                -- Write miss: write-through sin allocate.
                                state <= S_WR_REQ;
                            end if;
                        end if;

                    -- ----------------------------------------------------
                    -- Miss de lectura
                    -- ----------------------------------------------------
                    when S_FILL_REQ =>
                        sd_addr_word := pend_addr(25 downto 2) & halfword_idx;
                        O_mem_addr   <= sd_addr_word;
                        O_mem_rd_en  <= '1';
                        O_mem_be     <= "11";  -- ignored on read by sdram (DQM=00 inside)
                        if I_mem_busy = '1' then
                            mem_in_flight <= '1';
                            state         <= S_FILL_WAIT;
                        end if;

                    when S_FILL_WAIT =>
                        idx_int := to_integer(unsigned(pend_addr(INDEX_BITS+1 downto 2)));
                        if I_mem_valid = '1' then
                            if halfword_idx = '0' then
                                refill_lo    <= I_mem_rdata;
                                halfword_idx <= '1';
                                mem_in_flight<= '0';
                                state        <= S_FILL_REQ;
                            else
                                -- High halfword recibido. Componemos la palabra
                                -- de 32 bits y la escribimos al cache. Luego
                                -- volvemos a IDLE: la CPU sigue stalleada, en
                                -- el siguiente ciclo re-presentara la misma
                                -- peticion y haremos un nuevo lookup -- esta
                                -- vez hit, con cache_d_r mostrando el dato
                                -- recien escrito.
                                cache_data(idx_int)  <= I_mem_rdata & refill_lo;
                                cache_tag(idx_int)   <= pend_addr(31 downto INDEX_BITS+2);
                                cache_valid(idx_int) <= '1';
                                post_fill            <= '1';  -- el proximo lookup es re-lookup
                                state                <= S_IDLE;
                            end if;
                        end if;

                    -- ----------------------------------------------------
                    -- Write-through (1 o 2 halfwords)
                    -- ----------------------------------------------------
                    when S_WR_REQ =>
                        sd_addr_word := pend_addr(25 downto 2) & halfword_idx;
                        O_mem_addr   <= sd_addr_word;

                        if halfword_idx = '0' then
                            if pend_be(1 downto 0) = "00" then
                                -- Nada que escribir en low half: saltar a high.
                                halfword_idx <= '1';
                            else
                                O_mem_wdata <= pend_wdata(15 downto 0);
                                O_mem_be    <= pend_be(1 downto 0);
                                O_mem_wr_en <= '1';
                                if I_mem_busy = '1' then
                                    mem_in_flight <= '1';
                                    state         <= S_WR_WAIT;
                                end if;
                            end if;
                        else
                            if pend_be(3 downto 2) = "00" then
                                -- Mismo motivo que la salida normal:
                                -- pasamos por RECOVERY para no quedarnos
                                -- atrapados en un loop con la CPU.
                                state <= S_RECOVERY;
                            else
                                O_mem_wdata <= pend_wdata(31 downto 16);
                                O_mem_be    <= pend_be(3 downto 2);
                                O_mem_wr_en <= '1';
                                if I_mem_busy = '1' then
                                    mem_in_flight <= '1';
                                    state         <= S_WR_WAIT;
                                end if;
                            end if;
                        end if;

                    when S_WR_WAIT =>
                        if mem_in_flight = '1' and I_mem_busy = '0' then
                            mem_in_flight <= '0';
                            if halfword_idx = '0' then
                                halfword_idx <= '1';
                                state        <= S_WR_REQ;
                            else
                                -- Ambos halfwords escritos. Pasamos por
                                -- RECOVERY (busy=0 sin aceptar peticiones)
                                -- para que la CPU avance ex_mem antes de
                                -- que volvamos a IDLE y miremos I_req.
                                state <= S_RECOVERY;
                            end if;
                        end if;

                    when S_RECOVERY =>
                        state <= S_IDLE;

                    when others =>
                        state <= S_IDLE;
                end case;
            end if;
        end if;
    end process;

    O_hit_count  <= std_logic_vector(hit_count_reg);
    O_miss_count <= std_logic_vector(miss_count_reg);

end architecture Behavioral;
