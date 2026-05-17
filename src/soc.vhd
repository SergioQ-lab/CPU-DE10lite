--------------------------------------------------------------------------------
-- soc.vhd
--
-- Integrador del SoC: une la CPU con la memoria principal, el framebuffer
-- VGA y la periferia MMIO. Implementa el address decoding del bus de
-- datos para decidir a quien va dirigida cada transaccion.
--
-- Mapa de memoria (visto desde la CPU):
--   0x0000_0000..0x0000_FFFF   RAM principal (64 KiB)
--   0x1000_0000..0x1001_2BFF   Framebuffer indexado
--   0xF000_0000..0xF000_00FF   Periferia MMIO
--
-- El bus de instrucciones esta cableado directamente al puerto A de la
-- RAM (Harvard simplificado: las instrucciones SOLO se buscan en la RAM
-- principal). Esto simplifica el critical path y refuerza el contenido
-- del programa contra escrituras accidentales.
--
-- Las lecturas tienen 1 ciclo de latencia (BRAM + MMIO). El pipeline de
-- la CPU ya esta disenado asumiendo eso (etapas MEM y WB), por lo que no
-- hace falta handshake.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

library work;
use work.riscv_pkg.all;

entity soc is
    port (
        I_clk_50  : in  std_logic;
        I_reset_n : in  std_logic;  -- reset activo en bajo (KEY0)

        -- Switches/keys/LEDs
        I_sw      : in  std_logic_vector(9 downto 0);
        I_key     : in  std_logic_vector(1 downto 0);
        O_ledr    : out std_logic_vector(9 downto 0);

        -- Displays
        O_hex0    : out std_logic_vector(7 downto 0);
        O_hex1    : out std_logic_vector(7 downto 0);
        O_hex2    : out std_logic_vector(7 downto 0);
        O_hex3    : out std_logic_vector(7 downto 0);
        O_hex4    : out std_logic_vector(7 downto 0);
        O_hex5    : out std_logic_vector(7 downto 0);

        -- VGA fisico
        O_vga_hs  : out std_logic;
        O_vga_vs  : out std_logic;
        O_vga_r   : out std_logic_vector(3 downto 0);
        O_vga_g   : out std_logic_vector(3 downto 0);
        O_vga_b   : out std_logic_vector(3 downto 0);

        -- UART
        O_uart_tx : out std_logic;

        -- Joystick
        I_joystick: in  std_logic_vector(6 downto 0);

        -- SDRAM
        O_sdram_clk  : out   std_logic;
        O_sdram_cke  : out   std_logic;
        O_sdram_cs_n : out   std_logic;
        O_sdram_ras_n: out   std_logic;
        O_sdram_cas_n: out   std_logic;
        O_sdram_we_n : out   std_logic;
        O_sdram_addr : out   std_logic_vector(12 downto 0);
        O_sdram_ba   : out   std_logic_vector(1 downto 0);
        O_sdram_ldqm : out   std_logic;
        O_sdram_udqm : out   std_logic;
        IO_sdram_dq  : inout std_logic_vector(15 downto 0)
    );
end entity soc;

