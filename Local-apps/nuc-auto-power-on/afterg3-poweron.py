#!/usr/bin/env python3
# Clear GEN_PMCON_A.SLEEP_AFTER_POWER_FAIL (PWRMBASE 0xFE000000 + 0x1020, bit 0)
# so the board powers on after AC loss. BIOS resets this each POST; re-apply at boot.
import mmap, struct
f = open('/dev/mem', 'r+b')
m = mmap.mmap(f.fileno(), 4096, offset=0xfe001000)
v = struct.unpack('<I', m[0x20:0x24])[0]
if v & 1:
    m[0x20:0x24] = struct.pack('<I', v & ~1)
