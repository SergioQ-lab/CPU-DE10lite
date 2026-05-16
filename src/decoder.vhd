--------------------------------------------------------------------------------
-- decoder.vhd
--
-- Decodificador de instrucciones RV32IM. Es totalmente combinacional:
-- recibe la instruccion de 32 bits leida en la etapa IF y produce
-- todas las senales de control para el resto del pipeline:
--
--   * selectores de registros (rs1, rs2, rd)
--   * inmediato extendido en signo segun el formato (I, S, B, U, J)
--   * operacion de la ALU
--   * fuente de los operandos A y B
--   * fuente del valor a escribir en el banco
--   * tipo de transferencia de memoria + write-enable
--   * habilitacion del escritura en banco
--   * indicadores de salto/branch
--   * informacion para la unidad CSR
--   * deteccion de instruccion ilegal
--
-- La instruccion x0=ADDI x0, x0, 0 codifica un NOP. Cuando el pipeline
-- inyecta burbujas (por hazard) presenta la palabra X"00000013" como
-- instruccion, por lo que el decodificador automaticamente genera un
-- NOP sin escrituras ni efectos laterales.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

library work;
use work.riscv_pkg.all;

entity decoder is
    port (
        I_instr   : in  word_t;                       -- instruccion completa
        -- selectores de registros
        O_rs1     : out std_logic_vector(4 downto 0);
        O_rs2     : out std_logic_vector(4 downto 0);
        O_rd      : out std_logic_vector(4 downto 0);
        -- inmediato y opcode interno
        O_imm     : out word_t;
        O_alu_op  : out std_logic_vector(4 downto 0);
        O_a_src   : out std_logic_vector(1 downto 0);
        O_b_src   : out std_logic;
        O_wb_src  : out std_logic_vector(1 downto 0);
        O_reg_we  : out std_logic;
        -- memoria
        O_mem_re  : out std_logic;                    -- load
        O_mem_we  : out std_logic;                    -- store
        O_mem_op  : out std_logic_vector(2 downto 0); -- ancho + signo
        -- saltos
        O_is_branch : out std_logic;
        O_is_jal    : out std_logic;
        O_is_jalr   : out std_logic;
        O_br_func   : out std_logic_vector(2 downto 0); -- funct3 del branch
        -- CSR / sistema
        O_csr_op   : out std_logic_vector(1 downto 0);
        O_csr_addr : out std_logic_vector(11 downto 0);
        O_csr_imm  : out std_logic; -- '1' si la fuente es uimm
        O_is_ecall  : out std_logic;
        O_is_ebreak : out std_logic;
        O_is_mret   : out std_logic;
        -- mul/div utiliza la propia ALU pero el hazard unit lo necesita
        O_is_mul   : out std_logic;
        O_is_div   : out std_logic;
        -- excepcion sincrona
        O_illegal  : out std_logic
    );
end entity decoder;

architecture Behavioral of decoder is

    -- Campos directos del formato R/I/S/B/U/J
    signal opcode  : std_logic_vector(4 downto 0);
    signal funct3  : std_logic_vector(2 downto 0);
    signal funct7  : std_logic_vector(6 downto 0);
    signal rs1_s   : std_logic_vector(4 downto 0);
    signal rs2_s   : std_logic_vector(4 downto 0);
    signal rd_s    : std_logic_vector(4 downto 0);

    -- Inmediatos por formato
    signal imm_i : word_t;
    signal imm_s : word_t;
    signal imm_b : word_t;
    signal imm_u : word_t;
    signal imm_j : word_t;

