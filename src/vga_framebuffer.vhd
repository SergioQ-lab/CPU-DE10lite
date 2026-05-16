--------------------------------------------------------------------------------
-- vga_framebuffer.vhd
--
-- Controlador VGA con framebuffer indexado por paleta de 16 colores.
-- Usa altsyncram en modo BIDIR_DUAL_PORT (True Dual Port) para garantizar
-- que Quartus mete el framebuffer en BRAM M9K y no en flip-flops.
--
--   Puerto A: lectura (barrido VGA, wren_a fijo a '0')
--   Puerto B: lectura + escritura con byte enable (acceso de la CPU,
--             permite read-modify-write para putpixel sub-word)
--
-- Resolucion nativa: 320 x 200 (Doom). Cada pixel = nibble de 4 bits
-- indice a la paleta. 8 pixeles por palabra de 32 bits => 8000 palabras
-- utiles, allocadas como 8192 (ADDR_BITS = 13) para indexacion limpia.
--
-- Salida fisica: 640 x 480. El framebuffer se duplica 2x en H y V
-- ocupando 640x400, con 40 px de banda negra arriba y abajo.
--
-- IMPORTANTE: el puerto B (CPU) recibe DIRECCION DE PALABRA, NO de byte.
-- La conversion byte->word (descartar los 2 LSBs) se hace EXPLICITAMENTE
-- en soc.vhd. Asi este modulo no puede meter la pata con el alineado.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

library altera_mf;
use altera_mf.altera_mf_components.all;

library work;
use work.riscv_pkg.all;

entity vga_framebuffer is
    generic (
        FB_ADDR_BITS : integer := 13   -- 2^13 = 8192 palabras de FB
    );
    port (
        I_clk_50  : in  std_logic;
        I_reset   : in  std_logic;
        -- Bus de lectura/escritura desde la CPU (32 bits + BE de 4).
        -- I_addr es DIRECCION DE PALABRA (FB_ADDR_BITS bits), NO byte.
        I_we      : in  std_logic;
        I_addr    : in  std_logic_vector(FB_ADDR_BITS-1 downto 0);
        I_wdata   : in  word_t;
        I_be      : in  std_logic_vector(3 downto 0);
        O_rdata   : out word_t;
        -- Escritura de paleta (16 entradas de 12 bits cada una)
        I_pal_we     : in  std_logic;
        I_pal_index  : in  std_logic_vector(3 downto 0);
        I_pal_data   : in  std_logic_vector(11 downto 0);
        -- Salidas VGA fisicas
        O_hs      : out std_logic;
        O_vs      : out std_logic;
        O_r       : out std_logic_vector(3 downto 0);
        O_g       : out std_logic_vector(3 downto 0);
        O_b       : out std_logic_vector(3 downto 0)
    );
end entity vga_framebuffer;

