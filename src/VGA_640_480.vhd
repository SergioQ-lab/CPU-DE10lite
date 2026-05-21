library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity VGA_640_480 is
	Port (
			CLK : in STD_LOGIC;
			RST : in STD_LOGIC :='0';
         Vsync : out  STD_LOGIC :='1';
         Hsync : out  STD_LOGIC :='1';
         vgaRed : out  STD_LOGIC_VECTOR (3 downto 0);
         vgaGreen : out  STD_LOGIC_VECTOR (3 downto 0);
         vgaBlue : out  STD_LOGIC_VECTOR (3 downto 0);
			pixVGAH : out integer range 0 to 640-1;
			pixVGAV : out integer range 0 to 480-1;
			Data : in STD_LOGIC_VECTOR (11 downto 0)
			);
end entity;

architecture Behavioral of VGA_640_480 is
-- constants for Synchro module
constant PAL:integer:=640;			--Pixels/Active Line (pixels)
constant PLD:integer:=800;			--Pixel/Line Divider
constant LAF:integer:=480;			--Lines/Active Frame (lines)
constant LFD:integer:=521;			--Line/Frame Divider
constant HPW:integer:=96;			--Horizontal synchro Pulse Width (pixels)
constant HFP:integer:=16;			--Horizontal synchro Front Porch (pixels)
--  constant HBP:integer:=48;		--Horizontal synchro Back Porch (pixels)
constant VPW:integer:=2;			--Verical synchro Pulse Width (lines)
constant VFP:integer:=10;			--Verical synchro Front Porch (lines)
--  constant VBP:integer:=29;		--Verical synchro Back Porch (lines)

-- Hor: 800, Ver: 521
-- frec = 25 MHz
-- Tpix = 1/frec = 0.04 us

-- Tline= Hor * Tpix = 32 us
-- Tframe = Ver * Tline = 16.672 ms
-- fframe = 1/Tframe = 59.98 Hz

-- HSini = PAL-1+HFP = 655
-- HSfin = PAL-1+HFP+HPW = 751
-- VSini = LAF-1+VFP = 489
-- VSfin = LAF-1+VFP+VPW = 491

-- signals for VGA
signal intHcnt: integer range 0 to PLD-1 :=0; 		-- PLD-1 - horizontal counter
signal intVcnt: integer range 0 to LFD-1 :=0; 		-- LFD-1 - verical counter

signal CLK_VGA : std_logic :='0';

begin

-- divide 50MHz clock to 25MHz
process(RST,CLK)
begin
	if RST='1' then
		CLK_VGA<='0'; 
	elsif rising_edge(CLK) then
		CLK_VGA<=not CLK_VGA; 
	end if;
end process;	   

process (RST,CLK_VGA)
begin
	if RST='1' then
		Hsync<='1';
		Vsync<='1';
		intHcnt<=0;
		intVcnt<=0;
	elsif rising_edge(CLK_VGA) then
		if intHcnt=PLD-1 then					-- 800-1 = 799
			intHcnt<=0;
			if intVcnt=LFD-1 then				-- 521-1 = 520
				intVcnt<=0;
			else
				intVcnt<=intVcnt+1;
			end if;
		else
			intHcnt<=intHcnt+1;
		end if;	

		-- Generates HS - active low
		if intHcnt=PAL-1+HFP then				-- 640-1+16 = 655
			Hsync<='0';			
		elsif intHcnt=PAL-1+HFP+HPW then 	-- 640-1+16+96 = 751	
			Hsync<='1';
		end if;

		-- Generates VS - active low
		if intVcnt=LAF-1+VFP then 				-- 480-1+10 = 489
			Vsync<='0';			
		elsif intVcnt=LAF-1+VFP+VPW then		-- 480-1+10+2 = 491
			Vsync<='1';
		end if;
	end if;
end process; 

pixVGAH<=intHcnt when intHcnt<PAL else 0;
pixVGAV<=intVcnt when intVcnt<LAF else 0;

process(intHcnt, intVcnt, data)
  begin
    if intHcnt < PAL and intVcnt < LAF then	-- in the active screen
			vgaRed <= data(11 downto 8);
			vgaGreen <= data(7 downto 4);
			vgaBlue <= data(3 downto 0);
    else
         vgaRed <= (others => '0');
         vgaGreen <= (others => '0');
         vgaBlue <= (others => '0');
    end if;
  end process;

end architecture;