architecture Behavioral of soc is

    component cpu_core is
        port (
            I_clk        : in  std_logic;
            I_reset      : in  std_logic;
            O_imem_addr  : out word_t;
            I_imem_data  : in  word_t;
            O_dmem_addr  : out word_t;
            O_dmem_wdata : out word_t;
            O_dmem_we    : out std_logic;
            O_dmem_be    : out std_logic_vector(3 downto 0);
            I_dmem_rdata : in  word_t;
            I_dmem_busy  : in  std_logic;
            I_irq        : in  std_logic;
            O_dbg_pc     : out word_t
        );
    end component;

    component main_memory is
        generic (
            ADDR_BITS : integer := 13;
            INIT_FILE: string  := "program.mif"
        );
        port (
            I_clk     : in  std_logic;
            I_addr_a  : in  std_logic_vector(ADDR_BITS-1 downto 0);
            O_data_a  : out word_t;
            I_addr_b  : in  std_logic_vector(ADDR_BITS-1 downto 0);
            I_we_b    : in  std_logic;
            I_be_b    : in  std_logic_vector(3 downto 0);
            I_wdata_b : in  word_t;
            O_data_b  : out word_t
        );
    end component;

    component vga_framebuffer is
        generic (
            FB_ADDR_BITS : integer := 13
        );
        port (
            I_clk_50  : in  std_logic;
            I_reset   : in  std_logic;
            I_we      : in  std_logic;
            I_addr    : in  std_logic_vector(FB_ADDR_BITS-1 downto 0);
            I_wdata   : in  word_t;
            I_be      : in  std_logic_vector(3 downto 0);
            O_rdata   : out word_t;
            I_pal_we     : in  std_logic;
            I_pal_index  : in  std_logic_vector(3 downto 0);
            I_pal_data   : in  std_logic_vector(11 downto 0);
            O_hs      : out std_logic;
            O_vs      : out std_logic;
            O_r       : out std_logic_vector(3 downto 0);
            O_g       : out std_logic_vector(3 downto 0);
            O_b       : out std_logic_vector(3 downto 0)
        );
    end component;

    component mmio_bridge is
        port (
            I_clk     : in  std_logic;
            I_reset   : in  std_logic;
            I_sel     : in  std_logic;
            I_we      : in  std_logic;
            I_addr    : in  word_t;
            I_wdata   : in  word_t;
            I_be      : in  std_logic_vector(3 downto 0);
            O_rdata   : out word_t;
            O_ledr    : out std_logic_vector(9 downto 0);
            I_sw      : in  std_logic_vector(9 downto 0);
            I_key     : in  std_logic_vector(1 downto 0);
            O_hex0    : out std_logic_vector(7 downto 0);
            O_hex1    : out std_logic_vector(7 downto 0);
            O_hex2    : out std_logic_vector(7 downto 0);
            O_hex3    : out std_logic_vector(7 downto 0);
            O_hex4    : out std_logic_vector(7 downto 0);
            O_hex5    : out std_logic_vector(7 downto 0);
            O_uart_tx : out std_logic;
            O_pal_we    : out std_logic;
            O_pal_index : out std_logic_vector(3 downto 0);
            O_pal_data  : out std_logic_vector(11 downto 0);
            I_joystick  : in  std_logic_vector(6 downto 0)
        );
    end component;

    component sdram_controller is
        port (
            I_clk        : in    std_logic;
            I_reset      : in    std_logic;
            I_addr       : in    std_logic_vector(24 downto 0);
            I_data_in    : in    std_logic_vector(15 downto 0);
            O_data_out   : out   std_logic_vector(15 downto 0);
            I_rd_en      : in    std_logic;
            I_wr_en      : in    std_logic;
            I_byte_en    : in    std_logic_vector(1 downto 0);
            O_busy       : out   std_logic;
            O_valid      : out   std_logic;
            
            O_sdram_clk  : out   std_logic;
            O_sdram_cke  : out   std_logic;
            O_sdram_cs_n : out   std_logic;
            O_sdram_ras_n: out   std_logic;
            O_sdram_cas_n: out   std_logic;
            O_sdram_we_n : out   std_logic;
            O_sdram_addr : out   std_logic_vector(12 downto 0);
            O_sdram_ba   : out   std_logic_vector(1 downto 0);
            O_sdram_ldqm : out   std_logic;
            O_sdram_udqm : out   std_logic;
            IO_sdram_dq  : inout std_logic_vector(15 downto 0)
        );
    end component;

    -- Senales del bus
    signal reset       : std_logic;

    signal imem_addr   : word_t;
    signal imem_data   : word_t;

    signal dmem_addr   : word_t;
    signal dmem_wdata  : word_t;
    signal dmem_we     : std_logic;
    signal dmem_be     : std_logic_vector(3 downto 0);
    signal dmem_rdata  : word_t;

    -- Selectores de zona del bus de datos (combinacionales)
    signal sel_ram   : std_logic;
    signal sel_fb    : std_logic;
    signal sel_mmio  : std_logic;

    -- Selector retrasado un ciclo para multiplexar la lectura del dato
    -- (la BRAM/MMIO entregan el dato leido un ciclo despues de la
    -- presentacion de la direccion).
    signal sel_ram_d   : std_logic := '0';
    signal sel_fb_d    : std_logic := '0';
    signal sel_mmio_d  : std_logic := '0';

    -- Salidas de cada esclavo
    signal ram_rdata  : word_t;
    signal fb_rdata   : word_t;
    signal mmio_rdata : word_t;
    signal sdram_rdata: word_t;

    -- Senales para SDRAM
    signal sel_sdram  : std_logic;
    signal we_sdram   : std_logic;
    signal sdram_busy : std_logic;
    signal sdram_valid: std_logic;
    signal sdram_rd_en: std_logic;
    signal sdram_out16: std_logic_vector(15 downto 0);

    -- Senales de paleta del bridge MMIO al framebuffer
    signal pal_we    : std_logic;
    signal pal_index : std_logic_vector(3 downto 0);
    signal pal_data  : std_logic_vector(11 downto 0);

    -- Write enables locales para cada esclavo
    signal we_ram  : std_logic;
    signal we_fb   : std_logic;

    -- =========================================================================
    -- CONVERSION BYTE->WORD CENTRALIZADA
    --
    -- La CPU emite direcciones DE BYTE (estandar RISC-V): incrementar
    -- por 4 = la siguiente palabra. Las BRAMs son WORD-ADDRESSABLE:
    -- incrementar por 1 = la siguiente palabra.
    --
    -- Conversion: descartar los 2 bits bajos (offset de byte dentro de
    -- la palabra) y tomar los siguientes log2(N) bits como indice de
    -- palabra.
    --
    --   byte addr [31..0] -> bits [ADDR+1 .. 2] = indice de palabra
    --
    -- Para main_memory (ADDR_BITS=13, 8192 palabras = 32 KiB):
    --   word index = byte_addr[14:2]
    -- Para vga_framebuffer (FB_ADDR_BITS=13, 8192 palabras):
    --   word index = byte_addr[14:2]
    --
    -- Hacer esta conversion UNA SOLA VEZ aqui, y pasar el word index a
    -- las memorias, evita el bug en el que el byte_addr se interpreta
    -- directamente como word_addr (saltos de 4 en la BRAM fisica que
    -- crean los huecos visibles como "columnas" en el framebuffer).
    -- =========================================================================
    constant MAIN_ADDR_BITS : integer := 13;
    constant FB_ADDR_BITS   : integer := 13;

    signal imem_word_addr : std_logic_vector(MAIN_ADDR_BITS-1 downto 0);
    signal dmem_word_addr_main : std_logic_vector(MAIN_ADDR_BITS-1 downto 0);
    signal dmem_word_addr_fb   : std_logic_vector(FB_ADDR_BITS-1 downto 0);

    -- dbg_pc esta disponible por puerto del cpu_core pero no se enruta a
    -- pin fisico. Se deja como OPEN.

