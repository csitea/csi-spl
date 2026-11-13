import os, sys, time, resource, ctypes, statistics

libc = ctypes.CDLL(None, use_errno=True)
PR_SET_THP_DISABLE = 41


def run(cmd, n, thp_off=False, env=None):
    walls = []
    r0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    for _ in range(n):
        t = time.perf_counter()
        pid = os.fork()
        if pid == 0:
            if thp_off:
                libc.prctl(PR_SET_THP_DISABLE, 1, 0, 0, 0)
            fd = os.open("/dev/null", os.O_WRONLY)
            os.dup2(fd, 1)
            os.dup2(fd, 2)
            try:
                os.execvpe(cmd[0], cmd, env or os.environ)
            finally:
                os._exit(127)
        os.waitpid(pid, 0)
        walls.append((time.perf_counter() - t) * 1000)
    r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    u = (r1.ru_utime - r0.ru_utime) * 1000 / n
    s = (r1.ru_stime - r0.ru_stime) * 1000 / n
    mf = (r1.ru_minflt - r0.ru_minflt) / n
    return statistics.median(walls), u, s, mf


cases = {
    "true": ["/bin/true"],
    "bash -c :": ["bash", "-c", ":"],
    "awk BEGIN": ["awk", "BEGIN{}"],
    "python3 -c pass": ["python3", "-c", "pass"],
    "python3 -I -S -c pass": ["python3", "-I", "-S", "-c", "pass"],
    "jq -n .": ["jq", "-n", "."],
    "git --version": ["git", "--version"],
    "spool version": [os.environ.get("SPOOL_BIN", "spool"), "version"],
    "sudo -n true": ["sudo", "-n", "true"],
}
n = int(sys.argv[1]) if len(sys.argv) > 1 else 40
la = open("/proc/loadavg").read().split()[:3]
print(f"# {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} load={la} n={n}")
print(
    f"{'case':24} {'thp':5} {'wall_med_ms':>11} {'usr_ms':>7} {'sys_ms':>7} {'minflt':>7}"
)
for name, cmd in cases.items():
    for thp in (False, True):
        w, u, s, mf = run(cmd, n, thp)
        print(
            f"{name:24} {'off' if thp else 'sys':5} {w:11.1f} {u:7.2f} {s:7.2f} {mf:7.0f}"
        )
