import os, time, collections, sys

D = float(sys.argv[1])
seen = set(int(p) for p in os.listdir("/proc") if p.isdigit())
c = collections.Counter()
new = 0
t0 = time.time()
p0 = int([l for l in open("/proc/stat") if l.startswith("processes")][0].split()[1])
while time.time() - t0 < D:
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        i = int(p)
        if i in seen:
            continue
        seen.add(i)
        new += 1
        try:
            c[open(f"/proc/{p}/comm").read().strip()] += 1
        except Exception:
            c["<exited>"] += 1
    time.sleep(0.01)
p1 = int([l for l in open("/proc/stat") if l.startswith("processes")][0].split()[1])
print(
    f"# {time.strftime('%FT%TZ', time.gmtime())} {D:.0f}s load={open('/proc/loadavg').read().split()[0]} kernel starts={p1 - p0} seen={new}"
)
for k, v in c.most_common(25):
    print(f"{v:7d} {k}")
