--------------------------------------------------------------------------------
-- cpu_core.vhd
--
-- Nucleo RV32IM con pipeline en orden de 5 etapas (IF, ID, EX, MEM, WB).
--
--  IF  (instruction fetch)
--      Calcula el PC, lo presenta al bus de instrucciones y latchea la
--      palabra recibida en el registro IF/ID.
--
--  ID  (instruction decode + register read)
--      Decodifica la instruccion y lee rs1/rs2 del banco. Pasa todo el
--      paquete de control al registro ID/EX.
--
--  EX  (execute)
--      Resuelve forwarding sobre los operandos, ejecuta la ALU (incluida la
--      extension M, que puede generar stalls), evalua el branch y calcula
--      el destino. Aqui se hace tambien la entrada/salida de trampas.
--
--  MEM (memory access)
--      Envia loads/stores al bus de datos. Para loads, ajusta el dato leido
--      al tamano y signo segun mem_op.
--
--  WB  (write back)
--      Escribe el banco con el dato seleccionado por wb_src.
--
-- Buses externos
--  - I-bus: sincrono, sin handshake. Se asume latencia 1 ciclo (BRAM).
--  - D-bus: idem, con write-enable y byte-enable de 4 bits, dato 32 bits.
--
-- En cada ciclo el pipeline avanza una etapa salvo que el hazard_unit
-- pida stall (load-use, ALU multiciclo) o flush (branch tomado, trampa).
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

library work;
use work.riscv_pkg.all;

entity cpu_core is
    port (
        I_clk        : in  std_logic;
        I_reset      : in  std_logic;
        -- Bus de instrucciones (lectura)
        O_imem_addr  : out word_t;
        I_imem_data  : in  word_t;
        -- Bus de datos (lectura/escritura, byte enables 4 bits)
        O_dmem_addr  : out word_t;
        O_dmem_wdata : out word_t;
        O_dmem_we    : out std_logic;
        O_dmem_be    : out std_logic_vector(3 downto 0);
        I_dmem_rdata : in  word_t;
        -- Interrupcion externa (sin uso por ahora, se podra elevar
        -- desde el SoC). I_irq=1 genera entrada a trampa con cause=IRQ_M_EXT.
        I_irq        : in  std_logic;
        -- Depuracion: PC actual de la etapa de IF (para debug visual)
        O_dbg_pc     : out word_t
    );
end entity cpu_core;

