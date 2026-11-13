import sys, resource, ctypes, subprocess

thp = sys.argv[1] == "off"
cmd = sys.argv[2:]


def pre():
    if thp:
        ctypes.CDLL(None).prctl(41, 1, 0, 0, 0)


p = subprocess.run(cmd, preexec_fn=pre)
r = resource.getrusage(resource.RUSAGE_CHILDREN)
print(
    f"  thp={'off' if thp else 'sys'} usr={r.ru_utime:.2f}s sys={r.ru_stime:.2f}s minflt={r.ru_minflt}"
)
