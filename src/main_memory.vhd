--------------------------------------------------------------------------------
-- main_memory.vhd
--
-- Memoria principal del SoC implementada usando la primitiva altsyncram
-- de Intel/Altera. Esto evita los problemas de inferencia automatica de
-- BRAM en Quartus Lite con patrones complejos (TDP + byte enable + MIF
-- init), que estaban haciendo que la RAM se sintetizara como flip-flops
-- y reventaba el chip (>500K registros).
--
-- Configuracion: BIDIR_DUAL_PORT (True Dual Port)
--   * Puerto A: lectura (instruction fetch). wren_a fijado a '0'.
--   * Puerto B: lectura + escritura con byte enable (data bus).
--   * Reloj unico, M9K, init_file = "program.mif".
--
-- Capacidad: 2^ADDR_BITS palabras de 32 bits.
-- Con ADDR_BITS=13 -> 8192 palabras = 32 KiB.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

library altera_mf;
use altera_mf.altera_mf_components.all;

library work;
use work.riscv_pkg.all;

entity main_memory is
    generic (
        ADDR_BITS : integer := 13;
        INIT_FILE : string  := "program.mif"
    );
    port (
        I_clk     : in  std_logic;
        I_addr_a  : in  word_t;
        O_data_a  : out word_t;
        I_addr_b  : in  word_t;
        I_we_b    : in  std_logic;
        I_be_b    : in  std_logic_vector(3 downto 0);
        I_wdata_b : in  word_t;
        O_data_b  : out word_t
    );
end entity main_memory;

architecture Behavioral of main_memory is

    signal addr_a_s : std_logic_vector(ADDR_BITS-1 downto 0);
    signal addr_b_s : std_logic_vector(ADDR_BITS-1 downto 0);

    -- Constante de relleno para el puerto A (no escribe)
    constant ZERO_WORD : std_logic_vector(31 downto 0) := (others => '0');

begin

    -- Toma directamente los ADDR_BITS bits que indexan palabras
    -- (los 2 bits bajos son el offset de byte y se ignoran).
    addr_a_s <= I_addr_a(ADDR_BITS+1 downto 2);
    addr_b_s <= I_addr_b(ADDR_BITS+1 downto 2);

    ram : altsyncram
        generic map (
            operation_mode             => "BIDIR_DUAL_PORT",
            width_a                    => 32,
            widthad_a                  => ADDR_BITS,
            numwords_a                 => 2**ADDR_BITS,
            width_b                    => 32,
            widthad_b                  => ADDR_BITS,
            numwords_b                 => 2**ADDR_BITS,
            -- Byte enable: altsyncram exige width_byteena = width / byte_size
            -- en ambos puertos. El puerto A no escribe pero el parametro
            -- debe valer 4 igual que el B.
            width_byteena_a            => 4,
            width_byteena_b            => 4,
            byte_size                  => 8,
            -- Inicializacion via MIF
            init_file                  => INIT_FILE,
            init_file_layout           => "PORT_A",
            -- Sincronizacion: todo al reloj 0
            address_reg_b              => "CLOCK0",
            indata_reg_b               => "CLOCK0",
            wrcontrol_wraddress_reg_b  => "CLOCK0",
            byteena_reg_b              => "CLOCK0",
            -- Salidas sin registro extra: latencia = 1 ciclo
            outdata_reg_a              => "UNREGISTERED",
            outdata_reg_b              => "UNREGISTERED",
            -- Read-during-write: devuelve dato viejo (mas seguro)
            read_during_write_mode_port_a       => "OLD_DATA",
            read_during_write_mode_port_b       => "OLD_DATA",
            read_during_write_mode_mixed_ports  => "OLD_DATA",
            -- Forzar bloque M9K en MAX10
            ram_block_type             => "M9K",
            intended_device_family     => "MAX 10",
            lpm_type                   => "altsyncram"
        )
        port map (
            clock0    => I_clk,
            -- Puerto A: solo lectura
            address_a => addr_a_s,
            wren_a    => '0',
            byteena_a => "0000",
            data_a    => ZERO_WORD,
            q_a       => O_data_a,
            -- Puerto B: lectura + escritura
            address_b => addr_b_s,
            wren_b    => I_we_b,
            byteena_b => I_be_b,
            data_b    => I_wdata_b,
            q_b       => O_data_b
        );

end architecture Behavioral;
