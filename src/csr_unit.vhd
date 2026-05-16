--------------------------------------------------------------------------------
-- csr_unit.vhd
--
-- Unidad de Control and Status Registers para machine mode. Soporta el
-- subconjunto minimo necesario para una toolchain estandar RISC-V con
-- Newlib/picolibc:
--
--   mstatus, misa, mie, mtvec, mscratch, mepc, mcause, mtval, mip,
--   mcycle, mcycleh
--
-- Las operaciones soportadas son las tres clasicas (CSRRW, CSRRS, CSRRC)
-- en sus variantes con registro y con inmediato. La logica es totalmente
-- combinacional/un-ciclo: en EX se calcula el nuevo valor y se escribe
-- en el flanco siguiente.
--
-- Tambien actua como punto centralizado para entrada/salida de trampas:
--   * I_trap_enter  -> ocurre una excepcion: salvar pc y causa, ir a mtvec
--   * I_trap_exit   -> MRET: restaurar pc desde mepc y volver
--
-- mcycle/mcycleh son contadores libres de 64 bits que la software puede
-- usar para benchmarking (asi se pueden medir los FPS de Doom).
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

library work;
use work.riscv_pkg.all;

entity csr_unit is
    port (
        I_clk         : in  std_logic;
        I_reset       : in  std_logic;

        -- Interfaz con el pipeline (etapa EX)
        I_valid       : in  std_logic;                       -- la instruccion EX es valida
        I_csr_op      : in  std_logic_vector(1 downto 0);    -- CSROP_*
        I_csr_addr    : in  std_logic_vector(11 downto 0);
        I_src         : in  word_t;                          -- rs1 o uimm
        O_rdata       : out word_t;                          -- valor leido (antes de la op)

        -- Manejo de trampas
        I_trap_enter  : in  std_logic;
        I_trap_pc     : in  word_t;                          -- PC de la instruccion ofensiva
        I_trap_cause  : in  word_t;                          -- valor para mcause
        I_trap_tval   : in  word_t;                          -- valor para mtval
        I_trap_exit   : in  std_logic;                       -- MRET

        -- Salidas de CSR que necesitan otros modulos
        O_mtvec       : out word_t;
        O_mepc        : out word_t;
        O_mstatus_mie : out std_logic                        -- bit global de interrupt enable
    );
end entity csr_unit;

architecture Behavioral of csr_unit is

    -- CSRs almacenados
    signal r_mstatus  : word_t := (others => '0'); -- bit 3 = MIE, bit 7 = MPIE
    signal r_mtvec    : word_t := ADDR_TRAPVEC;
    signal r_mscratch : word_t := (others => '0');
    signal r_mepc     : word_t := (others => '0');
    signal r_mcause   : word_t := (others => '0');
    signal r_mtval    : word_t := (others => '0');
    signal r_mie      : word_t := (others => '0');
    signal r_mip      : word_t := (others => '0');

    -- Contadores de ciclos (64 bits)
    signal r_mcycle   : unsigned(63 downto 0) := (others => '0');

    -- Lectura combinacional segun direccion
    signal s_rdata    : word_t;

    -- Calculo del valor a escribir
    signal s_wdata    : word_t;
    signal s_do_write : std_logic;

    constant MISA_RV32IM : word_t := X"40001100"; -- MXL=1 (32b), bits I (8) y M (12)

begin

    ---------------------------------------------------------------------------
    -- Lectura combinacional. Las direcciones no implementadas devuelven 0.
    ---------------------------------------------------------------------------
    read_proc : process (I_csr_addr, r_mstatus, r_mtvec, r_mscratch, r_mepc,
                         r_mcause, r_mtval, r_mie, r_mip, r_mcycle)
    begin
        case I_csr_addr is
            when CSR_MSTATUS  => s_rdata <= r_mstatus;
            when CSR_MISA     => s_rdata <= MISA_RV32IM;
            when CSR_MIE      => s_rdata <= r_mie;
            when CSR_MTVEC    => s_rdata <= r_mtvec;
            when CSR_MSCRATCH => s_rdata <= r_mscratch;
            when CSR_MEPC     => s_rdata <= r_mepc;
            when CSR_MCAUSE   => s_rdata <= r_mcause;
            when CSR_MTVAL    => s_rdata <= r_mtval;
            when CSR_MIP      => s_rdata <= r_mip;
            when CSR_MCYCLE   => s_rdata <= std_logic_vector(r_mcycle(31 downto 0));
            when CSR_MCYCLEH  => s_rdata <= std_logic_vector(r_mcycle(63 downto 32));
            when others       => s_rdata <= (others => '0');
        end case;
    end process;

    O_rdata <= s_rdata;

    ---------------------------------------------------------------------------
    -- Valor a escribir segun la operacion
    ---------------------------------------------------------------------------
    s_do_write <= '1' when (I_valid = '1' and I_csr_op /= CSROP_NONE) else '0';

    write_data_proc : process (I_csr_op, I_src, s_rdata)
    begin
        case I_csr_op is
            when CSROP_RW => s_wdata <= I_src;
            when CSROP_RS => s_wdata <= s_rdata or  I_src;
            when CSROP_RC => s_wdata <= s_rdata and (not I_src);
            when others   => s_wdata <= s_rdata;
        end case;
    end process;

    ---------------------------------------------------------------------------
    -- Escritura sincrona y gestion de trampas
    ---------------------------------------------------------------------------
    write_proc : process (I_clk)
    begin
        if rising_edge(I_clk) then
            -- Contador de ciclos siempre cuenta
            r_mcycle <= r_mcycle + 1;

            if I_reset = '1' then
                r_mstatus  <= (others => '0');
                r_mtvec    <= ADDR_TRAPVEC;
                r_mscratch <= (others => '0');
                r_mepc     <= (others => '0');
                r_mcause   <= (others => '0');
                r_mtval    <= (others => '0');
                r_mie      <= (others => '0');
                r_mip      <= (others => '0');
                r_mcycle   <= (others => '0');
            else
                -- 1) Entrada en trampa tiene prioridad: salva contexto
                if I_trap_enter = '1' then
                    r_mepc            <= I_trap_pc;
                    r_mcause          <= I_trap_cause;
                    r_mtval           <= I_trap_tval;
                    -- MPIE <- MIE; MIE <- 0
                    r_mstatus(7)      <= r_mstatus(3);
                    r_mstatus(3)      <= '0';

                -- 2) MRET: restaura MIE y deja al pipeline saltar a mepc
                elsif I_trap_exit = '1' then
                    r_mstatus(3) <= r_mstatus(7);
                    r_mstatus(7) <= '1';

                -- 3) Escritura ordinaria de CSR
                elsif s_do_write = '1' then
                    case I_csr_addr is
                        when CSR_MSTATUS  => r_mstatus  <= s_wdata;
                        when CSR_MIE      => r_mie      <= s_wdata;
                        when CSR_MTVEC    => r_mtvec    <= s_wdata;
                        when CSR_MSCRATCH => r_mscratch <= s_wdata;
                        when CSR_MEPC     => r_mepc     <= s_wdata;
                        when CSR_MCAUSE   => r_mcause   <= s_wdata;
                        when CSR_MTVAL    => r_mtval    <= s_wdata;
                        when CSR_MIP      => r_mip      <= s_wdata;
                        when others       => null;
                    end case;
                end if;
            end if;
        end if;
    end process;

    -- Salidas para el datapath
    O_mtvec       <= r_mtvec;
    O_mepc        <= r_mepc;
    O_mstatus_mie <= r_mstatus(3);

end architecture Behavioral;