begin

    -- Conversion byte -> word: descarta bits [1:0] (offset de byte) y
    -- toma los siguientes ADDR_BITS bits como indice de palabra.
    imem_word_addr     <= imem_addr(MAIN_ADDR_BITS + 1 downto 2);
    dmem_word_addr_main <= dmem_addr(MAIN_ADDR_BITS + 1 downto 2);
    dmem_word_addr_fb   <= dmem_addr(FB_ADDR_BITS   + 1 downto 2);

    reset <= not I_reset_n;

    ---------------------------------------------------------------------------
    -- Decode de direccion del bus de datos
    ---------------------------------------------------------------------------
    -- 1. Address Decoding
    -- =========================================================================
    sel_ram   <= '1' when (dmem_addr(31 downto 28) = MAINMEM_BASE(31 downto 28)) else '0';
    sel_fb    <= '1' when (dmem_addr(31 downto 28) = FB_BASE(31 downto 28))      else '0';
    sel_sdram <= '1' when (dmem_addr(31 downto 28) = SDRAM_BASE(31 downto 28))   else '0';
    sel_mmio  <= '1' when (dmem_addr(31 downto 28) = MMIO_BASE(31 downto 28))    else '0';

    -- 2. Write Enables locales (se activan solo si we=1 y estamos en esa zona)
    -- =========================================================================
    we_ram    <= sel_ram   and dmem_we;
    we_fb     <= sel_fb    and dmem_we;
    we_sdram  <= sel_sdram and dmem_we;
    sdram_rd_en <= sel_sdram and (not dmem_we);

    -- Retraso de 1 ciclo para la fase de lectura
    sel_delay : process (I_clk_50)
    begin
        if rising_edge(I_clk_50) then
            if reset = '1' then
                sel_ram_d  <= '0';
                sel_fb_d   <= '0';
                sel_mmio_d <= '0';
            else
                sel_ram_d   <= sel_ram;
                sel_fb_d    <= sel_fb;
                sel_mmio_d  <= sel_mmio;
                
                -- La SDRAM no tiene un ciclo fijo de latencia, usa el O_valid
                -- Asi que no usamos _d, la capturamos dinamicamente.
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- CPU
    ---------------------------------------------------------------------------
    cpu_inst : cpu_core port map (
        I_clk        => I_clk_50,
        I_reset      => reset,
        O_imem_addr  => imem_addr,
        I_imem_data  => imem_data,
        O_dmem_addr  => dmem_addr,
        O_dmem_wdata => dmem_wdata,
        O_dmem_we    => dmem_we,
        O_dmem_be    => dmem_be,
        I_dmem_rdata => dmem_rdata,
        I_dmem_busy  => (sdram_busy and sel_sdram),
        I_irq        => '0',
        O_dbg_pc     => open
    );

    ---------------------------------------------------------------------------
    -- RAM principal: puerto A = instrucciones, puerto B = datos
    -- Solo se escribe el puerto B cuando el rango es RAM.
    ---------------------------------------------------------------------------
    ram_inst : main_memory
        generic map (
            ADDR_BITS => MAIN_ADDR_BITS,
            INIT_FILE => "program.mif"
        )
        port map (
            I_clk     => I_clk_50,
            -- Direcciones WORD-aligned, ya truncadas arriba
            I_addr_a  => imem_word_addr,
            O_data_a  => imem_data,
            I_addr_b  => dmem_word_addr_main,
            I_we_b    => we_ram,
            I_be_b    => dmem_be,
            I_wdata_b => dmem_wdata,
            O_data_b  => ram_rdata
        );

    ---------------------------------------------------------------------------
    -- Framebuffer VGA
    ---------------------------------------------------------------------------
    fb_inst : vga_framebuffer
        generic map (
            FB_ADDR_BITS => FB_ADDR_BITS
        )
        port map (
            I_clk_50    => I_clk_50,
            I_reset     => reset,
            I_we        => we_fb,
            -- Direccion WORD-aligned, ya truncada arriba
            I_addr      => dmem_word_addr_fb,
            I_wdata     => dmem_wdata,
            I_be        => dmem_be,
            O_rdata     => fb_rdata,
            I_pal_we    => pal_we,
            I_pal_index => pal_index,
            I_pal_data  => pal_data,
            O_hs        => O_vga_hs,
            O_vs        => O_vga_vs,
            O_r         => O_vga_r,
            O_g         => O_vga_g,
            O_b         => O_vga_b
        );

    ---------------------------------------------------------------------------
    -- Periferia MMIO
    ---------------------------------------------------------------------------
    mmio_inst : mmio_bridge port map (
        I_clk       => I_clk_50,
        I_reset     => reset,
        I_sel       => sel_mmio,
        I_we        => dmem_we,
        I_addr      => dmem_addr,
        I_wdata     => dmem_wdata,
        I_be        => dmem_be,
        O_rdata     => mmio_rdata,
        O_ledr      => O_ledr,
        I_sw        => I_sw,
        I_key       => I_key,
        O_hex0      => O_hex0,
        O_hex1      => O_hex1,
        O_hex2      => O_hex2,
        O_hex3      => O_hex3,
        O_hex4      => O_hex4,
        O_hex5      => O_hex5,
        O_uart_tx   => O_uart_tx,
        O_pal_we    => pal_we,
        O_pal_index => pal_index,
        O_pal_data  => pal_data,
        I_joystick  => I_joystick
    );

    ---------------------------------------------------------------------------
    -- Instancia del Controlador SDRAM
    -- Mapeado a 0x20000000. Por ahora expone interfaz de 16 bits (Half-Word).
    -- La direccion de byte de CPU dmem_addr(25 downto 1) = direccion 16-bit SDRAM.
    ---------------------------------------------------------------------------
    sdram_inst : sdram_controller port map (
        I_clk        => I_clk_50,
        I_reset      => reset,
        I_addr       => dmem_addr(25 downto 1),
        I_data_in    => dmem_wdata(31 downto 16) when dmem_addr(1) = '1' else dmem_wdata(15 downto 0),
        O_data_out   => sdram_out16,
        I_rd_en      => sdram_rd_en,
        I_wr_en      => we_sdram,
        I_byte_en    => dmem_be(3 downto 2) when dmem_addr(1) = '1' else dmem_be(1 downto 0),
        O_busy       => sdram_busy,
        O_valid      => sdram_valid,
        
        O_sdram_clk  => O_sdram_clk,
        O_sdram_cke  => O_sdram_cke,
        O_sdram_cs_n => O_sdram_cs_n,
        O_sdram_ras_n=> O_sdram_ras_n,
        O_sdram_cas_n=> O_sdram_cas_n,
        O_sdram_we_n => O_sdram_we_n,
        O_sdram_addr => O_sdram_addr,
        O_sdram_ba   => O_sdram_ba,
        O_sdram_ldqm => O_sdram_ldqm,
        O_sdram_udqm => O_sdram_udqm,
        IO_sdram_dq  => IO_sdram_dq
    );

    sdram_rdata <= sdram_out16 & sdram_out16;

    ---------------------------------------------------------------------------
    -- Mux de lectura del bus de datos. Se usa el selector retrasado porque
    -- los esclavos devuelven el dato un ciclo despues de la peticion.
    ---------------------------------------------------------------------------
    dmem_rdata <= ram_rdata   when sel_ram_d  = '1' else
                  fb_rdata    when sel_fb_d   = '1' else
                  mmio_rdata  when sel_mmio_d = '1' else
                  sdram_rdata when sel_sdram  = '1' else -- La SDRAM puede tomar varios ciclos
                  (others => '0');

end architecture Behavioral;
