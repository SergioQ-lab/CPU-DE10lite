--------------------------------------------------------------------------------
-- dcache.vhd
--
-- Cache de datos para la region SDRAM (0x2000_0000..0x23FF_FFFF).
--
-- ============================================================================
-- PARAMETROS
-- ============================================================================
--   Tamano total      : 4 KB (256 lineas de 16 bytes)
--   Topologia         : Direct-mapped
--   Tamano de linea   : 16 bytes = 4 palabras de 32 bits
--   Politica escritura: Write-through, no-write-allocate
--   Politica lectura  : Read-allocate (al miss se cachea la linea entera)
--
-- ============================================================================
-- ADDRESS DECODING (direccion byte de 32 bits)
-- ============================================================================
--   [31:12] = tag         (20 bits)
--   [11: 4] = index       (8 bits -> 256 lineas)
--   [ 3: 2] = word offset (2 bits -> 4 palabras / linea)
--   [ 1: 0] = byte offset (lo gestiona la CPU en WB)
--
-- ============================================================================
-- RELLENO POR BURST
-- ============================================================================
-- En un miss de lectura, lanzamos UN burst de 8 halfwords al SDRAM (BL=8).
-- Eso son 16 bytes = una linea completa. Los acumulamos en refill_buf y
-- al recibir I_mem_done escribimos la linea entera al cache.
--
-- Coste aproximado:
--   Hit  (read)     : 2 ciclos
--   Miss (read)     : ACTIVATE(1) + TRCD(1) + READ_CMD(1) + CAS(3) + 8 burst
--                     + RECOVERY(1) = ~15 ciclos, traen 4 palabras de golpe
--                     -> ~4 ciclos efectivos por palabra (vs ~26 antes).
--   Write           : ~26 ciclos (no cambia, write-through single)
--
-- ============================================================================
-- PROTOCOLO DE HANDSHAKE
-- ============================================================================
-- O_busy combinacional. '0' solo en IDLE-sin-peticion, LOOKUP-hit-read, o
-- RECOVERY. Garantiza que la CPU no avance por delante del cache.
--
-- En los WAIT mantenemos rd_en/wr_en/addr altos hasta que I_mem_done pulse,
-- asi sobrevivimos a refreshes intercalados de la SDRAM sin perder la
-- peticion.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity dcache is
    generic (
        INDEX_BITS  : integer := 8;    -- 2^8 = 256 lineas
        TAG_BITS    : integer := 20;
        LINE_WORDS  : integer := 4     -- 4 palabras de 32 bits por linea
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

        -- Lado SDRAM controller (16-bit). BL=8 en lecturas.
        O_mem_addr   : out std_logic_vector(24 downto 0);
        O_mem_wdata  : out std_logic_vector(15 downto 0);
        I_mem_rdata  : in  std_logic_vector(15 downto 0);
        O_mem_rd_en  : out std_logic;
        O_mem_wr_en  : out std_logic;
        O_mem_be     : out std_logic_vector(1 downto 0);
        I_mem_busy   : in  std_logic;
        I_mem_valid  : in  std_logic;    -- pulso por cada halfword del burst
        I_mem_done   : in  std_logic;    -- pulso unico al final de la transaccion

        -- Contadores
        O_hit_count  : out std_logic_vector(31 downto 0);
        O_miss_count : out std_logic_vector(31 downto 0)
    );
end entity dcache;

