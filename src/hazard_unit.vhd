--------------------------------------------------------------------------------
-- hazard_unit.vhd
--
-- Unidad central de control de hazards del pipeline. Realiza dos funciones:
--
--   1) FORWARDING: decide si los operandos en EX deben tomarse del banco
--      o de los registros EX/MEM (resultado de la instruccion que esta
--      en MEM) o MEM/WB (resultado todavia no escrito de la que esta en
--      WB). Para esta decision se comparan los rs1/rs2 de la instruccion
--      ACTUALMENTE en EX (es decir, id_ex.rs1/rs2) con los rd registrados
--      en cada etapa siguiente.
--
--   2) STALL & FLUSH: hazards de control de flujo:
--
--      a) Load-use (load en EX, instruccion en ID que usa rd del load):
--          freeze PC, freeze IF/ID, bubble ID/EX. Una sola burbuja basta;
--          al siguiente ciclo el load esta en MEM/WB y el forwarding lo
--          resuelve. Para detectar esto comparamos id_rs1/id_rs2 (del
--          decoder, instruccion en ID) con id_ex.rd (instruccion en EX).
--
--      b) Multiciclo (mul/div): la instruccion debe permanecer en EX
--          varios ciclos. Hay que:
--             - freeze PC, freeze IF/ID  (el frontend no avanza)
--             - freeze ID/EX             (la instr no sale de EX)
--             - bubble EX/MEM            (downstream recibe NOPs)
--          Cuando termine (O_busy=0), todo se libera.
--
--      c) Branch tomado / trampa: flushear IF e ID (2 burbujas).
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

library work;
use work.riscv_pkg.all;

entity hazard_unit is
    port (
        -- Para load-use detection (instruccion en ID)
        I_id_rs1    : in  std_logic_vector(4 downto 0);
        I_id_rs2    : in  std_logic_vector(4 downto 0);

        -- Para forwarding (instruccion en EX)
        I_ex_rs1    : in  std_logic_vector(4 downto 0);
        I_ex_rs2    : in  std_logic_vector(4 downto 0);

        -- Estado de las etapas posteriores
        I_ex_rd     : in  std_logic_vector(4 downto 0);
        I_ex_reg_we : in  std_logic;
        I_ex_mem_re : in  std_logic;  -- la EX actual es un load

        I_mem_rd    : in  std_logic_vector(4 downto 0);
        I_mem_reg_we: in  std_logic;
        I_wb_rd     : in  std_logic_vector(4 downto 0);
        I_wb_reg_we : in  std_logic;

        I_alu_busy    : in std_logic;
        I_dmem_busy   : in std_logic;
        I_branch_take : in std_logic;
        I_trap        : in std_logic;

        -- Salidas: forwarding y control de pipeline
        O_fwd_a       : out std_logic_vector(1 downto 0);
        O_fwd_b       : out std_logic_vector(1 downto 0);

        O_stall_pc    : out std_logic;
        O_stall_if_id : out std_logic;
        O_stall_id_ex : out std_logic;
        O_stall_ex_mem: out std_logic;
        O_stall_mem_wb: out std_logic;
        O_bubble_id_ex: out std_logic;
        O_bubble_ex_mem: out std_logic;
        O_flush_if    : out std_logic;
        O_flush_id    : out std_logic
    );
end entity hazard_unit;

architecture Behavioral of hazard_unit is

    signal s_load_use : std_logic;

begin

    ---------------------------------------------------------------------------
    -- Forwarding: la instruccion en EX (rs1/rs2 = I_ex_rs1/rs2) puede tomar
    -- su operando de:
    --   * EX/MEM (resultado de la instruccion una posicion por delante)
    --   * MEM/WB (resultado de dos posiciones por delante, todavia no
    --     escrito en el banco)
    -- EX/MEM tiene prioridad (mas reciente). x0 nunca se forwarda.
    ---------------------------------------------------------------------------
    O_fwd_a <= FWD_EX_MEM when (I_mem_reg_we = '1' and I_mem_rd /= "00000" and
                                  I_mem_rd = I_ex_rs1) else
               FWD_MEM_WB when (I_wb_reg_we = '1' and I_wb_rd /= "00000" and
                                  I_wb_rd = I_ex_rs1) else
               FWD_REG;

    O_fwd_b <= FWD_EX_MEM when (I_mem_reg_we = '1' and I_mem_rd /= "00000" and
                                  I_mem_rd = I_ex_rs2) else
               FWD_MEM_WB when (I_wb_reg_we = '1' and I_wb_rd /= "00000" and
                                  I_wb_rd = I_ex_rs2) else
               FWD_REG;

    ---------------------------------------------------------------------------
    -- Deteccion de load-use hazard: el load en EX produce rd que el
    -- decoder de ID acaba de leer como rs1 o rs2.
    ---------------------------------------------------------------------------
    s_load_use <= '1' when (I_ex_mem_re = '1' and I_ex_rd /= "00000" and
                              (I_ex_rd = I_id_rs1 or I_ex_rd = I_id_rs2)) else '0';

    ---------------------------------------------------------------------------
    -- Control de paradas (STALL) y burbujas (BUBBLE)
    ---------------------------------------------------------------------------
    O_stall_pc    <= I_alu_busy or s_load_use or I_dmem_busy;
    O_stall_if_id <= I_alu_busy or s_load_use or I_dmem_busy;
    O_stall_id_ex <= I_alu_busy or I_dmem_busy;
    O_stall_ex_mem<= I_dmem_busy;
    O_stall_mem_wb<= I_dmem_busy;

    O_bubble_id_ex  <= s_load_use and (not I_alu_busy) and (not I_dmem_busy);
    O_bubble_ex_mem <= I_alu_busy and (not I_dmem_busy);
    O_flush_if <= I_branch_take or I_trap;
    O_flush_id <= I_branch_take or I_trap;

end architecture Behavioral;