begin

    -- Extraccion de campos. Los bits [1:0] de opcode estan siempre a "11"
    -- para instrucciones RV32 de 32 bits validas, asi que se ignoran y
    -- guardamos solo [6:2].
    opcode <= I_instr(6 downto 2);
    funct3 <= I_instr(14 downto 12);
    funct7 <= I_instr(31 downto 25);
    rd_s   <= I_instr(11 downto  7);
    rs1_s  <= I_instr(19 downto 15);
    rs2_s  <= I_instr(24 downto 20);

    O_rs1 <= rs1_s;
    O_rs2 <= rs2_s;
    O_rd  <= rd_s;

    ---------------------------------------------------------------------------
    -- Inmediatos extendidos en signo. La sintaxis es la del manual RISC-V
    -- (figura 2.4): cada formato toma un subconjunto distinto de los bits
    -- de la instruccion y los reordena.
    ---------------------------------------------------------------------------
    imm_i <= (31 downto 11 => I_instr(31)) & I_instr(30 downto 20);
    imm_s <= (31 downto 11 => I_instr(31)) & I_instr(30 downto 25) & I_instr(11 downto 7);
    imm_b <= (31 downto 12 => I_instr(31)) & I_instr(7)
             & I_instr(30 downto 25) & I_instr(11 downto 8) & '0';
    imm_u <= I_instr(31 downto 12) & X"000";
    imm_j <= (31 downto 20 => I_instr(31)) & I_instr(19 downto 12)
             & I_instr(20) & I_instr(30 downto 21) & '0';

    ---------------------------------------------------------------------------
    -- Logica combinacional principal
    ---------------------------------------------------------------------------
    decode_proc : process (opcode, funct3, funct7, rs1_s, rs2_s, rd_s,
                            imm_i, imm_s, imm_b, imm_u, imm_j, I_instr)
        variable v_alu : std_logic_vector(4 downto 0);
    begin
        -- valores por defecto = NOP / sin efectos laterales
        O_imm       <= (others => '0');
        O_alu_op    <= ALU_ADD;
        O_a_src     <= ASRC_RS1;
        O_b_src     <= BSRC_RS2;
        O_wb_src    <= WBSRC_ALU;
        O_reg_we    <= '0';
        O_mem_re    <= '0';
        O_mem_we    <= '0';
        O_mem_op    <= MEM_W;
        O_is_branch <= '0';
        O_is_jal    <= '0';
        O_is_jalr   <= '0';
        O_br_func   <= funct3;
        O_csr_op    <= CSROP_NONE;
        O_csr_addr  <= I_instr(31 downto 20);
        O_csr_imm   <= '0';
        O_is_ecall  <= '0';
        O_is_ebreak <= '0';
        O_is_mret   <= '0';
        O_is_mul    <= '0';
        O_is_div    <= '0';
        O_illegal   <= '0';

        case opcode is

            when OP_LUI =>
                -- rd <- imm_u (alu_b = imm_u, alu_a = 0 con COPY_B)
                O_imm    <= imm_u;
                O_alu_op <= ALU_COPY_B;
                O_a_src  <= ASRC_ZERO;
                O_b_src  <= BSRC_IMM;
                O_reg_we <= '1';

            when OP_AUIPC =>
                -- rd <- PC + imm_u
                O_imm    <= imm_u;
                O_alu_op <= ALU_ADD;
                O_a_src  <= ASRC_PC;
                O_b_src  <= BSRC_IMM;
                O_reg_we <= '1';

            when OP_JAL =>
                O_imm    <= imm_j;
                O_a_src  <= ASRC_PC;
                O_b_src  <= BSRC_IMM;
                O_alu_op <= ALU_ADD;     -- target = PC + imm_j
                O_wb_src <= WBSRC_PC4;
                O_reg_we <= '1';
                O_is_jal <= '1';

            when OP_JALR =>
                O_imm     <= imm_i;
                O_a_src   <= ASRC_RS1;
                O_b_src   <= BSRC_IMM;
                O_alu_op  <= ALU_ADD;     -- target = rs1 + imm_i (lsb se limpia en branch_unit)
                O_wb_src  <= WBSRC_PC4;
                O_reg_we  <= '1';
                O_is_jalr <= '1';

            when OP_BRANCH =>
                O_imm       <= imm_b;
                O_a_src     <= ASRC_PC;
                O_b_src     <= BSRC_IMM;
                O_alu_op    <= ALU_ADD;   -- target = PC + imm_b
                O_is_branch <= '1';
                O_br_func   <= funct3;

            when OP_LOAD =>
                O_imm    <= imm_i;
                O_a_src  <= ASRC_RS1;
                O_b_src  <= BSRC_IMM;
                O_alu_op <= ALU_ADD;
                O_wb_src <= WBSRC_MEM;
                O_reg_we <= '1';
                O_mem_re <= '1';
                O_mem_op <= funct3;
                if funct3 = "011" or funct3 = "110" or funct3 = "111" then
                    O_illegal <= '1';
                end if;

            when OP_STORE =>
                O_imm    <= imm_s;
                O_a_src  <= ASRC_RS1;
                O_b_src  <= BSRC_IMM;
                O_alu_op <= ALU_ADD;
                O_mem_we <= '1';
                O_mem_op <= funct3;
                if funct3(2) = '1' or funct3 = "011" then
                    O_illegal <= '1';
                end if;

            when OP_OPIMM =>
                O_imm    <= imm_i;
                O_a_src  <= ASRC_RS1;
                O_b_src  <= BSRC_IMM;
                O_reg_we <= '1';
                case funct3 is
                    when F3_ADD_SUB => v_alu := ALU_ADD;
                    when F3_SLT     => v_alu := ALU_SLT;
                    when F3_SLTU    => v_alu := ALU_SLTU;
                    when F3_XOR     => v_alu := ALU_XOR;
                    when F3_OR      => v_alu := ALU_OR;
                    when F3_AND     => v_alu := ALU_AND;
                    when F3_SLL     =>
                        v_alu := ALU_SLL;
                        if funct7 /= F7_DEFAULT then
                            O_illegal <= '1';
                        end if;
                    when F3_SRL_SRA =>
                        if funct7 = F7_DEFAULT then
                            v_alu := ALU_SRL;
                        elsif funct7 = F7_ALT then
                            v_alu := ALU_SRA;
                        else
                            v_alu := ALU_SRL;
                            O_illegal <= '1';
                        end if;
                    when others =>
                        v_alu := ALU_ADD;
                        O_illegal <= '1';
                end case;
                O_alu_op <= v_alu;

            when OP_OP =>
                O_a_src  <= ASRC_RS1;
                O_b_src  <= BSRC_RS2;
                O_reg_we <= '1';
                if funct7 = F7_MEXT then
                    -- Extension M (mul/div/rem)
                    case funct3 is
                        when F3_MUL    => v_alu := ALU_MUL;    O_is_mul <= '1';
                        when F3_MULH   => v_alu := ALU_MULH;   O_is_mul <= '1';
                        when F3_MULHSU => v_alu := ALU_MULHSU; O_is_mul <= '1';
                        when F3_MULHU  => v_alu := ALU_MULHU;  O_is_mul <= '1';
                        when F3_DIV    => v_alu := ALU_DIV;    O_is_div <= '1';
                        when F3_DIVU   => v_alu := ALU_DIVU;   O_is_div <= '1';
                        when F3_REM    => v_alu := ALU_REM;    O_is_div <= '1';
                        when F3_REMU   => v_alu := ALU_REMU;   O_is_div <= '1';
                        when others    => v_alu := ALU_ADD;    O_illegal <= '1';
                    end case;
                else
                    case funct3 is
                        when F3_ADD_SUB =>
                            if funct7 = F7_ALT then
                                v_alu := ALU_SUB;
                            else
                                v_alu := ALU_ADD;
                            end if;
                        when F3_SLL  => v_alu := ALU_SLL;
                        when F3_SLT  => v_alu := ALU_SLT;
                        when F3_SLTU => v_alu := ALU_SLTU;
                        when F3_XOR  => v_alu := ALU_XOR;
                        when F3_SRL_SRA =>
                            if funct7 = F7_ALT then
                                v_alu := ALU_SRA;
                            else
                                v_alu := ALU_SRL;
                            end if;
                        when F3_OR   => v_alu := ALU_OR;
                        when F3_AND  => v_alu := ALU_AND;
                        when others  => v_alu := ALU_ADD; O_illegal <= '1';
                    end case;
                end if;
                O_alu_op <= v_alu;

            when OP_MISCMEM =>
                -- FENCE / FENCE.I: tratados como NOP en esta micro-arquitectura
                -- ya que el pipeline mantiene orden estricto y no hay caches.
                null;

            when OP_SYSTEM =>
                O_csr_addr <= I_instr(31 downto 20);
                if funct3 = F3_PRIV then
                    -- ECALL, EBREAK, MRET
                    if I_instr(31 downto 20) = X"000" then
                        O_is_ecall <= '1';
                    elsif I_instr(31 downto 20) = X"001" then
                        O_is_ebreak <= '1';
                    elsif I_instr(31 downto 20) = X"302" then
                        O_is_mret <= '1';
                    else
                        O_illegal <= '1';
                    end if;
                else
                    -- CSR access: rd = CSR, CSR <- op(CSR, src)
                    O_a_src   <= ASRC_RS1;
                    O_b_src   <= BSRC_RS2;
                    O_wb_src  <= WBSRC_CSR;
                    O_reg_we  <= '1';
                    case funct3 is
                        when F3_CSRRW  => O_csr_op <= CSROP_RW;
                        when F3_CSRRS  => O_csr_op <= CSROP_RS;
                        when F3_CSRRC  => O_csr_op <= CSROP_RC;
                        when F3_CSRRWI => O_csr_op <= CSROP_RW; O_csr_imm <= '1';
                        when F3_CSRRSI => O_csr_op <= CSROP_RS; O_csr_imm <= '1';
                        when F3_CSRRCI => O_csr_op <= CSROP_RC; O_csr_imm <= '1';
                        when others    => O_illegal <= '1';
                    end case;
                end if;

            when others =>
                O_illegal <= '1';
        end case;
    end process;

end architecture Behavioral;
