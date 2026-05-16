--------------------------------------------------------------------------------
-- uart_tx.vhd
--
-- Transmisor UART simple, 8N1, sin paridad. Genera bit start, 8 bits de
-- datos LSB-first y bit stop a la velocidad fijada por el divisor
-- BAUD_DIVIDER (CLK_HZ / BAUD).
--
-- Por defecto: 50 MHz / 115200 = 434  -> BAUD_DIVIDER = 434.
--
-- Interfaz CPU
--   I_we = '1' + I_data = byte  -> arranca transmision
--   O_busy = '1' mientras hay un byte en vuelo
--
-- En el bridge MMIO se exponen dos registros:
--   UART_TX (offset 0x10): escritura del byte a enviar
--   UART_ST (offset 0x14): lectura, bit 0 = busy
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity uart_tx is
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
end entity uart_tx;

architecture Behavioral of uart_tx is

    type state_t is (IDLE, START, DATA, STOP_ST);
    signal state : state_t := IDLE;

    signal tick_cnt  : integer range 0 to BAUD_DIVIDER-1 := 0;
    signal bit_cnt   : integer range 0 to 7 := 0;
    signal shift_reg : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_int    : std_logic := '1';

begin

    proc : process (I_clk)
    begin
        if rising_edge(I_clk) then
            if I_reset = '1' then
                state     <= IDLE;
                tick_cnt  <= 0;
                bit_cnt   <= 0;
                shift_reg <= (others => '0');
                tx_int    <= '1';
            else
                case state is
                    when IDLE =>
                        tx_int <= '1';
                        if I_we = '1' then
                            shift_reg <= I_data;
                            tick_cnt  <= 0;
                            state     <= START;
                            tx_int    <= '0';
                        end if;
                    when START =>
                        if tick_cnt = BAUD_DIVIDER-1 then
                            tick_cnt <= 0;
                            bit_cnt  <= 0;
                            tx_int   <= shift_reg(0);
                            state    <= DATA;
                        else
                            tick_cnt <= tick_cnt + 1;
                        end if;
                    when DATA =>
                        if tick_cnt = BAUD_DIVIDER-1 then
                            tick_cnt  <= 0;
                            if bit_cnt = 7 then
                                tx_int <= '1';
                                state  <= STOP_ST;
                            else
                                shift_reg <= '0' & shift_reg(7 downto 1);
                                tx_int    <= shift_reg(1);
                                bit_cnt   <= bit_cnt + 1;
                            end if;
                        else
                            tick_cnt <= tick_cnt + 1;
                        end if;
                    when STOP_ST =>
                        if tick_cnt = BAUD_DIVIDER-1 then
                            tick_cnt <= 0;
                            state    <= IDLE;
                        else
                            tick_cnt <= tick_cnt + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;

    O_tx   <= tx_int;
    O_busy <= '0' when state = IDLE else '1';

end architecture Behavioral;
