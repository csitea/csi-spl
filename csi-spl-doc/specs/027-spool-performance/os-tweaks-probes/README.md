# Probes for os-tweaks-analysis.md

Read-only probes behind [../os-tweaks-analysis.md](../os-tweaks-analysis.md).
Run them in a scratch copy; none changes a system setting. Each per-process A/B
(`prctl(PR_SET_THP_DISABLE)`, `GOMAXPROCS`) affects only the probe's children.

| probe | run | measures |
|---|---|---|
| `bench.py` | `SPOOL_BIN=$(command -v spool) python3 -I bench.py 40` | wall, usr, sys, minor faults per start of common programs, THP on and off |
| `fk.c` | `gcc -O2 -o fk fk.c && ./fk`, then `taskset -c 3 ./fk` | `fork`+`_exit` and `vfork`+`exec /bin/true` cost, unpinned and pinned |
| `forkbash.sh` + `rus.py` | `python3 -I rus.py sys bash forkbash.sh 1 <checkout>` (and `0`, and `off` for THP off; `forkbash.sh 1 <checkout> 0` for the source-only cost) | `sys` per `$( )` fork from a plain Bash vs one that sourced every `orc` action |
| `fkheap.c` | `gcc -O2 -o fkheap fkheap.c && ./fkheap <heap MB> <child writes every N pages, 0 = none> [1 = MADV_NOHUGEPAGE]` | fork cost against parent heap size, on huge pages and on 4 KiB pages |
| `thpcheck.sh` | `GLIBC_TUNABLES=glibc.malloc.top_pad=134217728 bash thpcheck.sh <checkout>` | RSS and `AnonHugePages` of a Bash that sourced every `orc` action |
| `pidscan.py` | `python3 -I pidscan.py 30` | new pids by `comm` over 30 s (a lower bound) |

The 11-day regression reads the box's `sysstat` files:
`for f in /var/log/sysstat/sa[0-9][0-9]; do LC_ALL=C sadf -d "$f" -- -w -u; done`
then least squares of `%system` on `proc/s` per timestamp (skip `LINUX-RESTART` rows).
