## SN-360 Firmware with 57k Ultraspeed and bugfixes


Original SN-360 firmware by Slawomir Nienaltowski (Atari Studio) 1992  
This firmware by: Michal Szwaczko (WireLabs) 1997,1998,2006-2009  
Reverse-engineered from bare metal, cracked, fixed and enhanced  
Some comments or code annotations may be completely wrong, since they come 
from original disassembly back from the 1998-1999 when I had no idea of the real 
workings of 8051 and FDCs :)))  

Also, this is not a complete rewrite of the original Nienaltowski's code 
just a reverse + hacks. Still, pity they hadn't done same in 1990's :) 

**Thanks to:** _drac030, seban, trub_

### Drive Memory map:
0x0000-0x0003 - 2797 Registers (status/command, track, sector, data)  
0x8000-0x80FF - internal drive buffer, data from drive/sectors  
0x8100-0x81FF - external buffer , anything read from atari  

### Fixes:
* fixed '80 tracks in PERCOM' bug, for 360k 5.25 drives
* fixed '0xFF byte formatting' bug for DD/DSDD
* some code cleanups, optimizations, and code-flow clarifications

### New features:
* support for US DOUBLER compatible ultra speed (57kbaud,$08) 
* ultraspeed sector skew, and FORMAT_CUSTOM command for SDX

### TODO:
* support for 3.5 720k drives in both 9/512 and 18/256 track formats
* make format_custom really set up sector skew, now it's just faking it :)
* format real SD (just for a laugh)
* romdisk?



