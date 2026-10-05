#!/usr/bin/env bash
# Print identity and negotiated mode of the microSD card in the KV260 slot (mmc1).
# Output is JSON on stdout. Runs on the board; needs sudo for debugfs.
set -euo pipefail

HOST=/sys/class/mmc_host/mmc1
CARD=$(ls -d "$HOST"/mmc1:* 2>/dev/null | head -1)
[[ -n "$CARD" ]] || { echo "no card on mmc1" >&2; exit 1; }

sudo mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
IOS=$(sudo cat /sys/kernel/debug/mmc1/ios)

python3 - "$CARD" "$IOS" <<'PY'
import json, sys, pathlib, re
card = pathlib.Path(sys.argv[1]); ios_txt = sys.argv[2]
rd = lambda f: (card / f).read_text().strip()

# SD Status Register (512 bits). bit b lives in byte (511-b)//8, MSB first.
ssr = bytes.fromhex(rd("ssr"))
def bits(hi, lo):
    v = int.from_bytes(ssr, "big")
    return (v >> lo) & ((1 << (hi - lo + 1)) - 1)

speed_class = {0: "0", 1: "2", 2: "4", 3: "6", 4: "10"}.get(bits(447, 440), "?")
au_code = bits(431, 428)
au_size = {1:"16K",2:"32K",3:"64K",4:"128K",5:"256K",6:"512K",7:"1M",8:"2M",9:"4M",0xA:"8M",0xB:"12M",0xC:"16M",0xD:"24M",0xE:"32M",0xF:"64M"}.get(au_code, "?")
uhs_grade = bits(399, 396)              # 0 = none, 1 = U1, 3 = U3
video_class = bits(391, 384)            # 0 = none, else V<n>
app_class = bits(351, 348)              # 0 = none, 1 = A1, 2 = A2
discard = bits(313, 313); fule = bits(312, 312)

ios = {}
for line in ios_txt.splitlines():
    k, _, v = line.partition(":")
    ios[k.strip()] = v.strip()
m = re.search(r"\(([^)]*)\)", ios.get("timing spec", ""))

manf = {0x03: "SanDisk", 0x1b: "Samsung", 0x27: "Phison", 0x74: "Transcend", 0x9f: "Kingston/Taiwan", 0x02: "Toshiba/Kioxia"}
mid = int(rd("manfid"), 16)

info = {
    "name": rd("name"), "manfid": rd("manfid"), "manufacturer": manf.get(mid, "unknown"),
    "oemid": rd("oemid"), "date": rd("date"), "serial": rd("serial"),
    "hwrev": rd("hwrev"), "fwrev": rd("fwrev"),
    "size_gib": round(int(open("/sys/block/mmcblk1/size").read()) * 512 / 2**30, 1),
    "ssr": {
        "speed_class": speed_class, "uhs_grade": f"U{uhs_grade}" if uhs_grade else "none",
        "video_class": f"V{video_class}" if video_class else "none",
        "app_class": f"A{app_class}" if app_class else "none",
        "au_size": au_size, "discard": bool(discard), "fule": bool(fule),
    },
    "mode": {"timing": m.group(1) if m else ios.get("timing spec"),
             "clock_hz": int(ios.get("actual clock", "0").split()[0]),
             "signal_voltage": ios.get("signal voltage"), "bus_width": ios.get("bus width")},
    "kernel": open("/proc/version").read().split()[2],
    "model": open("/proc/device-tree/model", "rb").read().rstrip(b"\0").decode(),
}
print(json.dumps(info, indent=2))
PY
