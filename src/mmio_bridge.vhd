--------------------------------------------------------------------------------
-- mmio_bridge.vhd
--
-- Puente que mapea las direcciones MMIO en periferia concreta. Trabaja
-- en la region 0xF0000000..0xF00000FF. Los offsets soportados estan en
-- riscv_pkg.MMIO_OFF_*.
--
--   0x00  LEDR        WR     enciende los 10 LED rojos
--   0x04  SWITCHES    RD     lectura de los 10 switches
--   0x08  KEYS        RD     lectura de los dos pulsadores
--   0x0C  HEX         WR     cada nibble = un display (HEX5..HEX0)
--   0x10  UART_TX     WR     byte a transmitir
--   0x14  UART_ST     RD     bit 0 = busy
--   0x18  TIMER       RD     contador libre de 32 bits @50MHz
--   0x20..0x5F PALETTE WR    16 paletas de 12 bits (LSB)
--
-- El bridge es totalmente sincrono. Las lecturas tienen 1 ciclo de
-- latencia (igual que la memoria principal) para no romper el timing del
-- pipeline.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

library work;
use work.riscv_pkg.all;

entity mmio_bridge is
    port (
        I_clk     : in  std_logic;
        I_reset   : in  std_logic;
        -- bus desde la CPU (direccion ya filtrada a la region MMIO)
        I_sel     : in  std_logic;                     -- '1' = ciclo activo en MMIO
        I_we      : in  std_logic;
        I_addr    : in  word_t;
        I_wdata   : in  word_t;
        I_be      : in  std_logic_vector(3 downto 0);
        O_rdata   : out word_t;

        -- interfaz fisica de la DE10-Lite
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
        -- senales para el modulo VGA: actualizacion de paleta
        O_pal_we    : out std_logic;
        O_pal_index : out std_logic_vector(3 downto 0);
        O_pal_data  : out std_logic_vector(11 downto 0);
        I_joystick  : in  std_logic_vector(6 downto 0)
    );
end entity mmio_bridge;

architecture Behavioral of mmio_bridge is

    component uart_tx is
        generic (
            BAUD_DIVIDER : integer := 434
        );
        port (
            I_clk    : in  std_logic;
            I_reset  : in  std_logic;
            I_we     : in  std_logic;
            I_data   : in  std_logic_vector(7 downto 0);
            O_busy   : out std_logic;
            O_tx     : out std_logic
        );
    end component;

    component seven_seg is
        port (
            I_value : in  std_logic_vector(3 downto 0);
            O_seg   : out std_logic_vector(7 downto 0)
        );
    end component;

    -- Registros mapeados
    signal r_ledr : std_logic_vector(9 downto 0) := (others => '0');
    signal r_hex  : std_logic_vector(23 downto 0) := (others => '0'); -- 6 nibbles

    -- UART
    signal uart_we   : std_logic := '0';
    signal uart_byte : std_logic_vector(7 downto 0) := (others => '0');
    signal uart_busy : std_logic;

    -- Timer libre
    signal r_timer : unsigned(31 downto 0) := (others => '0');

    -- Paleta
    signal pal_we_int    : std_logic := '0';
    signal pal_index_int : std_logic_vector(3 downto 0) := (others => '0');
    signal pal_data_int  : std_logic_vector(11 downto 0) := (others => '0');

    -- offset dentro de la region MMIO (8 bits bajos)
    signal off : std_logic_vector(7 downto 0);

