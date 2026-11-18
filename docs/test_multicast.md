# How to get multicast time from `multicast_benchmark.c`

## How timing is instrumented

The code uses `snrt_mcycle()` which reads the RISC-V `mcycle` CSR (hardware cycle counter). Each call creates a boundary between two timed regions. In `main()`:

```c
for (volatile int i = 0; i < 2; i++) {
    snrt_mcycle();          // boundary: starts "init" region
    dma_multicast(...);     // inside HW impl: one more snrt_mcycle() before DMA start
    snrt_mcycle();          // boundary: ends "transfer" region
    snrt_inter_cluster_barrier(comm);
}
```

For the `HW` implementation (`dma_multicast_hw`), the DMA core of cluster 0 (`hart_9`) sees 3 `snrt_mcycle()` calls per iteration, creating regions:
- **Region 1 ("init")**: outer mcycle → inner mcycle (setup overhead)
- **Region 2 ("transfer")**: inner mcycle → closing outer mcycle (actual DMA transfer time)

The second loop iteration (regions 4 & 5) gives the "warm" timing — that's what `hw_cycles()` in `experiments.py` reads by default (occurrence=1).

## Step-by-step: extract timing from a single run

**1. Run simulation:**
```bash
make vsim-run-batch CHS_BINARY=sw/cheshire/tests/simple_offload.spm.elf \
    SN_BINARY=sw/snitch/tests/build/multicast_benchmark.elf PRELMODE=3
```

**2. Generate traces and `logs/perf.json`:**
```bash
make traces sn-perf
```
This produces `logs/perf.json` — a JSON with all mcycle-delimited regions per hart.

**3. Read the transfer time from `perf.json`:**

The DMA core of cluster 0 is `hart_9` (formula: `1 + cluster_idx*9 + 8`, cluster 0 → hart 9). The transfer region is region index 2 (0-based: index 1 for the first iteration, index 4 for the second/warm iteration).

```python
import json

with open('logs/perf.json') as f:
    perf = json.load(f)

# Second iteration (warm), region index 4 = "transfer"
regions = perf['hart_9']
# Each region has 'tstart' and 'tend' in picoseconds
transfer_region = regions[4]  # 0-indexed; idx 5 in ROI spec = index 4 here
cycles = (transfer_region['tend'] - transfer_region['tstart']) // 5  # TCK=5ps
print(f"HW multicast transfer: {cycles} cycles")
```

**4. Or use the ROI infrastructure for labeled regions:**
```bash
make traces sn-perf ROI_SPEC=experiments/multicast/roi/hw.json.tpl
```
Note: the `.tpl` files use Mako templates and need experiment config to render. For a one-off run use `perf.json` directly as above.

## Quickest one-liner after simulation

```bash
python3 -c "
import json
p = json.load(open('logs/perf.json'))
h = p['hart_9']  # DMA core, cluster 0
# Region indices (0-based): 0=init1, 1=transfer1, 2=init2, 3=transfer2
for i, r in enumerate(h):
    dt = (r['tend'] - r['tstart']) // 5  # cycles (TCK=5ps)
    print(f'region {i}: {dt} cycles')
"
```

The **"transfer"** region of the second iteration is the canonical multicast latency (cache-warm). For the `SEQ` and `TREE` impls, multiple clusters contribute so you'd look at their respective `hart_*` entries using the formulas in `experiments.py:dma_core()`.

## Region index reference (HW impl, hart_9)

| 0-based index | ROI spec idx | Label      | Description                     |
|---------------|-------------|------------|---------------------------------|
| 0             | 1           | init       | Iteration 1: setup to DMA start |
| 1             | 2           | transfer   | Iteration 1: DMA transfer time  |
| 2             | 4           | init       | Iteration 2: setup to DMA start |
| 3             | 5           | transfer   | Iteration 2: DMA transfer time (use this) |
