#!/usr/bin/env python3
"""Summarise results/<label>/ into markdown tables (median of runs) and simple charts."""
import json, pathlib, re, statistics as st, sys

ROOT = pathlib.Path(__file__).parent / "results"
FIO = ["seq-read", "seq-write", "rand-read-4k", "rand-write-4k", "rand-write-4k-fsync", "mixed-4k-70-30"]


def med(xs):
    return st.median(xs) if xs else float("nan")


def load(label):
    d = ROOT / label
    r = {"label": label, "card": json.loads((d / "card.json").read_text()), "fio": {}, "task": {}, "boot": []}
    for job in FIO:
        runs = [json.loads(p.read_text())["jobs"][0] for p in sorted(d.glob(f"fio-{job}-run*.json"))]
        if not runs:
            continue
        agg = {}
        for rw in ("read", "write"):
            if any(x[rw]["io_bytes"] for x in runs):
                agg[rw] = {
                    "mb_s": med([x[rw]["bw_bytes"] / 1e6 for x in runs]),
                    "iops": med([x[rw]["iops"] for x in runs]),
                    "lat_ms": med([x[rw]["clat_ns"]["mean"] / 1e6 for x in runs]),
                    "p99_ms": med([x[rw]["clat_ns"]["percentile"]["99.000000"] / 1e6 for x in runs]),
                    "p9999_ms": med([x[rw]["clat_ns"]["percentile"]["99.990000"] / 1e6 for x in runs]),
                }
        r["fio"][job] = agg
    for task in ("largefile", "smallfiles"):
        runs = [json.loads(p.read_text()) for p in sorted(d.glob(f"task-{task}-run*.json"))]
        if runs:
            r["task"][task] = {k: med([x[k] for x in runs]) for k in runs[0]}
    for p in sorted(d.glob("boot-run*.txt")):
        m = re.search(r"= ([\d.]+)s", p.read_text().splitlines()[0])
        if m:
            r["boot"].append(float(m.group(1)))
    return r


def table(rows, header):
    out = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    out += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
    return "\n".join(out)


def main(labels):
    R = [load(l) for l in labels]
    names = [r["label"] for r in R]

    print("## Cards\n")
    print(table([[r["label"], r["card"]["manufacturer"], r["card"]["name"], r["card"]["size_gib"], r["card"]["date"],
                  r["card"]["ssr"]["speed_class"], r["card"]["ssr"]["uhs_grade"], r["card"]["ssr"]["video_class"],
                  r["card"]["ssr"]["app_class"], r["card"]["ssr"]["au_size"], r["card"]["mode"]["timing"]] for r in R],
                ["label", "maker", "name", "GiB", "made", "class", "UHS", "video", "app", "AU", "mode"]))

    print("\n## Large files (median of runs)\n")
    print(table([[n, f"{r['fio']['seq-read']['read']['mb_s']:.1f}", f"{r['fio']['seq-write']['write']['mb_s']:.1f}",
                  f"{r['task']['largefile']['bytes']/r['task']['largefile']['write_s']/1e6:.1f}",
                  f"{r['task']['largefile']['bytes']/r['task']['largefile']['read_s']/1e6:.1f}"] for n, r in zip(names, R)],
                ["card", "fio seq read MB/s", "fio seq write MB/s", "1 GiB file write MB/s", "1 GiB file read MB/s"]))

    print("\n## Small I/O, 4 KiB, one request at a time (median of runs)\n")
    rows = []
    for n, r in zip(names, R):
        f = r["fio"]
        rows.append([n,
                     f"{f['rand-read-4k']['read']['iops']:.0f} ({f['rand-read-4k']['read']['lat_ms']:.2f} ms)",
                     f"{f['rand-write-4k']['write']['iops']:.0f} ({f['rand-write-4k']['write']['lat_ms']:.2f} ms)",
                     f"{f['rand-write-4k-fsync']['write']['iops']:.0f} ({f['rand-write-4k-fsync']['write']['lat_ms']:.2f} ms)",
                     f"{f['mixed-4k-70-30']['read']['iops']:.0f} / {f['mixed-4k-70-30']['write']['iops']:.0f}",
                     f"{f['rand-write-4k']['write']['p9999_ms']:.1f} ms"])
    print(table(rows, ["card", "rand read IOPS", "rand write IOPS", "write+fsync IOPS", "mixed r/w IOPS", "write p99.99"]))

    print("\n## Real tasks (median of runs)\n")
    print(table([[n, f"{r['task']['smallfiles']['extract_s']:.1f} s", f"{r['task']['smallfiles']['delete_s']:.1f} s",
                  f"{med(r['boot']):.1f} s" if r["boot"] else "-"] for n, r in zip(names, R)],
                ["card", f"extract {R[0]['task']['smallfiles']['files']:.0f} files", "delete them", "boot (systemd-analyze)"]))

    try:
        import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
        fig, ax = plt.subplots(1, 3, figsize=(13, 3.8))
        ax[0].bar(names, [r["fio"]["seq-read"]["read"]["mb_s"] for r in R], label="read")
        ax[0].bar(names, [r["fio"]["seq-write"]["write"]["mb_s"] for r in R], alpha=.6, label="write")
        ax[0].set_title("Sequential, MB/s"); ax[0].legend()
        ax[1].bar(names, [r["fio"]["rand-read-4k"]["read"]["iops"] for r in R], label="read")
        ax[1].bar(names, [r["fio"]["rand-write-4k"]["write"]["iops"] for r in R], alpha=.6, label="write")
        ax[1].bar(names, [r["fio"]["rand-write-4k-fsync"]["write"]["iops"] for r in R], alpha=.6, label="write+fsync")
        ax[1].set_title("4 KiB random, IOPS"); ax[1].legend()
        ax[2].bar(names, [r["task"]["smallfiles"]["extract_s"] for r in R], label="extract")
        ax[2].bar(names, [r["task"]["smallfiles"]["delete_s"] for r in R], alpha=.6, label="delete")
        ax[2].set_title("Small files, seconds (lower is better)"); ax[2].legend()
        for a in ax: a.tick_params(axis="x", labelsize=8)
        fig.tight_layout(); fig.savefig(ROOT / "summary.png", dpi=130)
        print(f"\nchart: {ROOT/'summary.png'}")
    except ImportError:
        print("\n(matplotlib not installed; no chart)")


if __name__ == "__main__":
    main(sys.argv[1:] or sorted(p.name for p in ROOT.iterdir() if (p / "card.json").exists()))
