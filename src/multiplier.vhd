--------------------------------------------------------------------------------
-- multiplier.vhd
--
-- Multiplicador 32x32 -> 64 bits con latencia de 2 ciclos. Cubre las
-- cuatro variantes RV32M (MUL, MULH, MULHSU, MULHU) usando UNA sola
-- multiplicacion signed de 33x33 -> 66 bits. La clave es elegir la
-- extension de cada operando segun la variante:
--
--   MUL    : sign-extend ambos                 -> usa bits  31:0 del prod
--   MULH   : sign-extend ambos                 -> usa bits 63:32
--   MULHU  : zero-extend ambos                 -> usa bits 63:32
--   MULHSU : sign-extend A, zero-extend B      -> usa bits 63:32
--
-- Esto reduce el consumo de DSP del MAX10 a 2-3 bloques (frente a 6-7 si
-- se mantienen tres multiplicaciones paralelas) y baja el tiempo de
-- analysis & synthesis al rango de minutos.
--
-- Protocolo:
--   1) El control sube I_start con I_op estable.
--   2) Tras 1 ciclo el resultado esta listo (state=DONE) y O_done='1'.
--   3) El control retira I_start; la unidad vuelve a IDLE.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

library work;
use work.riscv_pkg.all;

entity multiplier is
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
end entity multiplier;

architecture Behavioral of multiplier is

    type mul_state_t is (IDLE, COMPUTE, DONE_ST);
    signal state : mul_state_t := IDLE;

    -- Operandos extendidos a 33 bits segun la variante
    signal a_ext   : signed(32 downto 0);
    signal b_ext   : signed(32 downto 0);

    -- Producto y resultado de salida
    signal r_prod  : signed(65 downto 0) := (others => '0');
    signal r_op    : std_logic_vector(4 downto 0) := (others => '0');
    signal r_out   : word_t := (others => '0');

    -- Determina si cada operando se debe extender con signo o con cero
    -- en funcion de la variante de la instruccion.
    signal a_signed : std_logic;
    signal b_signed : std_logic;

begin

    -- A es signed para MUL, MULH y MULHSU; unsigned para MULHU.
    a_signed <= '0' when I_op = ALU_MULHU else '1';
    -- B es signed para MUL y MULH; unsigned para MULHSU y MULHU.
    b_signed <= '0' when (I_op = ALU_MULHU or I_op = ALU_MULHSU) else '1';

    a_ext <= signed((I_a(31) and a_signed) & I_a);
    b_ext <= signed((I_b(31) and b_signed) & I_b);

    proc : process (I_clk)
    begin
        if rising_edge(I_clk) then
            if I_reset = '1' then
                state <= IDLE;
                r_out <= (others => '0');
            else
                case state is
                    when IDLE =>
                        if I_start = '1' then
                            r_op   <= I_op;
                            r_prod <= a_ext * b_ext;
                            state  <= COMPUTE;
                        end if;
                    when COMPUTE =>
                        -- Selecciona la mitad correcta del producto
                        if r_op = ALU_MUL then
                            r_out <= std_logic_vector(r_prod(31 downto 0));
                        else
                            -- MULH, MULHU, MULHSU: parte alta
                            r_out <= std_logic_vector(r_prod(63 downto 32));
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

    O_result <= r_out;
    O_done   <= '1' when state = DONE_ST else '0';

end architecture Behavioral;
