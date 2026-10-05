# kv260-sdcard-bench

A small, repeatable microSD benchmark for the AMD Kria KV260, used for
[Kria KV260 Notes, Part 3](https://sametdemir.com/).

The question it answers: once the board runs the card in UHS-I SDR104
(see [Part 1](https://sametdemir.com/linux/kria-kv260-notes-part-1-unlocking-the-kv260s-microsd-performance/)),
how much does the *card* matter, and for which kind of work?

## Method

Every card gets the same software: a fresh ext4 filesystem with an identical
copy of one Ubuntu 22.04.5 install (SDR104 override and `noatime` already in
place). The card is then booted in the KV260 and measured there, not in a PC
reader, because the ZynqMP SD controller is the host that matters.

All I/O is `direct=1`, `psync`, `iodepth=1`: one request at a time, no page
cache. That is how an operating system mostly uses a disk. Each job runs 3 times
and the median is reported.

| Job | Stands for |
|---|---|
| Sequential read/write, 1 MiB blocks, 2 GiB | boot, Snap images, big copies, downloads |
| 1 GiB file write (`fdatasync`) and read back | copying a video or dataset |
| 4 KiB random read, 30 s | loading libraries, starting apps |
| 4 KiB random write, 30 s | logs, caches, browser profile |
| 4 KiB random write + `fsync` per write, 30 s | `dpkg`, SQLite, git, journald |
| 4 KiB mixed 70/30, 45 s | general desktop use; same job as Part 1 |
| Extract and delete the Python stdlib tree (~25k real files) from RAM | `apt install`, `git clone`, builds |
| `systemd-analyze` over 3 reboots | boot time |

## Files

- `card-info.sh` — identity from sysfs (CID, manufacturer, date), the SD Status
  Register decoded into speed class / UHS grade / video class / app class, and the
  negotiated mode from debugfs. Runs on the board.
- `bench.sh <label> [runs]` — runs everything above on the board. Refuses to run
  unless the card is in SDR104 and `/` is on `mmcblk1p2`.
- `run-remote.sh <label> [host] [runs]` — from the PC: copy scripts, run
  `bench.sh`, reboot `runs` times for boot timing, fetch results into `results/<label>/`.
- `report.py [labels...]` — markdown tables and a summary chart from `results/`.

## Running it

```bash
# card is in the KV260 and booted
./run-remote.sh samsung-pro-plus ubuntu@kria 3
./report.py
```

## Scope

One board (KV260 Rev B), one image, kernel 5.15.0-1078-xilinx-zynqmp, three
cards. It is a comparison on this host, not a general card review. Numbers from a
PC reader or a different SoC will differ.
