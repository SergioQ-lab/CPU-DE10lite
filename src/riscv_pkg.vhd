--------------------------------------------------------------------------------
-- riscv_pkg.vhd
--
-- Paquete central del SoC RISC-V. Concentra el ancho de palabra (XLEN=32),
-- la codificacion de la ISA RV32IM (opcodes, funct3, funct7), los modos
-- de acceso a memoria, los selectores internos del datapath (ALU, fuentes
-- de operandos, fuentes de PC, etc.) y los identificadores de las
-- excepciones soportadas. Los constantes estan agrupados por familia para
-- facilitar su mantenimiento.
--
-- Cualquier modulo del SoC puede referenciarlo con:
--      library work;
--      use work.riscv_pkg.all;
--
-- El uso de "use work.<pkg>.all" es legal y necesario para importar tipos,
-- y NO contradice la pauta del usuario de instanciar los sub-modulos como
-- componentes (esa regla aplica a entity instantiation, no a packages).
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;

package riscv_pkg is

    ---------------------------------------------------------------------------
    -- Ancho de palabra y vector base de la CPU
    ---------------------------------------------------------------------------
    constant XLEN   : integer := 32;
    constant XLENM1 : integer := XLEN - 1;
    subtype word_t is std_logic_vector(XLENM1 downto 0);

    -- Direccion de arranque del PC despues de reset
    constant ADDR_RESET   : word_t := X"00000000";
    -- Direccion del vector de interrupciones (mtvec por defecto)
    constant ADDR_TRAPVEC : word_t := X"00000004";

    ---------------------------------------------------------------------------
    -- Opcodes RV32 (campo opcode[6:0], pero todos los validos terminan en 11
    -- asi que aqui se almacenan solo los bits [6:2] como en el RPU).
    ---------------------------------------------------------------------------
    constant OP_LOAD    : std_logic_vector(4 downto 0) := "00000";
    constant OP_MISCMEM : std_logic_vector(4 downto 0) := "00011";
    constant OP_OPIMM   : std_logic_vector(4 downto 0) := "00100";
    constant OP_AUIPC   : std_logic_vector(4 downto 0) := "00101";
    constant OP_STORE   : std_logic_vector(4 downto 0) := "01000";
    constant OP_OP      : std_logic_vector(4 downto 0) := "01100";
    constant OP_LUI     : std_logic_vector(4 downto 0) := "01101";
    constant OP_BRANCH  : std_logic_vector(4 downto 0) := "11000";
    constant OP_JALR    : std_logic_vector(4 downto 0) := "11001";
    constant OP_JAL     : std_logic_vector(4 downto 0) := "11011";
    constant OP_SYSTEM  : std_logic_vector(4 downto 0) := "11100";

    ---------------------------------------------------------------------------
    -- funct3 (campo bits [14:12]) para cada familia de instrucciones
    ---------------------------------------------------------------------------
    -- Branches
    constant F3_BEQ  : std_logic_vector(2 downto 0) := "000";
    constant F3_BNE  : std_logic_vector(2 downto 0) := "001";
    constant F3_BLT  : std_logic_vector(2 downto 0) := "100";
    constant F3_BGE  : std_logic_vector(2 downto 0) := "101";
    constant F3_BLTU : std_logic_vector(2 downto 0) := "110";
    constant F3_BGEU : std_logic_vector(2 downto 0) := "111";

    -- Loads (byte/half/word, con/sin signo)
    constant F3_LB  : std_logic_vector(2 downto 0) := "000";
    constant F3_LH  : std_logic_vector(2 downto 0) := "001";
    constant F3_LW  : std_logic_vector(2 downto 0) := "010";
    constant F3_LBU : std_logic_vector(2 downto 0) := "100";
    constant F3_LHU : std_logic_vector(2 downto 0) := "101";

    -- Stores
    constant F3_SB : std_logic_vector(2 downto 0) := "000";
    constant F3_SH : std_logic_vector(2 downto 0) := "001";
    constant F3_SW : std_logic_vector(2 downto 0) := "010";

    -- ALU OP / OPIMM (mismos funct3, pero funct7 distingue ADD/SUB y SRL/SRA)
    constant F3_ADD_SUB : std_logic_vector(2 downto 0) := "000";
    constant F3_SLL     : std_logic_vector(2 downto 0) := "001";
    constant F3_SLT     : std_logic_vector(2 downto 0) := "010";
    constant F3_SLTU    : std_logic_vector(2 downto 0) := "011";
    constant F3_XOR     : std_logic_vector(2 downto 0) := "100";
    constant F3_SRL_SRA : std_logic_vector(2 downto 0) := "101";
    constant F3_OR      : std_logic_vector(2 downto 0) := "110";
    constant F3_AND     : std_logic_vector(2 downto 0) := "111";

    -- Sistema (CSR + ECALL/EBREAK + privilegio)
    constant F3_PRIV   : std_logic_vector(2 downto 0) := "000";
    constant F3_CSRRW  : std_logic_vector(2 downto 0) := "001";
    constant F3_CSRRS  : std_logic_vector(2 downto 0) := "010";
    constant F3_CSRRC  : std_logic_vector(2 downto 0) := "011";
    constant F3_CSRRWI : std_logic_vector(2 downto 0) := "101";
    constant F3_CSRRSI : std_logic_vector(2 downto 0) := "110";
    constant F3_CSRRCI : std_logic_vector(2 downto 0) := "111";

    ---------------------------------------------------------------------------
    -- funct7 (campo bits [31:25]) - solo los valores relevantes
    ---------------------------------------------------------------------------
    constant F7_DEFAULT : std_logic_vector(6 downto 0) := "0000000"; -- ADD, SRL, SLL...
    constant F7_ALT     : std_logic_vector(6 downto 0) := "0100000"; -- SUB, SRA
    constant F7_MEXT    : std_logic_vector(6 downto 0) := "0000001"; -- MUL/DIV/REM (RV32M)

    -- funct3 para la extension M
    constant F3_MUL    : std_logic_vector(2 downto 0) := "000";
    constant F3_MULH   : std_logic_vector(2 downto 0) := "001";
    constant F3_MULHSU : std_logic_vector(2 downto 0) := "010";
    constant F3_MULHU  : std_logic_vector(2 downto 0) := "011";
    constant F3_DIV    : std_logic_vector(2 downto 0) := "100";
    constant F3_DIVU   : std_logic_vector(2 downto 0) := "101";
    constant F3_REM    : std_logic_vector(2 downto 0) := "110";
    constant F3_REMU   : std_logic_vector(2 downto 0) := "111";

    ---------------------------------------------------------------------------
    -- Selectores internos del datapath
    --
    -- ALU_*: operacion concreta que ejecuta la ALU.
    -- Numero de bits elegido como 5 para englobar las 10 operaciones
    -- ordinarias mas 8 de la extension M.
    ---------------------------------------------------------------------------
    constant ALU_ADD  : std_logic_vector(4 downto 0) := "00000";
    constant ALU_SUB  : std_logic_vector(4 downto 0) := "00001";
    constant ALU_SLL  : std_logic_vector(4 downto 0) := "00010";
    constant ALU_SLT  : std_logic_vector(4 downto 0) := "00011";
    constant ALU_SLTU : std_logic_vector(4 downto 0) := "00100";
    constant ALU_XOR  : std_logic_vector(4 downto 0) := "00101";
    constant ALU_SRL  : std_logic_vector(4 downto 0) := "00110";
    constant ALU_SRA  : std_logic_vector(4 downto 0) := "00111";
    constant ALU_OR   : std_logic_vector(4 downto 0) := "01000";
    constant ALU_AND  : std_logic_vector(4 downto 0) := "01001";
    constant ALU_COPY_B : std_logic_vector(4 downto 0) := "01010"; -- pasa B (para LUI)
    -- Extension M
    constant ALU_MUL    : std_logic_vector(4 downto 0) := "10000";
    constant ALU_MULH   : std_logic_vector(4 downto 0) := "10001";
    constant ALU_MULHSU : std_logic_vector(4 downto 0) := "10010";
    constant ALU_MULHU  : std_logic_vector(4 downto 0) := "10011";
    constant ALU_DIV    : std_logic_vector(4 downto 0) := "10100";
    constant ALU_DIVU   : std_logic_vector(4 downto 0) := "10101";
    constant ALU_REM    : std_logic_vector(4 downto 0) := "10110";
    constant ALU_REMU   : std_logic_vector(4 downto 0) := "10111";

    -- Selectores de fuente de los operandos de la ALU.
    -- A: rs1, PC, 0
    -- B: rs2, immediate
    constant ASRC_RS1  : std_logic_vector(1 downto 0) := "00";
    constant ASRC_PC   : std_logic_vector(1 downto 0) := "01";
    constant ASRC_ZERO : std_logic_vector(1 downto 0) := "10";
    constant BSRC_RS2  : std_logic := '0';
    constant BSRC_IMM  : std_logic := '1';

    -- Fuente del dato a escribir en el banco de registros
    constant WBSRC_ALU  : std_logic_vector(1 downto 0) := "00";
    constant WBSRC_MEM  : std_logic_vector(1 downto 0) := "01";
    constant WBSRC_PC4  : std_logic_vector(1 downto 0) := "10"; -- PC+4 (JAL/JALR)
    constant WBSRC_CSR  : std_logic_vector(1 downto 0) := "11";

    -- Tipo de transferencia de memoria (codifica anchura + signo)
    -- bit 2 = unsigned-load, bits 1:0 = ancho (00=byte, 01=half, 10=word)
    constant MEM_B  : std_logic_vector(2 downto 0) := "000";
    constant MEM_H  : std_logic_vector(2 downto 0) := "001";
    constant MEM_W  : std_logic_vector(2 downto 0) := "010";
    constant MEM_BU : std_logic_vector(2 downto 0) := "100";
    constant MEM_HU : std_logic_vector(2 downto 0) := "101";

    -- Forwarding (cada operando puede venir del banco, de EX/MEM o de MEM/WB)
    constant FWD_REG    : std_logic_vector(1 downto 0) := "00";
    constant FWD_EX_MEM : std_logic_vector(1 downto 0) := "01";
    constant FWD_MEM_WB : std_logic_vector(1 downto 0) := "10";

    ---------------------------------------------------------------------------
    -- CSRs minimos soportados (machine mode)
    ---------------------------------------------------------------------------
    constant CSR_MSTATUS : std_logic_vector(11 downto 0) := X"300";
    constant CSR_MISA    : std_logic_vector(11 downto 0) := X"301";
    constant CSR_MIE     : std_logic_vector(11 downto 0) := X"304";
    constant CSR_MTVEC   : std_logic_vector(11 downto 0) := X"305";
    constant CSR_MSCRATCH: std_logic_vector(11 downto 0) := X"340";
    constant CSR_MEPC    : std_logic_vector(11 downto 0) := X"341";
    constant CSR_MCAUSE  : std_logic_vector(11 downto 0) := X"342";
    constant CSR_MTVAL   : std_logic_vector(11 downto 0) := X"343";
    constant CSR_MIP     : std_logic_vector(11 downto 0) := X"344";
    constant CSR_MCYCLE  : std_logic_vector(11 downto 0) := X"B00";
    constant CSR_MCYCLEH : std_logic_vector(11 downto 0) := X"B80";

    -- Operaciones internas de la unidad CSR
    constant CSROP_NONE : std_logic_vector(1 downto 0) := "00";
    constant CSROP_RW   : std_logic_vector(1 downto 0) := "01";
    constant CSROP_RS   : std_logic_vector(1 downto 0) := "10";
    constant CSROP_RC   : std_logic_vector(1 downto 0) := "11";

    ---------------------------------------------------------------------------
    -- Mapeo de memoria del SoC (32 bits)
    --
    -- 0x0000_0000 .. 0x0000_FFFF -> RAM principal (64 KiB BRAM, codigo+datos)
    -- 0x1000_0000 .. 0x1001_2BFF -> Framebuffer (320x240 nibble por pixel)
    -- 0xF000_0000 .. 0xF000_00FF -> Periferia MMIO (UART, GPIO, timer, HEX)
    ---------------------------------------------------------------------------
    constant MAINMEM_BASE : word_t := X"00000000";
    constant FB_BASE      : word_t := X"10000000";
    constant SDRAM_BASE   : word_t := X"20000000";
    constant MMIO_BASE    : word_t := X"F0000000";

    -- Offsets dentro de la region MMIO
    constant MMIO_OFF_LEDR     : std_logic_vector(7 downto 0) := X"00";
    constant MMIO_OFF_SWITCHES : std_logic_vector(7 downto 0) := X"04";
    constant MMIO_OFF_KEYS     : std_logic_vector(7 downto 0) := X"08";
    constant MMIO_OFF_HEX      : std_logic_vector(7 downto 0) := X"0C"; -- 6x4 bits empaquetados
    constant MMIO_OFF_UART_TX  : std_logic_vector(7 downto 0) := X"10";
    constant MMIO_OFF_UART_ST  : std_logic_vector(7 downto 0) := X"14";
    constant MMIO_OFF_TIMER    : std_logic_vector(7 downto 0) := X"18";
    constant MMIO_OFF_JOYSTICK : std_logic_vector(7 downto 0) := X"1C";
    constant MMIO_OFF_PALETTE  : std_logic_vector(7 downto 0) := X"20"; -- base de 16 paletas
    constant MMIO_OFF_UART_RX  : std_logic_vector(7 downto 0) := X"60";

end package riscv_pkg;

package body riscv_pkg is
end package body riscv_pkg;