architecture Behavioral of vga_framebuffer is

    component VGA_640_480 is
        port (
            CLK     : in  STD_LOGIC;
            RST     : in  STD_LOGIC := '0';
            Vsync   : out STD_LOGIC := '1';
            Hsync   : out STD_LOGIC := '1';
            vgaRed   : out STD_LOGIC_VECTOR(3 downto 0);
            vgaGreen : out STD_LOGIC_VECTOR(3 downto 0);
            vgaBlue  : out STD_LOGIC_VECTOR(3 downto 0);
            pixVGAH : out integer range 0 to 640-1;
            pixVGAV : out integer range 0 to 480-1;
            Data    : in  STD_LOGIC_VECTOR(11 downto 0)
        );
    end component;

    -- FB_ADDR_BITS viene ahora del generic
    constant FB_WORDS     : integer := 2**FB_ADDR_BITS;
    constant FB_W         : integer := 320;
    constant FB_H         : integer := 200;
    constant V_BORDER     : integer := (480 - FB_H*2) / 2;

    ---------------------------------------------------------------------------
    -- Paleta de 16 entradas xRGB (logica, no BRAM porque son solo 192 bits)
    ---------------------------------------------------------------------------
    type palette_t is array (0 to 15) of std_logic_vector(11 downto 0);
    signal palette : palette_t := (
        0  => X"000",  1  => X"700",  2  => X"070",  3  => X"770",
        4  => X"007",  5  => X"707",  6  => X"077",  7  => X"AAA",
        8  => X"555",  9  => X"F00",  10 => X"0F0",  11 => X"FF0",
        12 => X"00F",  13 => X"F0F",  14 => X"0FF",  15 => X"FFF"
    );
    attribute ramstyle : string;
    attribute ramstyle of palette : signal is "logic";

    ---------------------------------------------------------------------------
    -- Senales del barrido VGA
    ---------------------------------------------------------------------------
    signal vga_h         : integer range 0 to 639;
    signal vga_v         : integer range 0 to 479;
    signal in_active     : std_logic;
    signal pix_x         : integer range 0 to FB_W-1;
    signal pix_y         : integer range 0 to FB_H-1;

    signal rd_word_addr  : std_logic_vector(FB_ADDR_BITS-1 downto 0);
    signal rd_nibble_off : unsigned(2 downto 0);
    signal rd_nibble_off_r : unsigned(2 downto 0);

    signal fb_word_read  : std_logic_vector(31 downto 0);
    signal pixel_nibble  : std_logic_vector(3 downto 0);
    signal pixel_color   : std_logic_vector(11 downto 0);

    -- Para el puerto B (CPU read/write)
    signal wr_word_addr  : std_logic_vector(FB_ADDR_BITS-1 downto 0);
    signal fb_q_b        : std_logic_vector(31 downto 0);
    -- Byte enable forzado a "1111" durante lecturas para que altsyncram
    -- devuelva la palabra completa (algunas versiones aplican byteena
    -- tambien en lecturas; con "1111" siempre devuelve todo).
    signal fb_byteena    : std_logic_vector(3 downto 0);
    constant ZERO_WORD : std_logic_vector(31 downto 0) := (others => '0');