architecture Behavioral of dcache is

    constant N_LINES      : integer := 2**INDEX_BITS;
    constant LINE_BITS    : integer := LINE_WORDS * 32;     -- 128

    ------------------------------------------------------------------------
    -- Storage
    --
    -- 4 BRAMs separados de 32 bits para las palabras de la linea (uno por
    -- word offset). Cada uno se infiere como un M9K limpio. Quartus
    -- tiene problemas con arrays de 128 bits para dual-port BRAM, asi que
    -- los separamos a mano.
    ------------------------------------------------------------------------
    type valid_array_t is array (0 to N_LINES-1) of std_logic;
    type tag_array_t   is array (0 to N_LINES-1) of std_logic_vector(TAG_BITS-1 downto 0);
    type word_array_t  is array (0 to N_LINES-1) of std_logic_vector(31 downto 0);

    signal cache_valid : valid_array_t := (others => '0');
    signal cache_tag   : tag_array_t;
    signal cache_w0    : word_array_t;
    signal cache_w1    : word_array_t;
    signal cache_w2    : word_array_t;
    signal cache_w3    : word_array_t;

    attribute ramstyle : string;
    attribute ramstyle of cache_valid : signal is "logic";
    attribute ramstyle of cache_tag   : signal is "M9K";
    attribute ramstyle of cache_w0    : signal is "M9K";
    attribute ramstyle of cache_w1    : signal is "M9K";
    attribute ramstyle of cache_w2    : signal is "M9K";
    attribute ramstyle of cache_w3    : signal is "M9K";

    ------------------------------------------------------------------------
    -- Salidas registradas de la BRAM
    ------------------------------------------------------------------------
    signal cache_v_r  : std_logic;
    signal cache_t_r  : std_logic_vector(TAG_BITS-1 downto 0);
    signal cache_w0_r : std_logic_vector(31 downto 0);
    signal cache_w1_r : std_logic_vector(31 downto 0);
    signal cache_w2_r : std_logic_vector(31 downto 0);
    signal cache_w3_r : std_logic_vector(31 downto 0);

    ------------------------------------------------------------------------
    -- Slices de la direccion
    ------------------------------------------------------------------------
    signal idx_in : integer range 0 to N_LINES-1;

    ------------------------------------------------------------------------
    -- FSM
    ------------------------------------------------------------------------
    type state_t is (
        S_IDLE,
        S_LOOKUP,
        S_FILL_REQ,    -- iniciar burst read al SDRAM
        S_FILL_WAIT,   -- acumular 8 halfwords del burst
        S_WR_REQ,      -- iniciar write 16-bit al SDRAM (single)
        S_WR_WAIT,
        S_RECOVERY
    );
    signal state : state_t := S_IDLE;

    ------------------------------------------------------------------------
    -- Auxiliares de la transaccion en curso
    ------------------------------------------------------------------------
    signal pend_addr  : std_logic_vector(31 downto 0);
    signal pend_wdata : std_logic_vector(31 downto 0);
    signal pend_be    : std_logic_vector(3 downto 0);
    signal pend_is_wr : std_logic;

    -- Buffer de relleno: 8 halfwords del burst, accumulando en orden
    signal refill_buf : std_logic_vector(LINE_BITS-1 downto 0);
    signal refill_cnt : integer range 0 to 8;

    -- Para writes: 0 = procesar low halfword, 1 = procesar high halfword
    signal halfword_idx : std_logic;

    ------------------------------------------------------------------------
    -- Hit combinacional valido cuando estamos en LOOKUP
    ------------------------------------------------------------------------
    signal lookup_hit : std_logic;

    ------------------------------------------------------------------------
    -- Salidas combinacionales
    ------------------------------------------------------------------------
    signal busy_int    : std_logic;
    signal word_sel    : std_logic_vector(1 downto 0);
    signal cache_d_r   : std_logic_vector(31 downto 0);

    ------------------------------------------------------------------------
    -- Flag para no contar el hit del re-lookup post-fill como acceso real
    ------------------------------------------------------------------------
    signal post_fill : std_logic := '0';

    ------------------------------------------------------------------------
    -- Contadores
    ------------------------------------------------------------------------
    signal hit_count_reg  : unsigned(31 downto 0) := (others => '0');
    signal miss_count_reg : unsigned(31 downto 0) := (others => '0');

