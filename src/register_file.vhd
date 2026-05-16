--------------------------------------------------------------------------------
-- register_file.vhd
--
-- Banco de 32 registros de 32 bits con dos puertos de lectura combinacional
-- y un puerto de escritura sincrono. El registro x0 esta cableado a cero,
-- por lo que cualquier escritura sobre la direccion 0 se ignora.
--
-- Para que el banco haga forwarding "write-through" interno (RaW en el mismo
-- ciclo) se realiza un bypass combinacional: si la direccion leida coincide
-- con la direccion del puerto de escritura activo, se devuelve el dato a
-- escribir en lugar del contenido almacenado. Esto evita que el pipeline
-- tenga que esperar un ciclo extra cuando la etapa WB escribe el mismo
-- registro que ID acaba de leer.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

library work;
use work.riscv_pkg.all;

entity register_file is
    port (
        I_clk    : in  std_logic;
        I_reset  : in  std_logic;
        -- Puerto de escritura
        I_we     : in  std_logic;
        I_rd     : in  std_logic_vector(4 downto 0);
        I_wdata  : in  word_t;
        -- Puertos de lectura
        I_rs1    : in  std_logic_vector(4 downto 0);
        I_rs2    : in  std_logic_vector(4 downto 0);
        O_rs1d   : out word_t;
        O_rs2d   : out word_t
    );
end entity register_file;

architecture Behavioral of register_file is

    type regfile_t is array (0 to 31) of word_t;
    signal regs : regfile_t := (others => (others => '0'));

    signal rs1_raw : word_t;
    signal rs2_raw : word_t;

begin

    -- Escritura sincrona; x0 siempre permanece a 0
    write_proc : process (I_clk)
    begin
        if rising_edge(I_clk) then
            if I_reset = '1' then
                regs <= (others => (others => '0'));
            elsif I_we = '1' and I_rd /= "00000" then
                regs(to_integer(unsigned(I_rd))) <= I_wdata;
            end if;
        end if;
    end process;

    -- Lectura combinacional directa del array
    rs1_raw <= regs(to_integer(unsigned(I_rs1)));
    rs2_raw <= regs(to_integer(unsigned(I_rs2)));

    -- Bypass interno: si en el mismo ciclo se escribe el mismo registro,
    -- devolvemos el dato que se va a escribir. Esto elimina la necesidad
    -- de un forwarding adicional desde la etapa WB hacia ID.
    O_rs1d <= (others => '0') when I_rs1 = "00000" else
              I_wdata          when (I_we = '1' and I_rd = I_rs1) else
              rs1_raw;
    O_rs2d <= (others => '0') when I_rs2 = "00000" else
              I_wdata          when (I_we = '1' and I_rd = I_rs2) else
              rs2_raw;

end architecture Behavioral;