begin

    ---------------------------------------------------------------------------
    -- VGA timing
    ---------------------------------------------------------------------------
    vga_timing : VGA_640_480 port map (
        CLK      => I_clk_50,
        RST      => I_reset,
        Vsync    => O_vs,
        Hsync    => O_hs,
        vgaRed   => O_r,
        vgaGreen => O_g,
        vgaBlue  => O_b,
        pixVGAH  => vga_h,
        pixVGAV  => vga_v,
        Data     => pixel_color
    );

    ---------------------------------------------------------------------------
    -- Conversion (vga_h, vga_v) -> (pix_x, pix_y)
    ---------------------------------------------------------------------------
    pix_x <= vga_h / 2;
    in_active <= '1' when (vga_v >= V_BORDER) and (vga_v < V_BORDER + FB_H*2) else '0';
    pix_y <= (vga_v - V_BORDER) / 2 when in_active = '1' else 0;

    ---------------------------------------------------------------------------
    -- Calculo de direccion de palabra y offset de nibble.
    --   word = pix_y * 40 + pix_x / 8
    --   pix_y * 40 = (pix_y << 5) + (pix_y << 3)  (sin divisor)
    ---------------------------------------------------------------------------
    addr_calc : process (pix_x, pix_y)
        variable v_py    : unsigned(12 downto 0);
        variable v_row40 : unsigned(12 downto 0);
        variable v_pxw   : unsigned(12 downto 0);
        variable v_word  : unsigned(12 downto 0);
    begin
        v_py    := to_unsigned(pix_y, 13);
        v_row40 := resize(shift_left(v_py, 5) + shift_left(v_py, 3), 13);
        v_pxw   := to_unsigned(pix_x / 8, 13);
        v_word  := v_row40 + v_pxw;
        rd_word_addr  <= std_logic_vector(v_word);
        rd_nibble_off <= to_unsigned(pix_x mod 8, 3);
    end process;

    ---------------------------------------------------------------------------
    -- Latch del offset de nibble para alinearlo con el dato leido del BRAM
    -- (la lectura tiene 1 ciclo de latencia).
    ---------------------------------------------------------------------------
    nibble_latch : process (I_clk_50)
    begin
        if rising_edge(I_clk_50) then
            rd_nibble_off_r <= rd_nibble_off;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- BRAM dual-port (lectura/escritura) via altsyncram
    --
    -- I_addr ya es DIRECCION DE PALABRA (truncada en soc.vhd). Aqui se
    -- conecta directamente al puerto B del altsyncram sin mas slicing.
    ---------------------------------------------------------------------------
    wr_word_addr <= I_addr;

    -- Forzar byte enable a "1111" durante lecturas
    fb_byteena <= I_be when I_we = '1' else "1111";

    fb_ram : altsyncram
        generic map (
            -- BIDIR_DUAL_PORT: puerto A para barrido VGA (solo lee),
            -- puerto B para la CPU (lee y escribe con byte enable).
            operation_mode             => "BIDIR_DUAL_PORT",
            width_a                    => 32,
            widthad_a                  => FB_ADDR_BITS,
            numwords_a                 => FB_WORDS,
            width_b                    => 32,
            widthad_b                  => FB_ADDR_BITS,
            numwords_b                 => FB_WORDS,
            width_byteena_a            => 4,
            width_byteena_b            => 4,
            byte_size                  => 8,
            init_file                  => "UNUSED",
            init_file_layout           => "PORT_A",
            address_reg_b              => "CLOCK0",
            indata_reg_b               => "CLOCK0",
            wrcontrol_wraddress_reg_b  => "CLOCK0",
            byteena_reg_b              => "CLOCK0",
            outdata_reg_a              => "UNREGISTERED",
            outdata_reg_b              => "UNREGISTERED",
            read_during_write_mode_port_a       => "OLD_DATA",
            read_during_write_mode_port_b       => "OLD_DATA",
            read_during_write_mode_mixed_ports  => "OLD_DATA",
            ram_block_type             => "M9K",
            intended_device_family     => "MAX 10",
            lpm_type                   => "altsyncram"
        )
        port map (
            clock0    => I_clk_50,
            -- Puerto A: lectura para barrido VGA. wren='0' siempre.
            address_a => rd_word_addr,
            wren_a    => '0',
            byteena_a => "1111",
            data_a    => ZERO_WORD,
            q_a       => fb_word_read,
            -- Puerto B: lectura + escritura desde CPU.
            address_b => wr_word_addr,
            wren_b    => I_we,
            byteena_b => fb_byteena,
            data_b    => I_wdata,
            q_b       => fb_q_b
        );

    -- Selector de nibble
    pixel_nibble <=
        fb_word_read(3  downto  0) when rd_nibble_off_r = "000" else
        fb_word_read(7  downto  4) when rd_nibble_off_r = "001" else
        fb_word_read(11 downto  8) when rd_nibble_off_r = "010" else
        fb_word_read(15 downto 12) when rd_nibble_off_r = "011" else
        fb_word_read(19 downto 16) when rd_nibble_off_r = "100" else
        fb_word_read(23 downto 20) when rd_nibble_off_r = "101" else
        fb_word_read(27 downto 24) when rd_nibble_off_r = "110" else
        fb_word_read(31 downto 28);

    pixel_color <= palette(to_integer(unsigned(pixel_nibble))) when in_active = '1'
                   else X"000";

    -- Salida de lectura para la CPU (read-back del framebuffer).
    -- Permite que putpixel en C use read-modify-write sobre la palabra.
    O_rdata <= fb_q_b;

    ---------------------------------------------------------------------------
    -- Escritura de paleta
    ---------------------------------------------------------------------------
    palette_proc : process (I_clk_50)
    begin
        if rising_edge(I_clk_50) then
            if I_pal_we = '1' then
                palette(to_integer(unsigned(I_pal_index))) <= I_pal_data;
            end if;
        end if;
    end process;

end architecture Behavioral;