begin

    ---------------------------------------------------------------------------
    -- Decodificacion combinacional del address
    ---------------------------------------------------------------------------
    -- I_addr[INDEX_BITS+3 : 4] = idx (8 bits para 256 lineas).
    -- I_addr[3:2]              = word_sel (4 palabras/linea).
    idx_in <= to_integer(unsigned(I_addr(INDEX_BITS + 3 downto 4)));

    -- word_sel viene de pend_addr (registrado en S_IDLE->S_LOOKUP).
    -- Asi el mux de cache_d_r es estable a lo largo de la transaccion en
    -- curso, independiente de la I_addr que la CPU presente despues.
    word_sel <= pend_addr(3 downto 2);

    ---------------------------------------------------------------------------
    -- Lectura sincrona del cache (BRAM con salida registrada)
    ---------------------------------------------------------------------------
    cache_read_proc : process (I_clk)
    begin
        if rising_edge(I_clk) then
            cache_v_r  <= cache_valid(idx_in);
            cache_t_r  <= cache_tag(idx_in);
            cache_w0_r <= cache_w0(idx_in);
            cache_w1_r <= cache_w1(idx_in);
            cache_w2_r <= cache_w2(idx_in);
            cache_w3_r <= cache_w3(idx_in);
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Hit detection y mux de palabra
    ---------------------------------------------------------------------------
    lookup_hit <= '1' when (cache_v_r = '1' and cache_t_r = pend_addr(31 downto INDEX_BITS + 4))
                  else '0';

    cache_d_r <= cache_w0_r when word_sel = "00" else
                 cache_w1_r when word_sel = "01" else
                 cache_w2_r when word_sel = "10" else
                 cache_w3_r;

    ---------------------------------------------------------------------------
    -- O_busy combinacional. Mismo principio que antes: '0' solo en RECOVERY
    -- o IDLE-sin-peticion o LOOKUP-hit-read.
    ---------------------------------------------------------------------------
    busy_int <= '0' when state = S_RECOVERY else
                '0' when (state = S_IDLE   and I_req = '0') else
                '0' when (state = S_LOOKUP and lookup_hit = '1' and pend_is_wr = '0') else
                '1';
    O_busy   <= busy_int;

    O_rdata <= cache_d_r;

    ---------------------------------------------------------------------------
    -- FSM principal
    ---------------------------------------------------------------------------
    fsm_proc : process (I_clk)
        variable idx_int      : integer range 0 to N_LINES-1;
        variable line_aligned : std_logic_vector(24 downto 0);
        variable update_word  : std_logic_vector(31 downto 0);
        variable final_w0     : std_logic_vector(31 downto 0);
        variable final_w1     : std_logic_vector(31 downto 0);
        variable final_w2     : std_logic_vector(31 downto 0);
        variable final_w3     : std_logic_vector(31 downto 0);
    begin
        if rising_edge(I_clk) then
            if I_reset = '1' then
                state          <= S_IDLE;
                halfword_idx   <= '0';
                refill_cnt     <= 0;
                post_fill      <= '0';
                hit_count_reg  <= (others => '0');
                miss_count_reg <= (others => '0');
                pend_addr      <= (others => '0');
                pend_wdata     <= (others => '0');
                pend_be        <= (others => '0');
                pend_is_wr     <= '0';
                refill_buf     <= (others => '0');
                O_mem_rd_en    <= '0';
                O_mem_wr_en    <= '0';
                O_mem_addr     <= (others => '0');
                O_mem_wdata    <= (others => '0');
                O_mem_be       <= "00";
                for i in 0 to N_LINES-1 loop
                    cache_valid(i) <= '0';
                end loop;
            else
                -- Defaults
                O_mem_rd_en <= '0';
                O_mem_wr_en <= '0';

                -- Indice de la linea de la peticion actual.
                idx_int := to_integer(unsigned(pend_addr(INDEX_BITS+3 downto 4)));

                -- Direccion 25-bit aligned a la linea (8-halfword aligned).
                -- pend_addr en bytes; SDRAM addr en halfwords; bit[1]=0 alinea
                -- a halfword, bit[3:1]=0 alinea a linea de 16 bytes.
                line_aligned := pend_addr(25 downto 4) & "000";

                case state is
                    -- --------------------------------------------------------
                    when S_IDLE =>
                        if I_req = '1' then
                            pend_addr  <= I_addr;
                            pend_wdata <= I_wdata;
                            pend_be    <= I_be;
                            pend_is_wr <= I_we;
                            state      <= S_LOOKUP;
                        end if;

                    -- --------------------------------------------------------
                    when S_LOOKUP =>
                        if lookup_hit = '1' then
                            if post_fill = '0' then
                                hit_count_reg <= hit_count_reg + 1;
                            end if;
                            post_fill <= '0';
                            if pend_is_wr = '0' then
                                -- HIT-READ: el mux de cache_d_r ya tiene el
                                -- dato. Volvemos a IDLE.
                                state <= S_IDLE;
                            else
                                -- HIT-WRITE: actualizamos los bytes corres-
                                -- pondientes dentro de la palabra afectada y
                                -- arrancamos write-through. Solo escribimos
                                -- el BRAM correspondiente al word_sel.
                                case word_sel is
                                    when "00" =>
                                        update_word := cache_w0_r;
                                        for b in 0 to 3 loop
                                            if pend_be(b) = '1' then
                                                update_word(8*b + 7 downto 8*b) := pend_wdata(8*b + 7 downto 8*b);
                                            end if;
                                        end loop;
                                        cache_w0(idx_int) <= update_word;
                                    when "01" =>
                                        update_word := cache_w1_r;
                                        for b in 0 to 3 loop
                                            if pend_be(b) = '1' then
                                                update_word(8*b + 7 downto 8*b) := pend_wdata(8*b + 7 downto 8*b);
                                            end if;
                                        end loop;
                                        cache_w1(idx_int) <= update_word;
                                    when "10" =>
                                        update_word := cache_w2_r;
                                        for b in 0 to 3 loop
                                            if pend_be(b) = '1' then
                                                update_word(8*b + 7 downto 8*b) := pend_wdata(8*b + 7 downto 8*b);
                                            end if;
                                        end loop;
                                        cache_w2(idx_int) <= update_word;
                                    when others =>
                                        update_word := cache_w3_r;
                                        for b in 0 to 3 loop
                                            if pend_be(b) = '1' then
                                                update_word(8*b + 7 downto 8*b) := pend_wdata(8*b + 7 downto 8*b);
                                            end if;
                                        end loop;
                                        cache_w3(idx_int) <= update_word;
                                end case;
                                halfword_idx <= '0';
                                state        <= S_WR_REQ;
                            end if;
                        else
                            -- MISS
                            miss_count_reg <= miss_count_reg + 1;
                            halfword_idx   <= '0';
                            refill_cnt     <= 0;
                            if pend_is_wr = '0' then
                                state <= S_FILL_REQ;
                            else
                                state <= S_WR_REQ;
                            end if;
                        end if;

                    -- --------------------------------------------------------
                    -- Miss de lectura: lanzar burst de 8 halfwords al SDRAM
                    -- --------------------------------------------------------
                    when S_FILL_REQ =>
                        O_mem_addr   <= line_aligned;
                        O_mem_rd_en  <= '1';
                        O_mem_be     <= "11";
                        state        <= S_FILL_WAIT;

                    when S_FILL_WAIT =>
                        -- Mantener peticion estable hasta que el burst complete
                        O_mem_addr  <= line_aligned;
                        O_mem_rd_en <= '1';
                        O_mem_be    <= "11";

                        -- Cada I_mem_valid es un halfword del burst.
                        if I_mem_valid = '1' and refill_cnt < 8 then
                            refill_buf(refill_cnt*16 + 15 downto refill_cnt*16) <= I_mem_rdata;
                            refill_cnt <= refill_cnt + 1;
                        end if;

                        -- I_mem_done indica fin del burst entero.
                        if I_mem_done = '1' then
                            -- En el mismo ciclo viene el ultimo halfword en
                            -- I_mem_rdata (el valid pulsa simultaneamente).
                            -- Ensamblamos las 4 palabras de 32 bits desde los
                            -- 8 halfwords. Asumiendo refill_cnt = 7 (vamos a
                            -- recibir hw7 ahora), tenemos hw0..hw6 en
                            -- refill_buf y hw7 en I_mem_rdata.
                            final_w0 := refill_buf(31 downto 16) & refill_buf(15 downto 0);
                            final_w1 := refill_buf(63 downto 48) & refill_buf(47 downto 32);
                            final_w2 := refill_buf(95 downto 80) & refill_buf(79 downto 64);
                            -- Para w3 (bits 111..96 son hw6, 127..112 seria hw7):
                            if refill_cnt < 8 then
                                final_w3 := I_mem_rdata & refill_buf(111 downto 96);
                            else
                                final_w3 := refill_buf(127 downto 112) & refill_buf(111 downto 96);
                            end if;
                            cache_w0(idx_int)    <= final_w0;
                            cache_w1(idx_int)    <= final_w1;
                            cache_w2(idx_int)    <= final_w2;
                            cache_w3(idx_int)    <= final_w3;
                            cache_tag(idx_int)   <= pend_addr(31 downto INDEX_BITS+4);
                            cache_valid(idx_int) <= '1';
                            post_fill            <= '1';
                            state                <= S_IDLE;
                        end if;

                    -- --------------------------------------------------------
                    -- Write-through (SDRAM en modo single, 1 halfword por txn)
                    -- --------------------------------------------------------
                    when S_WR_REQ =>
                        O_mem_addr <= pend_addr(25 downto 2) & halfword_idx;

                        if halfword_idx = '0' then
                            if pend_be(1 downto 0) = "00" then
                                halfword_idx <= '1';
                            else
                                O_mem_wdata <= pend_wdata(15 downto 0);
                                O_mem_be    <= pend_be(1 downto 0);
                                O_mem_wr_en <= '1';
                                state       <= S_WR_WAIT;
                            end if;
                        else
                            if pend_be(3 downto 2) = "00" then
                                state <= S_RECOVERY;
                            else
                                O_mem_wdata <= pend_wdata(31 downto 16);
                                O_mem_be    <= pend_be(3 downto 2);
                                O_mem_wr_en <= '1';
                                state       <= S_WR_WAIT;
                            end if;
                        end if;

                    when S_WR_WAIT =>
                        -- Mantener peticion estable hasta I_mem_done.
                        O_mem_addr  <= pend_addr(25 downto 2) & halfword_idx;
                        O_mem_wr_en <= '1';
                        if halfword_idx = '0' then
                            O_mem_wdata <= pend_wdata(15 downto 0);
                            O_mem_be    <= pend_be(1 downto 0);
                        else
                            O_mem_wdata <= pend_wdata(31 downto 16);
                            O_mem_be    <= pend_be(3 downto 2);
                        end if;

                        if I_mem_done = '1' then
                            if halfword_idx = '0' then
                                halfword_idx <= '1';
                                state        <= S_WR_REQ;
                            else
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
