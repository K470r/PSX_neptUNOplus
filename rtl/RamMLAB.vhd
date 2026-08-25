library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity RamMLAB is
   generic
   (
      width           :  natural;
      width_byteena   :  natural := 1;
      widthad         :  natural
   );
   port
   (
      inclock         : in std_logic;
      wren            : in std_logic;
      data            : in std_logic_vector(width-1 downto 0);
      wraddress       : in std_logic_vector(widthad-1 downto 0);
      rdaddress       : in std_logic_vector(widthad-1 downto 0);
      q               : out std_logic_vector(width-1 downto 0)
   );
end;

-- Inferred (not megafunction-instantiated) simple dual-port RAM: synchronous
-- write, combinational/unregistered read - same behavior the "MLAB" (LUT-RAM)
-- altdpram configuration this used to instantiate explicitly provided.
--
-- Changed from an explicit altdpram instance (ram_block_type => "MLAB",
-- rdaddress_reg/outdata_reg => "UNREGISTERED") because Cyclone IV GX has no
-- MLAB blocks and its M9K blocks cannot do unregistered/asynchronous reads,
-- so altdpram refused to elaborate for that device family ("Cyclone IV GX
-- supports only synchronous dual-port RAM"). Letting Quartus infer the RAM
-- instead keeps the exact same read/write timing and lets each device family
-- pick its own implementation (still LUT-RAM on Cyclone V, LE-based on
-- Cyclone IV GX) - this is a portability fix, not a NeptUNO+-specific change.
architecture rtl of RamMLAB is

   type ram_type is array (0 to (2**widthad)-1) of std_logic_vector(width-1 downto 0);
   signal ram : ram_type;

begin

   process(inclock)
   begin
      if rising_edge(inclock) then
         if wren = '1' then
            ram(to_integer(unsigned(wraddress))) <= data;
         end if;
      end if;
   end process;

   q <= ram(to_integer(unsigned(rdaddress)));

end rtl;
