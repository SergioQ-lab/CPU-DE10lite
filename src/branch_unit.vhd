--------------------------------------------------------------------------------
-- branch_unit.vhd
--
-- Evaluador de saltos. Recibe los dos operandos (ya forwardeados) de la
-- etapa EX y el tipo de operacion de salto, y decide:
--
--   * si el salto se debe tomar  -> O_take
--   * cual es el PC destino       -> O_target
--
-- Soporta los seis branches RV32I (BEQ, BNE, BLT, BGE, BLTU, BGEU), JAL y
-- JALR. Para JALR aplica el enmascarado del LSB exigido por el estandar.
--
-- Como las comparaciones se hacen aqui, la deteccion de saltos tomados
-- ocurre al final de EX. Eso obliga a flushar las dos instrucciones que
-- en ese momento estan en IF/ID, lo cual cuesta 2 ciclos de penalty por
-- salto tomado. Mantenemos prediccion estatica "not taken".
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

library work;
use work.riscv_pkg.all;

entity branch_unit is
    port (
        I_is_branch : in  std_logic;
        I_is_jal    : in  std_logic;
        I_is_jalr   : in  std_logic;
        I_br_func   : in  std_logic_vector(2 downto 0); -- funct3 del branch
        I_a         : in  word_t;     -- rs1 (con forwarding)
        I_b         : in  word_t;     -- rs2 (con forwarding)
        I_alu_res   : in  word_t;     -- resultado de la ALU = PC+imm o rs1+imm
        O_take      : out std_logic;
        O_target    : out word_t
    );
end entity branch_unit;

architecture Behavioral of branch_unit is

    signal s_cmp : std_logic;

begin

    ---------------------------------------------------------------------------
    -- Comparador combinacional segun funct3. Dentro de un proceso (sentencias
    -- secuenciales) hay que usar if/else; la sintaxis "x <= ... when ... else"
    -- es concurrente y no se permite aqui.
    ---------------------------------------------------------------------------
    cmp_proc : process (I_br_func, I_a, I_b)
    begin
        case I_br_func is
            when F3_BEQ  =>
                if I_a = I_b then
                    s_cmp <= '1';
                else
                    s_cmp <= '0';
                end if;
            when F3_BNE  =>
                if I_a /= I_b then
                    s_cmp <= '1';
                else
                    s_cmp <= '0';
                end if;
            when F3_BLT  =>
                if signed(I_a) < signed(I_b) then
                    s_cmp <= '1';
                else
                    s_cmp <= '0';
                end if;
            when F3_BGE  =>
                if signed(I_a) >= signed(I_b) then
                    s_cmp <= '1';
                else
                    s_cmp <= '0';
                end if;
            when F3_BLTU =>
                if unsigned(I_a) < unsigned(I_b) then
                    s_cmp <= '1';
                else
                    s_cmp <= '0';
                end if;
            when F3_BGEU =>
                if unsigned(I_a) >= unsigned(I_b) then
                    s_cmp <= '1';
                else
                    s_cmp <= '0';
                end if;
            when others  =>
                s_cmp <= '0';
        end case;
    end process;

    -- Toma del salto: JAL siempre, JALR siempre, branches segun comparador
    O_take <= I_is_jal or I_is_jalr or (I_is_branch and s_cmp);

    -- PC destino: la ALU ya calculo PC+imm o rs1+imm. Para JALR forzamos
    -- LSB a 0 segun la spec.
    O_target <= (I_alu_res(31 downto 1) & '0') when I_is_jalr = '1' else I_alu_res;

end architecture Behavioral;
