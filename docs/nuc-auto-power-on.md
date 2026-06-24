# NUC Auto Power-On After AC Loss (June 2026)

## Problem

`tomnuc.home` does not power back on by itself after a power loss. When the June 2026 power crashes hit (see [nuc-power-crash-investigation-2026-06.md](nuc-power-crash-investigation-2026-06.md)), the box sat dead for ~40h until it was manually rebooted, because the board defaults to staying off when AC is restored. The whole cluster was down for that entire window for want of a power-on setting.

The obvious fix is the BIOS "power on after AC loss" option (`State After G3` / `Restore AC Power Loss`). This board doesn't expose it: it's a no-name AliExpress mini-PC (Whiskey Lake i7-8665U, Cannon Point-LP PCH, BIOS `GWHL4 5.04`), and the AMI setup menu has no such item anywhere (checked Power & Performance, Chipset / PCH-IO, Advanced, Boot).

## What controls this

The behaviour is a single hardware bit, `SLEEP_AFTER_POWER_FAIL`, bit 0 of the PCH's `GEN_PMCON_A` register. It lives in PMC MMIO at `PWRMBASE + 0x1020`. On this PCH `PWRMBASE` is the standard `0xFE000000`, so the register is at `0xFE001020`.

- bit 0 = 1 -> stay off (S5) when power returns. This is the board's default.
- bit 0 = 0 -> power on (S0) when power returns.

(Confirmed against coreboot's `soc/intel/cannonlake/include/soc/pmc.h`, which covers Whiskey Lake-U: `#define SLEEP_AFTER_POWER_FAIL (1 << 0)` in `GEN_PMCON_A` at offset `0x1020`.)

The register sits in the PCH suspend power well, backed by the CMOS battery, so the value persists through G3 (true power-off). That's what makes the recovery work: the PCH reads the bit at the moment AC returns, before BIOS or the OS run.

## Why a one-time write isn't enough

BIOS rewrites `GEN_PMCON_A` to its stay-off default (bit 0 = 1) on every POST. So a single write only survives until the next reboot, after which the board is back to not recovering. The fix has to re-apply the bit on every boot.

This was confirmed: clearing the bit, power-cycling, and re-reading after the box booted itself showed BIOS had set bit 0 back to 1.

## Solution

A systemd oneshot service clears bit 0 of `GEN_PMCON_A` on every boot. After that the live register is always in the power-on state, so any AC loss is recovered automatically: the bit persists through G3, the board powers on, BIOS resets the bit on POST, and the service re-clears it.

The write is a read-modify-write touching only bit 0 (`v & ~1`), so it can't disturb the other bits in the register. It uses `/dev/mem` mmap (the kernel has `CONFIG_IO_STRICT_DEVMEM=y`, but the PMC page isn't claimed by a driver so the mapping is allowed). `msync`/`flush()` is not used: it returns `EINVAL` on an MMIO mapping, and MMIO writes hit the device immediately without it.

Both files are version-controlled at [`Local-apps/nuc-auto-power-on/`](../Local-apps/nuc-auto-power-on/).

### `/usr/local/sbin/afterg3-poweron.py`

```python
#!/usr/bin/env python3
# Clear GEN_PMCON_A.SLEEP_AFTER_POWER_FAIL (PWRMBASE 0xFE000000 + 0x1020, bit 0)
# so the board powers on after AC loss. BIOS resets this each POST; re-apply at boot.
import mmap, struct
f = open('/dev/mem', 'r+b')
m = mmap.mmap(f.fileno(), 4096, offset=0xfe001000)
v = struct.unpack('<I', m[0x20:0x24])[0]
if v & 1:
    m[0x20:0x24] = struct.pack('<I', v & ~1)
```

### `/etc/systemd/system/afterg3-poweron.service`

```ini
[Unit]
Description=Power on after AC loss (clear PCH GEN_PMCON_A AFTERG3_EN)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/afterg3-poweron.py

[Install]
WantedBy=multi-user.target
```

### Install

```sh
sudo chmod 0755 /usr/local/sbin/afterg3-poweron.py
sudo systemctl daemon-reload
sudo systemctl enable --now afterg3-poweron.service
```

## Verification

```sh
# Read bit 0 of GEN_PMCON_A. 0 = power-on, 1 = stay-off.
sudo python3 -c "import mmap,struct; f=open('/dev/mem','r+b'); m=mmap.mmap(f.fileno(),4096,offset=0xfe001000); print('bit0', struct.unpack('<I',m[0x20:0x24])[0] & 1)"
```

Validated end to end on 24 June 2026:

1. Cleared bit 0, then did a clean `poweroff` and pulled AC. On restoring AC the board powered straight to S0 and booted with no button press. This proves the register/offset/bit are correct for this board.
2. After that boot, re-reading the register showed bit 0 back at 1, confirming BIOS resets it each POST (hence the per-boot service).
3. With the service enabled, the post-boot read shows `bit0 0`, so the service re-applies it.

## Caveats

- This only helps if the plug actually delivers power again. The June crashes were pinned to a NUC-internal power fault (likely PSU / DC input), so auto power-on gets the box to self-recover after a transient, but it does not fix a dying PSU. The real fix there is still a PSU swap and a UPS (see the investigation doc's next steps).
- `PWRMBASE = 0xFE000000` is assumed (the universal default for Skylake -> Comet Lake PCH). It couldn't be read off the BAR because BIOS hides the PMC device (`00:1f.2`) from PCI enumeration. The end-to-end power-cycle test confirms the address is right in practice.
- If the kernel or BIOS is ever updated, re-run the verification. A BIOS update could in theory move `PWRMBASE` or expose a real menu option (in which case the service becomes redundant).
