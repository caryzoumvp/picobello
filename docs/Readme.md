# Simulation Setup

Run all Picobello make targets from the repository root. The
`vsim-run-batch` target is defined by the root `Makefile`; a “No rule to make
target” error usually means that `make` was invoked from a different directory
or with another makefile.

## Docker/`/opt` QuestaSim Environment

When QuestaSim is installed below `/opt`, load the repository environment:

```bash
cd /workspace
source ./tools_docker.sh
```

This adds the repository-provided `bender`, the RISC-V toolchains, and
`/opt/questasim/linux_x86_64` to `PATH`. Verify the setup before compiling:

```bash
which bender
which vsim
make help
```

## Running a Batch Simulation

Compile the simulator once after RTL or dependency changes, then run the
Cheshire offload program together with the Snitch benchmark:

```bash
make vsim-compile
make vsim-run-batch \
  CHS_BINARY=sw/cheshire/tests/simple_offload.spm.elf \
  SN_BINARY=sw/snitch/tests/build/multicast_benchmark.elf \
  PRELMODE=3
```

`PRELMODE=3` uses fast Snitch ELF preloading. From outside the repository, use
`make -C /workspace vsim-run-batch ...` instead of relying on the caller’s
current directory.

## Regenerating Snitch RTL

After refreshing Bender dependencies, generate the Snitch wrapper before
running `make all`. Activate the repository environment first: `clustergen.py`
requires its `json5` dependency.

```bash
source ./tools_docker.sh
source .venv/bin/activate

make sn-hw-all
SN_ROOT="$(bender path snitch_cluster)"
make SN_GEN_DIR="$SN_ROOT/hw/generated" sn-hw-all
make all
```

The first target writes Picobello's generated sources to `.generated/`. The
second also writes `snitch_cluster_pkg.sv` to the Snitch checkout's
`hw/generated/` directory, which this Snitch revision's Bender manifest
requires during source-list generation.

## AXI Multicast Patch Status

The AXI checkout at `.bender/git/checkouts/axi-c94b9d7ea2e0843a` already
contains multicast patches `0001`--`0026` as committed history. The
clean-lock revision is `06410c36819924e32db2afa428d244dbdbcd5d4e` (`06410c3`),
which completed `make vsim-compile` with zero errors. Do not re-apply these
patches: their changes are already present and `git am` will conflict.

The corresponding commit range is `9cd8157^..06410c3`:

```text
0001-0003  9cd8157, bab24f7, d416ee9
0004-0008  28071b7, 6972683, 5813d9f, 9d6df68, 7bce784
0009-0013  29f1302, 3992e5b, 1a401d0, a64189a, a7c1423
0014-0018  1e34421, bd1abff, 3fb5376, eb5e61e, 6744830
0019-0023  3de08ff, 5f90fb2, 05af798, fbc7c91, cda42b9
0024-0026  6544830, 8e04779, 06410c3
```

Patches `0027` (`Bender.yml: Fix IP sorting by levels`) and `0028`
(`tb_axi_xbar_pkg: Remove legacy TODO`) are later than the lock-pinned AXI
commit. They have not been applied. Root `Bender.yml` and `Bender.lock` remain
unchanged.
