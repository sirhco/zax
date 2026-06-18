# Bare-metal / cloud Linux benchmark — confirm the evented numbers off the VM

All the headline numbers so far (`results.md`, the evented payoff: zax-ev ~750k req/s,
p99.9 ~0.35ms) were measured in **Docker's linuxkit VM on a Mac (arm64)**. That's a real
Linux kernel, and the *relative* gaps are sound — but absolute req/s carries VM + container
overhead, and the linuxkit scheduler isn't a server kernel. This procedure re-runs the
comparison on a **real Linux host** to remove that caveat.

## What you need
A Linux box with ≥8 cores (a cloud VM is fine — e.g. a c7g/c6i/n2 instance, 8–16 vCPU,
Ubuntu/Debian). `taskset` for `PIN=1` (present on all standard distros). Ideally x86_64 or
arm64 (both supported).

## Option A — fastest: run the existing Docker image on the Linux host
Same image we built locally, but on a real kernel (not the Mac's VM). On the Linux box:
```sh
git clone <this repo> zax && cd zax
docker build -f benchmarks/cross/docker/Dockerfile -t zax-linux-bench .
docker run --rm zax-linux-bench \
  bash -c 'cd /zax/benchmarks/cross && BACKEND=both PIN=1 DURATION=30s CONNS=64 ./run.sh' \
  | sed -n '/==== RESULTS/,$p'
```
Real kernel, but still inside a container (near-zero overhead for CPU-bound loopback, but
not truly bare). Good enough to validate; quickest.

## Option B — true bare metal: native toolchains (no Docker)
On the Linux box, run the setup script (installs zig 0.16 / go / rust+oha), then the bench:
```sh
git clone <this repo> zax && cd zax
bash benchmarks/cross/setup-linux.sh        # installs toolchains into ~/.local + cargo
cd benchmarks/cross
BACKEND=both PIN=1 DURATION=30s CONNS=64 ./run.sh | sed -n '/==== RESULTS/,$p'
```
No container at all — the truest measurement.

## Notes for a fair run
- **`PIN=1`** pins the servers to the first half of cores and `oha` to the second half
  (`taskset`) so client and server don't fight — essential for the tail numbers.
- **`BACKEND=both`** runs zax twice: `zax` (threaded) and `zax-ev` (evented epoll), alongside
  axum/go/httpz. The evented worker count defaults to ncpu; with `PIN=1` it binds to the
  pinned half — that's intended (server-side cores).
- For the cleanest tail, also try **client on a SEPARATE machine** over the LAN (no shared
  cores at all): start the servers on host A (bind all interfaces), run `oha` from host B.
- Run `DURATION=30s` (or longer) and a couple of repeats; report median.

## What to compare
Drop the RESULTS table into the section below and compare against the Docker-VM run in
`results.md` ("Evented zax — payoff"). The questions:
1. Does **zax-ev** stay the throughput leader (it was ~750k = 1.67× axum in the VM)?
2. Does the **p99.9 stay sub-ms** (~0.35ms) off the VM?
3. Does **zax-ev p50** stay best-in-class?
If the relative ordering holds on real hardware, the result is confirmed beyond the VM
caveat. If absolute numbers shift but the ordering holds, that's expected (VM overhead removed).

## Results (fill in)

Host: ______ (CPU, cores, distro/kernel) · DURATION ___ · CONNS ___ · Option A/B · client: same-host PIN / separate machine

| framework | scenario | req/s | p50 | p99 | p99.9 | max |
|-----------|----------|------:|----:|----:|------:|----:|
| zax (threaded) | static |  |  |  |  |  |
| zax-ev | static |  |  |  |  |  |
| axum | static |  |  |  |  |  |
| go | static |  |  |  |  |  |
| httpz | static |  |  |  |  |  |

**Verdict:** ______ (ordering held? absolute vs the VM run? tail sub-ms?)
