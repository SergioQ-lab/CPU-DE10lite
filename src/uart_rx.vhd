--------------------------------------------------------------------------------
-- uart_rx.vhd
--
-- Receptor UART simple, 8N1, sin paridad. Detecta el bit start, muestrea
-- 8 bits de datos LSB-first en el centro del bit, y bit stop a la velocidad 
-- fijada por el divisor BAUD_DIVIDER (CLK_HZ / BAUD).
--
-- Por defecto: 50 MHz / 115200 = 434  -> BAUD_DIVIDER = 434.
--
-- Interfaz CPU
--   O_valid pulsa a '1' durante un ciclo cuando se recibe un byte completo.
--   O_data contiene el byte recibido.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity uart_rx is
    generic (
        BAUD_DIVIDER : integer := 434
    );
    port (
        I_clk    : in  std_logic;
        I_reset  : in  std_logic;
        I_rx     : in  std_logic;
        O_data   : out std_logic_vector(7 downto 0);
        O_valid  : out std_logic
    );
end entity uart_rx;

architecture Behavioral of uart_rx is

    type state_t is (IDLE, START, DATA, STOP_ST);
    signal state : state_t := IDLE;

    signal tick_cnt  : integer range 0 to BAUD_DIVIDER-1 := 0;
    signal bit_cnt   : integer range 0 to 7 := 0;
    signal shift_reg : std_logic_vector(7 downto 0) := (others => '0');
    
    -- Sincronizadores para evitar metaestabilidad en la entrada asincrona
    signal rx_sync_1 : std_logic := '1';
    signal rx_sync_2 : std_logic := '1';

begin

    proc : process (I_clk)
    begin
        if rising_edge(I_clk) then
            if I_reset = '1' then
                state     <= IDLE;
                tick_cnt  <= 0;
                bit_cnt   <= 0;
                shift_reg <= (others => '0');
                rx_sync_1 <= '1';
                rx_sync_2 <= '1';
                O_valid   <= '0';
                O_data    <= (others => '0');
            else
                -- Shift de sincronizacion
                rx_sync_1 <= I_rx;
                rx_sync_2 <= rx_sync_1;
                
                -- Por defecto O_valid es 0
                O_valid <= '0';
                
                case state is
                    when IDLE =>
                        if rx_sync_2 = '0' then
                            -- Flanco de bajada detectado (posible Start bit)
                            tick_cnt <= 0;
                            state    <= START;
                        end if;
                        
                    when START =>
                        -- Esperamos a la mitad del bit para comprobar si es un start bit valido
                        if tick_cnt = (BAUD_DIVIDER / 2) - 1 then
                            if rx_sync_2 = '0' then
                                -- Start bit solido
                                tick_cnt <= 0;
                                bit_cnt  <= 0;
                                state    <= DATA;
                            else
                                -- Glitch, volvemos a IDLE
                                state <= IDLE;
                            end if;
                        else
                            tick_cnt <= tick_cnt + 1;
                        end if;
                        
                    when DATA =>
                        -- Esperamos un ciclo completo de bit
                        if tick_cnt = BAUD_DIVIDER - 1 then
                            tick_cnt <= 0;
                            -- Capturamos el bit (LSB first)
                            shift_reg <= rx_sync_2 & shift_reg(7 downto 1);
                            
                            if bit_cnt = 7 then
                                state <= STOP_ST;
                            else
                                bit_cnt <= bit_cnt + 1;
                            end if;
                        else
                            tick_cnt <= tick_cnt + 1;
                        end if;
                        
                    when STOP_ST =>
                        -- Esperamos el ciclo del bit de stop
                        if tick_cnt = BAUD_DIVIDER - 1 then
                            tick_cnt <= 0;
                            -- Asumimos que el bit de stop esta bien sin chequearlo estrictamente.
                            -- Sacamos el dato y levantamos el flag valid.
                            O_data  <= shift_reg;
                            O_valid <= '1';
                            state   <= IDLE;
                        else
                            tick_cnt <= tick_cnt + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;

end architecture Behavioral;
