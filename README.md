# `huawei-turbo-charge` — Turbo charge for Huawei laptops on Linux

Huawei PC Manager has a **Turbo charge** switch that Linux has no equivalent for. This tool turns it on, and keeps it on, from Linux.

On a MateBook X Pro 2024 (`VGHH-XX`) the same charger went from about **6 W to about 25 W** of net charge power with the switch on, measured twice with alternating on/off phases:

| Phase | Turbo charge | Net charge power |
|---|---|---|
| A1 | off | 5.8 W |
| B1 | **on** | **26.2 W** |
| A2 | off | 6.3 W |
| B2 | **on** | **24.9 W** |

Temperatures were the same in all four phases, so the low rate is a firmware policy that the switch lifts, not a heat limit. Huawei describes the feature as charging faster at the cost of the laptop and adapter warming up slightly.

> **Status: experimental.** Verified on one model only. See [Safety](#safety) before using it, and [Help us test](#help-us-test) if you have another Huawei laptop.

## Install

```bash
sudo ./install.sh              # command + udev rule + systemd unit, then enable
sudo ./install.sh --dry-run    # preview, changes nothing
sudo ./install.sh --uninstall
```

Everything installed is owned by root and not writable by users.

## Use

```bash
sudo huawei-turbo-charge status   # supported / turbo charge / charger
sudo huawei-turbo-charge on
sudo huawei-turbo-charge off
```

You normally do not run it by hand. The embedded controller (EC) clears the switch a few seconds after the charger is unplugged, so the installed udev rule re-enables it on every plug-in (verified on hardware: about one second after the charger is connected). The systemd unit also runs at boot and after resume (both verified on hardware on 2026-10-28). On a laptop that does not support the feature they do nothing.

## After a resume

Right after a resume the AC adapter can keep reporting itself offline even though the charger is connected, and the EC has already dropped the switch by then. An earlier version asked the adapter first and gave up silently, so Turbo charge stayed off until the charger was unplugged and plugged in again (observed on a MateBook X Pro 2024 after an `s2idle` resume, 2026-10-28).

`apply` now asks the EC directly: the EC knows whether a charger is connected, the adapter does not always know. The adapter is only consulted when a write fails, to tell a missing charger from a real failure.

## How it works

The firmware exposes a raw EC command channel through the Huawei WMI method `GI2C` (MFID `0x02`, SFID `0x10`). Turbo charge is EC command `0x02D3` with two data bytes:

| Data | Meaning | Result |
|---|---|---|
| `00 00` | is it supported? | `out[2] == 1` when supported |
| `00 01` | read the switch | `out[2] == 1` when on |
| `01 00` / `01 01` | switch off / on | `out[0] == 0` on success |

The commands are sent through the `huawei-wmi` kernel driver's debugfs interface (`/sys/kernel/debug/huawei-wmi/arg` then `call`), so no kernel module is built or loaded. The protocol was worked out by reading the ACPI tables of the machine and observing which calls the Windows software makes for this feature. No Huawei code or assets are included.

## Safety

- It writes one fixed EC command. Before any write it asks the firmware whether the feature is supported, the same check the Windows software makes, and does nothing when the answer is no.
- The firmware keeps enforcing its own protections (battery temperature cut-off, charge current limits). This tool does not touch the charge thresholds.
- Faster charging warms the laptop and the adapter. If your laptop already runs hot, fix that first.
- The setting does not persist in the firmware: unplugging the charger reverts it (verified), which is why it is re-applied on every plug-in.
- To undo everything: `sudo ./install.sh --uninstall`.
- This is not affiliated with Huawei. Use at your own risk.

Requires root, the `huawei_wmi` kernel driver, and debugfs. Kernel lockdown (Secure Boot setups that restrict debugfs) can block it.

## Help us test

The tool is only known to work on the MateBook X Pro 2024. If you have another Huawei or Honor laptop, run this and open an issue with the output:

```bash
sudo huawei-turbo-charge status
cat /sys/class/dmi/id/{sys_vendor,product_name,bios_version}
uname -r
```

`supported: no` on your model is a useful result too.

## Tests

```bash
tests/test_huawei_turbo_charge.sh
```

Dependency-free. The parser tests use real captures from the hardware; the policy tests mock the EC and cover AC detection, unsupported firmware, retries and failure.

## Roadmap

This is a user-space tool built on the driver's debugfs interface, which exists for debugging. The cleaner long-term home is a proper sysfs attribute in the in-kernel `huawei-wmi` driver. That is planned, but nothing has been proposed upstream yet.

## License

GPL-2.0-or-later. See [LICENSE](LICENSE).