begin

    off <= I_addr(7 downto 0);

    ---------------------------------------------------------------------------
    -- Periferia simple: pulsa UART_TX si llega una escritura al offset 0x10
    ---------------------------------------------------------------------------
    uart_inst : uart_tx
        generic map (
            BAUD_DIVIDER => 434  -- 50 MHz / 115200 baudios
        )
        port map (
            I_clk   => I_clk,
            I_reset => I_reset,
            I_we    => uart_we,
            I_data  => uart_byte,
            O_busy  => uart_busy,
            O_tx    => O_uart_tx
        );

    ---------------------------------------------------------------------------
    -- Seven-segment encoders (uno por display). Toman cada nibble del
    -- registro r_hex y producen el patron del display.
    ---------------------------------------------------------------------------
    h0 : seven_seg port map (I_value => r_hex(3  downto  0), O_seg => O_hex0);
    h1 : seven_seg port map (I_value => r_hex(7  downto  4), O_seg => O_hex1);
    h2 : seven_seg port map (I_value => r_hex(11 downto  8), O_seg => O_hex2);
    h3 : seven_seg port map (I_value => r_hex(15 downto 12), O_seg => O_hex3);
    h4 : seven_seg port map (I_value => r_hex(19 downto 16), O_seg => O_hex4);
    h5 : seven_seg port map (I_value => r_hex(23 downto 20), O_seg => O_hex5);

    ---------------------------------------------------------------------------
    -- Logica de escritura/lectura
    --
    -- La escritura es sincrona; cada registro se actualiza al ver su offset.
    -- Para registros mas pequenos que 32 bits, se ignora la parte alta.
    ---------------------------------------------------------------------------
    proc : process (I_clk)
    begin
        if rising_edge(I_clk) then
            -- pulsos de un ciclo
            uart_we    <= '0';
            pal_we_int <= '0';

            -- timer siempre cuenta
            r_timer <= r_timer + 1;

            if I_reset = '1' then
                r_ledr  <= (others => '0');
                r_hex   <= (others => '0');
                r_timer <= (others => '0');
            elsif I_sel = '1' and I_we = '1' then
                case off is
                    when MMIO_OFF_LEDR =>
                        if I_be(0) = '1' then
                            r_ledr(7 downto 0) <= I_wdata(7 downto 0);
                        end if;
                        if I_be(1) = '1' then
                            r_ledr(9 downto 8) <= I_wdata(9 downto 8);
                        end if;

                    when MMIO_OFF_HEX =>
                        if I_be(0) = '1' then
                            r_hex(7 downto 0)   <= I_wdata(7 downto 0);
                        end if;
                        if I_be(1) = '1' then
                            r_hex(15 downto 8)  <= I_wdata(15 downto 8);
                        end if;
                        if I_be(2) = '1' then
                            r_hex(23 downto 16) <= I_wdata(23 downto 16);
                        end if;

                    when MMIO_OFF_UART_TX =>
                        if I_be(0) = '1' then
                            uart_byte <= I_wdata(7 downto 0);
                            uart_we   <= '1';
                        end if;

                    when others =>
                        -- Region de paleta: 0x20..0x5F, 4 bytes por entrada
                        -- Cada entrada usa los 12 bits bajos.
                        if (unsigned(off) >= 16#20#) and (unsigned(off) < 16#60#) then
                            pal_index_int <= off(5 downto 2);
                            pal_data_int  <= I_wdata(11 downto 0);
                            pal_we_int    <= '1';
                        end if;
                end case;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Lectura combinacional segun offset. Se entrega con 1 ciclo de retardo
    -- en el siguiente proceso para coherencia con el resto del bus.
    ---------------------------------------------------------------------------
    read_proc : process (I_clk)
    begin
        if rising_edge(I_clk) then
            case off is
                when MMIO_OFF_LEDR     => O_rdata <= X"00000" & "00" & r_ledr;
                when MMIO_OFF_SWITCHES => O_rdata <= X"00000" & "00" & I_sw;
                when MMIO_OFF_KEYS     => O_rdata <= X"0000000" & "00" & I_key;
                when MMIO_OFF_HEX      => O_rdata <= X"00" & r_hex;
                when MMIO_OFF_UART_ST  => O_rdata <= X"0000000" & "000" & uart_busy;
                when MMIO_OFF_TIMER    => O_rdata <= std_logic_vector(r_timer);
                when MMIO_OFF_JOYSTICK => O_rdata <= X"000000" & '0' & I_joystick;
                when others            => O_rdata <= (others => '0');
            end case;
        end if;
    end process;

    O_ledr      <= r_ledr;
    O_pal_we    <= pal_we_int;
    O_pal_index <= pal_index_int;
    O_pal_data  <= pal_data_int;

end architecture Behavioral;