architecture Behavioral of cpu_core is

    ---------------------------------------------------------------------------
    -- Declaraciones de componentes (instanciacion tipo "component map")
    ---------------------------------------------------------------------------
    component register_file is
        port (
            I_clk    : in  std_logic;
            I_reset  : in  std_logic;
            I_we     : in  std_logic;
            I_rd     : in  std_logic_vector(4 downto 0);
            I_wdata  : in  word_t;
            I_rs1    : in  std_logic_vector(4 downto 0);
            I_rs2    : in  std_logic_vector(4 downto 0);
            O_rs1d   : out word_t;
            O_rs2d   : out word_t
        );
    end component;

    component decoder is
        port (
            I_instr     : in  word_t;
            O_rs1       : out std_logic_vector(4 downto 0);
            O_rs2       : out std_logic_vector(4 downto 0);
            O_rd        : out std_logic_vector(4 downto 0);
            O_imm       : out word_t;
            O_alu_op    : out std_logic_vector(4 downto 0);
            O_a_src     : out std_logic_vector(1 downto 0);
            O_b_src     : out std_logic;
            O_wb_src    : out std_logic_vector(1 downto 0);
            O_reg_we    : out std_logic;
            O_mem_re    : out std_logic;
            O_mem_we    : out std_logic;
            O_mem_op    : out std_logic_vector(2 downto 0);
            O_is_branch : out std_logic;
            O_is_jal    : out std_logic;
            O_is_jalr   : out std_logic;
            O_br_func   : out std_logic_vector(2 downto 0);
            O_csr_op    : out std_logic_vector(1 downto 0);
            O_csr_addr  : out std_logic_vector(11 downto 0);
            O_csr_imm   : out std_logic;
            O_is_ecall  : out std_logic;
            O_is_ebreak : out std_logic;
            O_is_mret   : out std_logic;
            O_is_mul    : out std_logic;
            O_is_div    : out std_logic;
            O_illegal   : out std_logic
        );
    end component;

    component alu is
        port (
            I_clk    : in  std_logic;
            I_reset  : in  std_logic;
            I_op     : in  std_logic_vector(4 downto 0);
            I_a      : in  word_t;
            I_b      : in  word_t;
            I_valid  : in  std_logic;
            O_result : out word_t;
            O_busy   : out std_logic
        );
    end component;

    component branch_unit is
        port (
            I_is_branch : in  std_logic;
            I_is_jal    : in  std_logic;
            I_is_jalr   : in  std_logic;
            I_br_func   : in  std_logic_vector(2 downto 0);
            I_a         : in  word_t;
            I_b         : in  word_t;
            I_alu_res   : in  word_t;
            O_take      : out std_logic;
            O_target    : out word_t
        );
    end component;

    component csr_unit is
        port (
            I_clk         : in  std_logic;
            I_reset       : in  std_logic;
            I_valid       : in  std_logic;
            I_csr_op      : in  std_logic_vector(1 downto 0);
            I_csr_addr    : in  std_logic_vector(11 downto 0);
            I_src         : in  word_t;
            O_rdata       : out word_t;
            I_trap_enter  : in  std_logic;
            I_trap_pc     : in  word_t;
            I_trap_cause  : in  word_t;
            I_trap_tval   : in  word_t;
            I_trap_exit   : in  std_logic;
            O_mtvec       : out word_t;
            O_mepc        : out word_t;
            O_mstatus_mie : out std_logic
        );
    end component;

    component hazard_unit is
        port (
            I_id_rs1     : in  std_logic_vector(4 downto 0);
            I_id_rs2     : in  std_logic_vector(4 downto 0);
            I_ex_rs1     : in  std_logic_vector(4 downto 0);
            I_ex_rs2     : in  std_logic_vector(4 downto 0);
            I_ex_rd      : in  std_logic_vector(4 downto 0);
            I_ex_reg_we  : in  std_logic;
            I_ex_mem_re  : in  std_logic;
            I_mem_rd     : in  std_logic_vector(4 downto 0);
            I_mem_reg_we : in  std_logic;
            I_wb_rd      : in  std_logic_vector(4 downto 0);
            I_wb_reg_we  : in  std_logic;
            I_alu_busy   : in  std_logic;
            I_branch_take: in  std_logic;
            I_trap       : in  std_logic;
            O_fwd_a      : out std_logic_vector(1 downto 0);
            O_fwd_b      : out std_logic_vector(1 downto 0);
            O_stall_pc    : out std_logic;
            O_stall_if_id : out std_logic;
            O_stall_id_ex : out std_logic;
            O_bubble_id_ex: out std_logic;
            O_bubble_ex_mem: out std_logic;
            O_flush_if   : out std_logic;
            O_flush_id   : out std_logic
        );
    end component;

    ---------------------------------------------------------------------------
    -- Senales del pipeline
    ---------------------------------------------------------------------------
    -- Etapa IF
    signal pc          : word_t := ADDR_RESET;
    signal pc_next     : word_t;

    -- pc_latched: el PC presentado a la BRAM en el ciclo anterior.
    -- Como la BRAM tiene 1 ciclo de latencia, I_imem_data en ciclo T
    -- corresponde al PC presentado en ciclo T-1 (= pc_latched en T).
    -- Necesitamos esto para if_id_pc apunte de verdad a la instruccion
    -- recibida (importante para AUIPC, JAL, branches que usan PC).
    signal pc_latched     : word_t := (others => '0');
    -- flush_pending: extiende h_flush_if un ciclo extra para descartar
    -- la instruccion "fantasma" que la BRAM precargo antes del branch.
    -- Iniciamos a '1' para descartar la primera lectura tras reset
    -- (cuando la BRAM aun no tenia datos validos).
    signal flush_pending  : std_logic := '1';

    -- Registro IF/ID
    signal if_id_instr : word_t := X"00000013"; -- NOP (ADDI x0, x0, 0)
    signal if_id_pc    : word_t := (others => '0');

    -- Etapa ID (señales del decoder)
    signal id_rs1, id_rs2, id_rd : std_logic_vector(4 downto 0);
    signal id_imm                : word_t;
    signal id_alu_op             : std_logic_vector(4 downto 0);
    signal id_a_src              : std_logic_vector(1 downto 0);
    signal id_b_src              : std_logic;
    signal id_wb_src             : std_logic_vector(1 downto 0);
    signal id_reg_we             : std_logic;
    signal id_mem_re, id_mem_we  : std_logic;
    signal id_mem_op             : std_logic_vector(2 downto 0);
    signal id_is_branch, id_is_jal, id_is_jalr : std_logic;
    signal id_br_func            : std_logic_vector(2 downto 0);
    signal id_csr_op             : std_logic_vector(1 downto 0);
    signal id_csr_addr           : std_logic_vector(11 downto 0);
    signal id_csr_imm            : std_logic;
    signal id_is_ecall, id_is_ebreak, id_is_mret : std_logic;
    signal id_illegal            : std_logic;
    signal id_rs1d, id_rs2d      : word_t;

    -- Registro ID/EX
    type id_ex_t is record
        pc        : word_t;
        rs1, rs2  : std_logic_vector(4 downto 0);
        rd        : std_logic_vector(4 downto 0);
        rs1d, rs2d: word_t;
        imm       : word_t;
        alu_op    : std_logic_vector(4 downto 0);
        a_src     : std_logic_vector(1 downto 0);
        b_src     : std_logic;
        wb_src    : std_logic_vector(1 downto 0);
        reg_we    : std_logic;
        mem_re    : std_logic;
        mem_we    : std_logic;
        mem_op    : std_logic_vector(2 downto 0);
        is_branch : std_logic;
        is_jal    : std_logic;
        is_jalr   : std_logic;
        br_func   : std_logic_vector(2 downto 0);
        csr_op    : std_logic_vector(1 downto 0);
        csr_addr  : std_logic_vector(11 downto 0);
        csr_imm   : std_logic;
        is_ecall  : std_logic;
        is_ebreak : std_logic;
        is_mret   : std_logic;
        illegal   : std_logic;
        valid     : std_logic;
    end record;

    constant ID_EX_NOP : id_ex_t := (
        pc => (others=>'0'),
        rs1 => "00000", rs2 => "00000", rd => "00000",
        rs1d => (others=>'0'), rs2d => (others=>'0'),
        imm => (others=>'0'),
        alu_op => ALU_ADD,
        a_src => ASRC_RS1, b_src => BSRC_RS2,
        wb_src => WBSRC_ALU,
        reg_we => '0', mem_re => '0', mem_we => '0',
        mem_op => MEM_W,
        is_branch => '0', is_jal => '0', is_jalr => '0',
        br_func => "000",
        csr_op => CSROP_NONE, csr_addr => (others=>'0'), csr_imm => '0',
        is_ecall => '0', is_ebreak => '0', is_mret => '0',
        illegal => '0',
        valid => '0'
    );

    signal id_ex : id_ex_t := ID_EX_NOP;

    -- Etapa EX
    signal ex_a_after_fwd     : word_t;
    signal ex_b_after_fwd     : word_t;
    signal ex_alu_a           : word_t;
    signal ex_alu_b           : word_t;
    signal ex_alu_result      : word_t;
    signal ex_alu_busy        : std_logic;
    signal ex_branch_take     : std_logic;
    signal ex_branch_target   : word_t;
    signal ex_csr_rdata       : word_t;
    signal ex_csr_src         : word_t;
    signal ex_wb_data         : word_t; -- valor a propagar a MEM/WB para banco

    -- Registro EX/MEM
    type ex_mem_t is record
        rd        : std_logic_vector(4 downto 0);
        alu_or_csr: word_t;     -- dato para WB si no es load
        rs2d      : word_t;     -- dato a almacenar en stores (ya forwardeado)
        addr      : word_t;     -- direccion de memoria
        pc_plus4  : word_t;     -- para JAL/JALR
        wb_src    : std_logic_vector(1 downto 0);
        reg_we    : std_logic;
        mem_re    : std_logic;
        mem_we    : std_logic;
        mem_op    : std_logic_vector(2 downto 0);
        valid     : std_logic;
    end record;

    constant EX_MEM_NOP : ex_mem_t := (
        rd => "00000",
        alu_or_csr => (others=>'0'),
        rs2d => (others=>'0'),
        addr => (others=>'0'),
        pc_plus4 => (others=>'0'),
        wb_src => WBSRC_ALU,
        reg_we => '0', mem_re => '0', mem_we => '0',
        mem_op => MEM_W,
        valid => '0'
    );

    signal ex_mem : ex_mem_t := EX_MEM_NOP;

    -- Etapa MEM: solo genera el be y wdata para stores
    signal mem_dbus_be   : std_logic_vector(3 downto 0);
    signal mem_dbus_wd   : word_t;

    -- Registro MEM/WB
    --
    -- IMPORTANTE: la BRAM sincrona devuelve I_dmem_rdata un ciclo despues
    -- de presentar la direccion. Si latcheamos el dato extraido en este
    -- registro al mismo flanco que actualiza la BRAM, capturariamos el
    -- dato antiguo. Por eso aqui solo guardamos METADATA (rd, wb_src,
    -- mem_op, addr LSBs, alu_or_csr, pc+4) y la extraccion del load se
    -- hace combinacionalmente en la etapa WB usando I_dmem_rdata (que
    -- ya es valido en ese ciclo).
    type mem_wb_t is record
        rd         : std_logic_vector(4 downto 0);
        reg_we     : std_logic;
        valid      : std_logic;
        wb_src     : std_logic_vector(1 downto 0);
        mem_op     : std_logic_vector(2 downto 0);
        addr_lsb   : std_logic_vector(1 downto 0);
        alu_or_csr : word_t;
        pc_plus4   : word_t;
    end record;

    constant MEM_WB_NOP : mem_wb_t := (
        rd => "00000", reg_we => '0', valid => '0',
        wb_src => WBSRC_ALU,
        mem_op => MEM_W,
        addr_lsb => "00",
        alu_or_csr => (others=>'0'),
        pc_plus4 => (others=>'0')
    );

    signal mem_wb : mem_wb_t := MEM_WB_NOP;

    -- Datos finales para el banco de registros (combinacionales en WB)
    signal wb_load_data : word_t;
    signal wb_data      : word_t;

    -- Hazard signals
    signal h_fwd_a, h_fwd_b      : std_logic_vector(1 downto 0);
    signal h_stall_pc, h_stall_if_id : std_logic;
    signal h_stall_id_ex         : std_logic;
    signal h_bubble_id_ex        : std_logic;
    signal h_bubble_ex_mem       : std_logic;
    signal h_flush_if, h_flush_id: std_logic;

    -- CSR salidas
    signal csr_mtvec       : word_t;
    signal csr_mepc        : word_t;
    -- csr_mstatus_mie no se conecta aqui mientras I_irq no este habilitado.
    -- Cuando se anadan interrupciones externas, se debera enmascarar con
    -- este bit. De momento se asigna a OPEN en el port map del csr_unit.

    -- Trampa: por ahora solo se generan trampas sincronas (illegal, ecall,
    -- ebreak). Las interrupciones externas se podrian habilitar bajo
    -- I_irq + mstatus.MIE.
    signal trap_enter : std_logic;
    signal trap_exit  : std_logic;
    signal trap_any   : std_logic;
    signal trap_cause : word_t;
    signal trap_tval  : word_t;
    signal trap_pc    : word_t;

    -- Banco de registros senales internas
    signal rf_we    : std_logic;
    signal rf_rd    : std_logic_vector(4 downto 0);
    signal rf_wdata : word_t;

