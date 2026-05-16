--------------------------------------------------------------------------------
-- alu.vhd
--
-- ALU combinacional de la CPU. Implementa todas las operaciones logicas,
-- aritmeticas y de comparacion de RV32I en un solo proceso, ademas de
-- exponer dos interfaces "start/done" hacia el multiplicador y el divisor
-- (RV32M), que tienen latencia plural y por tanto se manejan fuera de la
-- ruta combinacional.
--
-- Cuando la operacion solicitada es MUL/DIV/REM la ALU asserta el start
-- correspondiente y O_busy = '1' hasta que el resultado este disponible.
-- El control del pipeline usa O_busy para insertar burbujas.
--
-- Diseno aprovechando barrel shifter de la sintesis: las operaciones SLL,
-- SRL y SRA se modelan directamente con shift_left/shift_right sobre
-- vectores con/sin signo y Quartus genera un barrel shifter en LUTs.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

library work;
use work.riscv_pkg.all;

entity alu is
    port (
        I_clk    : in  std_logic;
        I_reset  : in  std_logic;
        -- entradas
        I_op     : in  std_logic_vector(4 downto 0);
        I_a      : in  word_t;
        I_b      : in  word_t;
        -- estado de ejecucion
        I_valid  : in  std_logic;   -- la instruccion EX es valida (no burbuja)
        -- salida
        O_result : out word_t;
        O_busy   : out std_logic    -- '1' mientras mul/div estan en curso
    );
end entity alu;

architecture Behavioral of alu is

    component multiplier is
        port (
            I_clk    : in  std_logic;
            I_reset  : in  std_logic;
            I_start  : in  std_logic;
            I_op     : in  std_logic_vector(4 downto 0);
            I_a      : in  word_t;
            I_b      : in  word_t;
            O_result : out word_t;
            O_done   : out std_logic
        );
    end component;

    component divider is
        port (
            I_clk    : in  std_logic;
            I_reset  : in  std_logic;
            I_start  : in  std_logic;
            I_op     : in  std_logic_vector(4 downto 0);
            I_a      : in  word_t;
            I_b      : in  word_t;
            O_result : out word_t;
            O_done   : out std_logic
        );
    end component;

    signal s_mul_start  : std_logic := '0';
    signal s_mul_done   : std_logic;
    signal s_mul_result : word_t;

    signal s_div_start  : std_logic := '0';
    signal s_div_done   : std_logic;
    signal s_div_result : word_t;

    signal s_int_result : word_t;       -- resultado de operaciones de 1 ciclo

    signal s_is_mul     : std_logic;
    signal s_is_div     : std_logic;

    signal a_s : signed(31 downto 0);
    signal b_s : signed(31 downto 0);
    signal a_u : unsigned(31 downto 0);
    signal b_u : unsigned(31 downto 0);

    -- cantidad de bits a desplazar (5 LSB del operando B)
    signal shamt : integer range 0 to 31;

begin

    mul_inst : multiplier port map (
        I_clk    => I_clk,
        I_reset  => I_reset,
        I_start  => s_mul_start,
        I_op     => I_op,
        I_a      => I_a,
        I_b      => I_b,
        O_result => s_mul_result,
        O_done   => s_mul_done
    );

    div_inst : divider port map (
        I_clk    => I_clk,
        I_reset  => I_reset,
        I_start  => s_div_start,
        I_op     => I_op,
        I_a      => I_a,
        I_b      => I_b,
        O_result => s_div_result,
        O_done   => s_div_done
    );

    -- Detectar tipo de operacion (bits altos del opcode interno)
    s_is_mul <= '1' when (I_op = ALU_MUL or I_op = ALU_MULH or
                          I_op = ALU_MULHSU or I_op = ALU_MULHU) else '0';
    s_is_div <= '1' when (I_op = ALU_DIV or I_op = ALU_DIVU or
                          I_op = ALU_REM or I_op = ALU_REMU) else '0';

    a_s   <= signed(I_a);
    b_s   <= signed(I_b);
    a_u   <= unsigned(I_a);
    b_u   <= unsigned(I_b);
    shamt <= to_integer(unsigned(I_b(4 downto 0)));

    ---------------------------------------------------------------------------
    -- Operaciones de un ciclo (combinacionales)
    ---------------------------------------------------------------------------
    int_proc : process (I_op, I_a, I_b, a_s, b_s, a_u, b_u, shamt)
    begin
        case I_op is
            when ALU_ADD    => s_int_result <= std_logic_vector(a_s + b_s);
            when ALU_SUB    => s_int_result <= std_logic_vector(a_s - b_s);
            when ALU_SLL    => s_int_result <= std_logic_vector(shift_left(a_u, shamt));
            when ALU_SRL    => s_int_result <= std_logic_vector(shift_right(a_u, shamt));
            when ALU_SRA    => s_int_result <= std_logic_vector(shift_right(a_s, shamt));
            when ALU_XOR    => s_int_result <= I_a xor I_b;
            when ALU_OR     => s_int_result <= I_a or  I_b;
            when ALU_AND    => s_int_result <= I_a and I_b;
            when ALU_SLT    =>
                if a_s < b_s then
                    s_int_result <= X"00000001";
                else
                    s_int_result <= X"00000000";
                end if;
            when ALU_SLTU   =>
                if a_u < b_u then
                    s_int_result <= X"00000001";
                else
                    s_int_result <= X"00000000";
                end if;
            when ALU_COPY_B => s_int_result <= I_b;
            when others     => s_int_result <= (others => '0');
        end case;
    end process;

    ---------------------------------------------------------------------------
    -- Control de start/done de las unidades multi-ciclo. Cuando el pipeline
    -- presenta una instruccion MUL/DIV valida levantamos el strobe; al ver
    -- O_done lo retiramos para que la unidad vuelva a IDLE.
    ---------------------------------------------------------------------------
    proc_long_ops : process (I_clk)
    begin
        if rising_edge(I_clk) then
            if I_reset = '1' then
                s_mul_start <= '0';
                s_div_start <= '0';
            else
                if I_valid = '1' and s_is_mul = '1' and s_mul_done = '0' then
                    s_mul_start <= '1';
                elsif s_mul_done = '1' then
                    s_mul_start <= '0';
                end if;

                if I_valid = '1' and s_is_div = '1' and s_div_done = '0' then
                    s_div_start <= '1';
                elsif s_div_done = '1' then
                    s_div_start <= '0';
                end if;
            end if;
        end if;
    end process;

    -- Mux de salida
    O_result <= s_mul_result when s_is_mul = '1' else
                s_div_result when s_is_div = '1' else
                s_int_result;

    -- O_busy = '1' mientras una unidad de varios ciclos esta en vuelo.
    -- Cuando done = '1' el resultado ya esta valido en el mux anterior y se
    -- libera al pipeline.
    O_busy <= '1' when (I_valid = '1' and s_is_mul = '1' and s_mul_done = '0') else
              '1' when (I_valid = '1' and s_is_div = '1' and s_div_done = '0') else
              '0';

end architecture Behavioral;
