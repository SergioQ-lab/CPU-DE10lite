--------------------------------------------------------------------------------
-- divider.vhd
--
-- Division/resto entero de 32 bits implementado como un algoritmo de
-- restoring por shift-and-subtract. Latencia tipica = 34 ciclos (1 ciclo
-- de captura + 32 iteraciones + 1 ciclo de ajuste de signo).
--
-- Soporta las cuatro variantes RV32M: DIV, DIVU, REM, REMU. Para las
-- operaciones con signo se opera internamente en valor absoluto y se
-- aplica el signo al final.
--
-- Comportamiento ante divisiones especiales del estandar RV32M:
--   * division por cero            -> cociente = -1 (0xFFFFFFFF),
--                                     resto    = dividendo
--   * overflow con signo (INT_MIN / -1) -> cociente = INT_MIN, resto = 0
--
-- Protocolo: el control_unit asserta I_start con la operacion y los
-- operandos. La unidad responde con O_done cuando el resultado esta
-- listo y permanece ahi hasta que se retira I_start.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

library work;
use work.riscv_pkg.all;

entity divider is
    port (
        I_clk    : in  std_logic;
        I_reset  : in  std_logic;
        I_start  : in  std_logic;
        I_op     : in  std_logic_vector(4 downto 0); -- ALU_DIV/DIVU/REM/REMU
        I_a      : in  word_t;                       -- dividendo
        I_b      : in  word_t;                       -- divisor
        O_result : out word_t;
        O_done   : out std_logic
    );
end entity divider;

architecture Behavioral of divider is

    type state_t is (IDLE, ITER, FIXUP, DONE_ST);
    signal state : state_t := IDLE;

    -- Operandos originales latcheados (para casos especiales). r_a
    -- guarda el dividendo para devolverlo como resto en div-por-cero.
    -- (r_b no es necesario porque el divisor ya esta capturado en
    -- r_dvs como valor absoluto).
    signal r_op   : std_logic_vector(4 downto 0) := (others => '0');
    signal r_a    : word_t := (others => '0');

    -- Estado del algoritmo
    signal r_count    : integer range 0 to 32 := 0;
    signal r_q        : unsigned(31 downto 0) := (others => '0');
    signal r_rem      : unsigned(31 downto 0) := (others => '0');
    signal r_dvd      : unsigned(31 downto 0) := (others => '0');
    signal r_dvs      : unsigned(31 downto 0) := (others => '0');

    signal r_neg_q    : std_logic := '0';
    signal r_neg_r    : std_logic := '0';
    signal r_div_by_0 : std_logic := '0';
    signal r_overflow : std_logic := '0';

    signal r_result   : word_t := (others => '0');

    function is_signed_op(op : std_logic_vector(4 downto 0)) return boolean is
    begin
        return (op = ALU_DIV) or (op = ALU_REM);
    end function;

    function is_rem_op(op : std_logic_vector(4 downto 0)) return boolean is
    begin
        return (op = ALU_REM) or (op = ALU_REMU);
    end function;

begin

    proc : process (I_clk)
        variable v_shift : unsigned(32 downto 0); -- {rem,bit alto del dvd} para comparar
        variable v_aabs  : unsigned(31 downto 0);
        variable v_babs  : unsigned(31 downto 0);
    begin
        if rising_edge(I_clk) then
            if I_reset = '1' then
                state    <= IDLE;
                r_result <= (others => '0');
            else
                case state is
                    when IDLE =>
                        if I_start = '1' then
                            -- Latch operandos
                            r_op <= I_op;
                            r_a  <= I_a;

                            -- Calcular valores absolutos si es operacion con signo
                            if is_signed_op(I_op) and I_a(31) = '1' then
                                v_aabs := unsigned(std_logic_vector(0 - signed(I_a)));
                            else
                                v_aabs := unsigned(I_a);
                            end if;
                            if is_signed_op(I_op) and I_b(31) = '1' then
                                v_babs := unsigned(std_logic_vector(0 - signed(I_b)));
                            else
                                v_babs := unsigned(I_b);
                            end if;

                            r_dvd <= v_aabs;
                            r_dvs <= v_babs;

                            if is_signed_op(I_op) then
                                r_neg_q <= I_a(31) xor I_b(31);
                                r_neg_r <= I_a(31);
                            else
                                r_neg_q <= '0';
                                r_neg_r <= '0';
                            end if;

                            -- Casos especiales del estandar
                            if unsigned(I_b) = 0 then
                                r_div_by_0 <= '1';
                            else
                                r_div_by_0 <= '0';
                            end if;
                            if is_signed_op(I_op) and I_a = X"80000000" and I_b = X"FFFFFFFF" then
                                r_overflow <= '1';
                            else
                                r_overflow <= '0';
                            end if;

                            r_q     <= (others => '0');
                            r_rem   <= (others => '0');
                            r_count <= 32;
                            state   <= ITER;
                        end if;

                    when ITER =>
                        -- En caso especial saltamos directamente al fixup
                        if r_div_by_0 = '1' or r_overflow = '1' then
                            state <= FIXUP;
                        else
                            -- Iteracion restoring:
                            -- desplazamos {rem, dvd} a la izquierda y comparamos
                            -- con el divisor.
                            v_shift := r_rem(30 downto 0) & r_dvd(31) & '0';
                            -- (33 bits: r_rem(30..0) & dvd(31) -> 32 bits, luego &'0' produce 33)
                            -- arriba el LSB '0' es un placeholder que cae fuera; mejor:
                            v_shift := '0' & (r_rem(30 downto 0) & r_dvd(31));
                            if v_shift >= ('0' & r_dvs) then
                                r_rem <= resize(v_shift - ('0' & r_dvs), 32);
                                r_q   <= r_q(30 downto 0) & '1';
                            else
                                r_rem <= resize(v_shift, 32);
                                r_q   <= r_q(30 downto 0) & '0';
                            end if;
                            r_dvd <= r_dvd(30 downto 0) & '0';

                            if r_count = 1 then
                                state <= FIXUP;
                            end if;
                            r_count <= r_count - 1;
                        end if;

                    when FIXUP =>
                        if r_div_by_0 = '1' then
                            if is_rem_op(r_op) then
                                r_result <= r_a;
                            else
                                r_result <= (others => '1');
                            end if;
                        elsif r_overflow = '1' then
                            if is_rem_op(r_op) then
                                r_result <= (others => '0');
                            else
                                r_result <= X"80000000";
                            end if;
                        else
                            if is_rem_op(r_op) then
                                if r_neg_r = '1' then
                                    r_result <= std_logic_vector(0 - signed(r_rem));
                                else
                                    r_result <= std_logic_vector(r_rem);
                                end if;
                            else
                                if r_neg_q = '1' then
                                    r_result <= std_logic_vector(0 - signed(r_q));
                                else
                                    r_result <= std_logic_vector(r_q);
                                end if;
                            end if;
                        end if;
                        state <= DONE_ST;

                    when DONE_ST =>
                        if I_start = '0' then
                            state <= IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

    O_result <= r_result;
    O_done   <= '1' when state = DONE_ST else '0';

end architecture Behavioral;
