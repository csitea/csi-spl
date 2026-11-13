import os, sys, time, collections

D = float(sys.argv[1])
seen = set(int(p) for p in os.listdir("/proc") if p.isdigit())
c = collections.Counter()
big = collections.Counter()
read = 0
p0 = int([x for x in open("/proc/stat") if x.startswith("processes")][0].split()[1])
t0 = time.time()
while time.time() - t0 < D:
    for p in os.listdir("/proc"):
        if not p.isdigit() or int(p) in seen:
            continue
        seen.add(int(p))
        try:
            comm = open(f"/proc/{p}/comm").read().strip()
            rss = 0
            for line in open(f"/proc/{p}/status"):
                if line.startswith("VmRSS:"):
                    rss = int(line.split()[1])
        except Exception:
            c["<exited>"] += 1
            continue
        read += 1
        c[comm] += 1
        if comm in ("run", "bash"):
            big[
                (
                    comm,
                    "rss>=60MB"
                    if rss >= 60000
                    else ("8-60MB" if rss >= 8000 else "<8MB"),
                )
            ] += 1
    time.sleep(0.01)
p1 = int([x for x in open("/proc/stat") if x.startswith("processes")][0].split()[1])
print(
    f"# {time.strftime('%FT%TZ', time.gmtime())} {D:.0f}s load={open('/proc/loadavg').read().split()[0]} kernel starts={p1 - p0} read={read} exited={c['<exited>']}"
)
for k, v in sorted(big.items()):
    print(f"{v:7d} {k[0]} {k[1]}")