begin

    ---------------------------------------------------------------------------
    -- Banco de registros (escritura en WB usando wb_data combinacional)
    ---------------------------------------------------------------------------
    rf_we    <= mem_wb.reg_we and mem_wb.valid;
    rf_rd    <= mem_wb.rd;
    rf_wdata <= wb_data;

    rf_inst : register_file port map (
        I_clk   => I_clk,
        I_reset => I_reset,
        I_we    => rf_we,
        I_rd    => rf_rd,
        I_wdata => rf_wdata,
        I_rs1   => id_rs1,
        I_rs2   => id_rs2,
        O_rs1d  => id_rs1d,
        O_rs2d  => id_rs2d
    );

    ---------------------------------------------------------------------------
    -- Decoder (etapa ID)
    ---------------------------------------------------------------------------
    dec_inst : decoder port map (
        I_instr     => if_id_instr,
        O_rs1       => id_rs1,
        O_rs2       => id_rs2,
        O_rd        => id_rd,
        O_imm       => id_imm,
        O_alu_op    => id_alu_op,
        O_a_src     => id_a_src,
        O_b_src     => id_b_src,
        O_wb_src    => id_wb_src,
        O_reg_we    => id_reg_we,
        O_mem_re    => id_mem_re,
        O_mem_we    => id_mem_we,
        O_mem_op    => id_mem_op,
        O_is_branch => id_is_branch,
        O_is_jal    => id_is_jal,
        O_is_jalr   => id_is_jalr,
        O_br_func   => id_br_func,
        O_csr_op    => id_csr_op,
        O_csr_addr  => id_csr_addr,
        O_csr_imm   => id_csr_imm,
        O_is_ecall  => id_is_ecall,
        O_is_ebreak => id_is_ebreak,
        O_is_mret   => id_is_mret,
        -- is_mul/is_div del decoder no se usan: el stall ya lo gestiona
        -- O_busy de la ALU.
        O_is_mul    => open,
        O_is_div    => open,
        O_illegal   => id_illegal
    );

    ---------------------------------------------------------------------------
    -- Hazard unit
    ---------------------------------------------------------------------------
    hz_inst : hazard_unit port map (
        -- load-use detection (instruccion en ID, decoder)
        I_id_rs1     => id_rs1,
        I_id_rs2     => id_rs2,
        -- forwarding (instruccion en EX)
        I_ex_rs1     => id_ex.rs1,
        I_ex_rs2     => id_ex.rs2,
        I_ex_rd      => id_ex.rd,
        I_ex_reg_we  => id_ex.reg_we,
        I_ex_mem_re  => id_ex.mem_re,
        I_mem_rd     => ex_mem.rd,
        I_mem_reg_we => ex_mem.reg_we,
        I_wb_rd      => mem_wb.rd,
        I_wb_reg_we  => mem_wb.reg_we,
        I_alu_busy   => ex_alu_busy,
        I_branch_take=> ex_branch_take,
        I_trap       => trap_any,
        O_fwd_a      => h_fwd_a,
        O_fwd_b      => h_fwd_b,
        O_stall_pc    => h_stall_pc,
        O_stall_if_id => h_stall_if_id,
        O_stall_id_ex => h_stall_id_ex,
        O_bubble_id_ex => h_bubble_id_ex,
        O_bubble_ex_mem => h_bubble_ex_mem,
        O_flush_if   => h_flush_if,
        O_flush_id   => h_flush_id
    );

    ---------------------------------------------------------------------------
    -- ALU + extension M
    ---------------------------------------------------------------------------
    alu_inst : alu port map (
        I_clk    => I_clk,
        I_reset  => I_reset,
        I_op     => id_ex.alu_op,
        I_a      => ex_alu_a,
        I_b      => ex_alu_b,
        I_valid  => id_ex.valid,
        O_result => ex_alu_result,
        O_busy   => ex_alu_busy
    );

    ---------------------------------------------------------------------------
    -- Branch unit
    ---------------------------------------------------------------------------
    br_inst : branch_unit port map (
        I_is_branch => id_ex.is_branch,
        I_is_jal    => id_ex.is_jal,
        I_is_jalr   => id_ex.is_jalr,
        I_br_func   => id_ex.br_func,
        I_a         => ex_a_after_fwd,
        I_b         => ex_b_after_fwd,
        I_alu_res   => ex_alu_result,
        O_take      => ex_branch_take,
        O_target    => ex_branch_target
    );

    ---------------------------------------------------------------------------
    -- CSR
    ---------------------------------------------------------------------------
    -- Si CSR{,I} usa inmediato, la fuente es uimm = rs1 zero-extended.
    -- En el decoder dejamos rs1 como std_logic_vector(4..0); se construye
    -- aqui el valor de 32 bits.
    ex_csr_src <= (X"000000" & "000" & id_ex.rs1) when id_ex.csr_imm = '1'
                                                  else ex_a_after_fwd;

    csr_inst : csr_unit port map (
        I_clk         => I_clk,
        I_reset       => I_reset,
        I_valid       => id_ex.valid,
        I_csr_op      => id_ex.csr_op,
        I_csr_addr    => id_ex.csr_addr,
        I_src         => ex_csr_src,
        O_rdata       => ex_csr_rdata,
        I_trap_enter  => trap_enter,
        I_trap_pc     => trap_pc,
        I_trap_cause  => trap_cause,
        I_trap_tval   => trap_tval,
        I_trap_exit   => trap_exit,
        O_mtvec       => csr_mtvec,
        O_mepc        => csr_mepc,
        O_mstatus_mie => open
    );

    ---------------------------------------------------------------------------
    -- Forwarding multiplexers
    ---------------------------------------------------------------------------
    -- Forwarding desde EX/MEM toma alu_or_csr (resultado ya latcheado).
    -- Desde MEM/WB tomamos wb_data, que es el valor final combinacional
    -- en la etapa WB (incluye loads usando el dato fresco de la BRAM).
    ex_a_after_fwd <= ex_mem.alu_or_csr when h_fwd_a = FWD_EX_MEM else
                      wb_data           when h_fwd_a = FWD_MEM_WB else
                      id_ex.rs1d;
    ex_b_after_fwd <= ex_mem.alu_or_csr when h_fwd_b = FWD_EX_MEM else
                      wb_data           when h_fwd_b = FWD_MEM_WB else
                      id_ex.rs2d;

    -- Operando A de la ALU: rs1 (con forwarding), PC o 0 (para LUI)
    ex_alu_a <= ex_a_after_fwd when id_ex.a_src = ASRC_RS1 else
                id_ex.pc        when id_ex.a_src = ASRC_PC  else
                (others => '0');
    -- Operando B: rs2 o imm
    ex_alu_b <= ex_b_after_fwd when id_ex.b_src = BSRC_RS2 else id_ex.imm;

    -- Dato que ira a la etapa siguiente:
    --  - operacion CSR -> valor leido (rdata) - se escribe en rd
    --  - en cualquier otro caso -> resultado de la ALU
    ex_wb_data <= ex_csr_rdata when id_ex.csr_op /= CSROP_NONE else ex_alu_result;

    ---------------------------------------------------------------------------
    -- PC y registro IF/ID
    --
    -- pc_next:
    --   - trampa entrando -> mtvec
    --   - MRET            -> mepc
    --   - branch tomado   -> branch target
    --   - stall           -> pc actual (no avanza)
    --   - resto           -> pc + 4
    ---------------------------------------------------------------------------
    pc_next <= csr_mtvec        when trap_enter = '1' else
               csr_mepc         when trap_exit  = '1' else
               ex_branch_target when ex_branch_take = '1' else
               pc               when h_stall_pc  = '1' else
               std_logic_vector(unsigned(pc) + 4);

    pc_proc : process (I_clk)
    begin
        if rising_edge(I_clk) then
            if I_reset = '1' then
                pc <= ADDR_RESET;
            else
                pc <= pc_next;
            end if;
        end if;
    end process;

    O_imem_addr <= pc;
    O_dbg_pc    <= pc;

    ---------------------------------------------------------------------------
    -- Tracking del PC en vuelo hacia la BRAM:
    --   * pc_latched recuerda el PC que se le presento a la BRAM en el
    --     ciclo anterior. I_imem_data en este ciclo es ram[pc_latched].
    --   * flush_pending mantiene la senal de flush durante un ciclo extra
    --     despues de un branch tomado o trampa, porque la BRAM ya estaba
    --     precargando una instruccion "fantasma" que aun no ha llegado y
    --     entraria erroneamente en IF/ID al ciclo siguiente. Sin esto, la
    --     instruccion posterior al branch se ejecuta de todos modos.
    ---------------------------------------------------------------------------
    pc_track_proc : process (I_clk)
    begin
        if rising_edge(I_clk) then
            if I_reset = '1' then
                pc_latched    <= (others => '0');
                flush_pending <= '1';  -- ignora el primer dato post-reset
            else
                if h_stall_pc = '0' then
                    pc_latched <= pc;
                end if;
                flush_pending <= h_flush_if;
            end if;
        end if;
    end process;

    -- Registro IF/ID con flush, stall y latencia de BRAM
    if_id_proc : process (I_clk)
    begin
        if rising_edge(I_clk) then
            if I_reset = '1' then
                if_id_instr <= X"00000013"; -- NOP
                if_id_pc    <= (others => '0');
            elsif h_flush_if = '1' or flush_pending = '1' then
                -- Flush actual o "fantasma" del ciclo anterior
                if_id_instr <= X"00000013";
                if_id_pc    <= (others => '0');
            elsif h_stall_if_id = '1' then
                -- mantener registro
                null;
            else
                if_id_instr <= I_imem_data;
                if_id_pc    <= pc_latched;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Registro ID/EX
    --
    -- Si hay flush o burbuja se inserta NOP. La bubble (load-use) y el
    -- flush se gestionan distintos: la primera congela el frontend; el
    -- segundo deja avanzar pero limpia la entrada en EX.
    ---------------------------------------------------------------------------
    id_ex_proc : process (I_clk)
    begin
        if rising_edge(I_clk) then
            if I_reset = '1' then
                id_ex <= ID_EX_NOP;
            elsif h_stall_id_ex = '1' then
                -- ALU multiciclo: la instruccion debe quedarse en EX.
                -- No tocamos id_ex.
                null;
            elsif h_flush_id = '1' or h_bubble_id_ex = '1' then
                id_ex <= ID_EX_NOP;
            else
                id_ex.pc        <= if_id_pc;
                id_ex.rs1       <= id_rs1;
                id_ex.rs2       <= id_rs2;
                id_ex.rd        <= id_rd;
                id_ex.rs1d      <= id_rs1d;
                id_ex.rs2d      <= id_rs2d;
                id_ex.imm       <= id_imm;
                id_ex.alu_op    <= id_alu_op;
                id_ex.a_src     <= id_a_src;
                id_ex.b_src     <= id_b_src;
                id_ex.wb_src    <= id_wb_src;
                id_ex.reg_we    <= id_reg_we;
                id_ex.mem_re    <= id_mem_re;
                id_ex.mem_we    <= id_mem_we;
                id_ex.mem_op    <= id_mem_op;
                id_ex.is_branch <= id_is_branch;
                id_ex.is_jal    <= id_is_jal;
                id_ex.is_jalr   <= id_is_jalr;
                id_ex.br_func   <= id_br_func;
                id_ex.csr_op    <= id_csr_op;
                id_ex.csr_addr  <= id_csr_addr;
                id_ex.csr_imm   <= id_csr_imm;
                id_ex.is_ecall  <= id_is_ecall;
                id_ex.is_ebreak <= id_is_ebreak;
                id_ex.is_mret   <= id_is_mret;
                id_ex.illegal   <= id_illegal;
                id_ex.valid     <= '1';
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Generacion de trampas sincronas en EX
    --
    -- - ECALL  -> cause = 11 (Mmode environment call)
    -- - EBREAK -> cause = 3  (breakpoint)
    -- - ILLEGAL-> cause = 2
    --
    -- MRET se trata como salida de trampa: restaura PC desde mepc y mstatus.
    -- No se gestionan interrupciones externas todavia (I_irq queda enlazado
    -- pero no produce trampa por ahora; se puede activar enmascarando con
    -- csr_mstatus_mie). Esto es deliberadamente simple para mantener el
    -- core verificable.
    ---------------------------------------------------------------------------
    trap_proc : process (id_ex)
    begin
        trap_enter <= '0';
        trap_cause <= (others => '0');
        trap_tval  <= (others => '0');
        trap_pc    <= id_ex.pc;
        if id_ex.valid = '1' then
            if id_ex.illegal = '1' then
                trap_enter <= '1';
                trap_cause <= X"00000002";
                trap_tval  <= id_ex.pc;
            elsif id_ex.is_ecall = '1' then
                trap_enter <= '1';
                trap_cause <= X"0000000B";
            elsif id_ex.is_ebreak = '1' then
                trap_enter <= '1';
                trap_cause <= X"00000003";
            end if;
        end if;
    end process;

    trap_exit <= id_ex.is_mret and id_ex.valid;
    -- Tanto entrada como salida de trampa requieren flushear el frontend
    -- (en una se redirige a mtvec, en la otra a mepc).
    trap_any  <= trap_enter or trap_exit;

    ---------------------------------------------------------------------------
    -- Registro EX/MEM
    ---------------------------------------------------------------------------
    ex_mem_proc : process (I_clk)
    begin
        if rising_edge(I_clk) then
            if I_reset = '1' then
                ex_mem <= EX_MEM_NOP;
            elsif h_bubble_ex_mem = '1' then
                -- ALU ocupada en EX: insertamos NOP en MEM para que la
                -- burbuja fluya por MEM/WB y no se procese dos veces la
                -- misma instruccion.
                ex_mem <= EX_MEM_NOP;
            else
                ex_mem.rd         <= id_ex.rd;
                ex_mem.alu_or_csr <= ex_wb_data;
                ex_mem.rs2d       <= ex_b_after_fwd;
                ex_mem.addr       <= ex_alu_result;
                ex_mem.pc_plus4   <= std_logic_vector(unsigned(id_ex.pc) + 4);
                ex_mem.wb_src     <= id_ex.wb_src;
                ex_mem.reg_we     <= id_ex.reg_we and id_ex.valid and (not trap_enter);
                ex_mem.mem_re     <= id_ex.mem_re and id_ex.valid and (not trap_enter);
                ex_mem.mem_we     <= id_ex.mem_we and id_ex.valid and (not trap_enter);
                ex_mem.mem_op     <= id_ex.mem_op;
                ex_mem.valid      <= id_ex.valid and (not trap_enter);
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Etapa MEM
    --
    -- Solo presenta la peticion en el bus: direccion, byte enable y dato
    -- a escribir para stores. La extraccion del dato de un load (con su
    -- ajuste de signo) ocurre en la etapa WB porque el I_dmem_rdata de
    -- la BRAM aparece un ciclo despues de presentar la direccion.
    ---------------------------------------------------------------------------
    mem_store_proc : process (ex_mem)
        variable v_be : std_logic_vector(3 downto 0);
        variable v_wd : word_t;
        variable v_byte_off : integer range 0 to 3;
    begin
        v_be := (others => '0');
        v_wd := (others => '0');
        v_byte_off := to_integer(unsigned(ex_mem.addr(1 downto 0)));

        if ex_mem.mem_we = '1' then
            case ex_mem.mem_op is
                when MEM_B =>
                    case v_byte_off is
                        when 0 => v_be := "0001"; v_wd(7  downto  0) := ex_mem.rs2d(7 downto 0);
                        when 1 => v_be := "0010"; v_wd(15 downto  8) := ex_mem.rs2d(7 downto 0);
                        when 2 => v_be := "0100"; v_wd(23 downto 16) := ex_mem.rs2d(7 downto 0);
                        when 3 => v_be := "1000"; v_wd(31 downto 24) := ex_mem.rs2d(7 downto 0);
                    end case;
                when MEM_H =>
                    if ex_mem.addr(1) = '0' then
                        v_be := "0011"; v_wd(15 downto 0)  := ex_mem.rs2d(15 downto 0);
                    else
                        v_be := "1100"; v_wd(31 downto 16) := ex_mem.rs2d(15 downto 0);
                    end if;
                when MEM_W =>
                    v_be := "1111"; v_wd := ex_mem.rs2d;
                when others =>
                    v_be := "0000";
            end case;
        end if;

        mem_dbus_be <= v_be;
        mem_dbus_wd <= v_wd;
    end process;

    -- Salidas al D-bus (la direccion ya esta latcheada en ex_mem.addr)
    O_dmem_addr  <= ex_mem.addr;
    O_dmem_wdata <= mem_dbus_wd;
    O_dmem_we    <= ex_mem.mem_we;
    O_dmem_be    <= mem_dbus_be;

    ---------------------------------------------------------------------------
    -- Etapa WB
    --
    -- Aqui I_dmem_rdata ya esta valido (la BRAM lo refrescamos el ciclo
    -- anterior). Combinacionalmente extraemos el dato del load segun
    -- tamano y signo, luego seleccionamos la fuente final con el mux
    -- wb_src y entregamos el valor al banco de registros.
    ---------------------------------------------------------------------------
    wb_load_proc : process (mem_wb, I_dmem_rdata)
        variable v_byte_off : integer range 0 to 3;
        variable v_byte : std_logic_vector(7 downto 0);
        variable v_half : std_logic_vector(15 downto 0);
    begin
        v_byte_off := to_integer(unsigned(mem_wb.addr_lsb));
        case mem_wb.mem_op is
            when MEM_B =>
                case v_byte_off is
                    when 0 => v_byte := I_dmem_rdata(7  downto  0);
                    when 1 => v_byte := I_dmem_rdata(15 downto  8);
                    when 2 => v_byte := I_dmem_rdata(23 downto 16);
                    when 3 => v_byte := I_dmem_rdata(31 downto 24);
                end case;
                wb_load_data <= (31 downto 8 => v_byte(7)) & v_byte;
            when MEM_BU =>
                case v_byte_off is
                    when 0 => v_byte := I_dmem_rdata(7  downto  0);
                    when 1 => v_byte := I_dmem_rdata(15 downto  8);
                    when 2 => v_byte := I_dmem_rdata(23 downto 16);
                    when 3 => v_byte := I_dmem_rdata(31 downto 24);
                end case;
                wb_load_data <= X"000000" & v_byte;
            when MEM_H =>
                if mem_wb.addr_lsb(1) = '0' then
                    v_half := I_dmem_rdata(15 downto 0);
                else
                    v_half := I_dmem_rdata(31 downto 16);
                end if;
                wb_load_data <= (31 downto 16 => v_half(15)) & v_half;
            when MEM_HU =>
                if mem_wb.addr_lsb(1) = '0' then
                    v_half := I_dmem_rdata(15 downto 0);
                else
                    v_half := I_dmem_rdata(31 downto 16);
                end if;
                wb_load_data <= X"0000" & v_half;
            when others =>
                wb_load_data <= I_dmem_rdata;
        end case;
    end process;

    -- Mux final de WB: load extraido, PC+4 (JAL/JALR), o ALU/CSR
    wb_data <= wb_load_data    when mem_wb.wb_src = WBSRC_MEM else
               mem_wb.pc_plus4 when mem_wb.wb_src = WBSRC_PC4 else
               mem_wb.alu_or_csr;

    ---------------------------------------------------------------------------
    -- Registro MEM/WB
    --
    -- Captura unicamente METADATA. La extraccion del load se realiza
    -- combinacionalmente en WB, una vez la BRAM tiene listo el dato.
    ---------------------------------------------------------------------------
    mem_wb_proc : process (I_clk)
    begin
        if rising_edge(I_clk) then
            if I_reset = '1' then
                mem_wb <= MEM_WB_NOP;
            else
                mem_wb.rd         <= ex_mem.rd;
                mem_wb.reg_we     <= ex_mem.reg_we;
                mem_wb.valid      <= ex_mem.valid;
                mem_wb.wb_src     <= ex_mem.wb_src;
                mem_wb.mem_op     <= ex_mem.mem_op;
                mem_wb.addr_lsb   <= ex_mem.addr(1 downto 0);
                mem_wb.alu_or_csr <= ex_mem.alu_or_csr;
                mem_wb.pc_plus4   <= ex_mem.pc_plus4;
            end if;
        end if;
    end process;

end architecture Behavioral;
