#!/usr/bin/env bash
# Reproduce multicast benchmark latency results for SEQ, TREE, and HW implementations.
# Defaults: SIZE=1024, BATCH=64, N_ROWS=4, 4 clusters/row (4x4 mesh).

set -e

source ./tools_docker.sh
source .venv/bin/activate

CHS_BINARY=sw/cheshire/tests/simple_offload.spm.elf

################
# Build step   #
################

PB_ROOT=$(pwd)
LLVM=${PB_ROOT}/tools/riscv32-snitch-llvm-ubuntu2204-15.0.0-snitch-0.5.0/bin
CLANG=${LLVM}/clang++
SN_ROOT=$(bender path snitch_cluster)
CFLAGS="-mcpu=snitch -menable-experimental-extensions -mabi=ilp32d -mcmodel=medany \
  -mno-fdiv -fno-builtin-printf -fno-builtin-sqrtf -fno-common -fopenmp \
  -ftls-model=local-exec -O3 -Werror \
  --sysroot=${LLVM}/../riscv32-unknown-elf \
  -I${SN_ROOT}/sw/kernels/blas \
  -I${PB_ROOT}/sw/include -I${PB_ROOT}/.generated -I${PB_ROOT}/sw/snitch/runtime/src \
  -I${SN_ROOT}/sw/runtime/src -I${SN_ROOT}/sw/runtime/api \
  -I${SN_ROOT}/sw/runtime/src/omp -I${SN_ROOT}/sw/runtime/api/omp \
  -I${SN_ROOT}/sw/runtime/vendor/riscv-opcodes \
  -I${PB_ROOT}/sw/snitch/runtime/impl"
LDFLAGS="-fuse-ld=${LLVM}/ld.lld \
  -nostartfiles -nostdlib++ -lm \
  -L${PB_ROOT}/sw/snitch/runtime/impl/ \
  -T${SN_ROOT}/sw/runtime/base.ld \
  -L${PB_ROOT}/sw/snitch/runtime/build -lsnRuntime"
SRC=${PB_ROOT}/sw/snitch/tests/multicast_benchmark.c
OUTDIR=${PB_ROOT}/sw/snitch/tests/build

echo "=== Building binaries ==="
$CLANG $CFLAGS -DIMPL=SEQ  $LDFLAGS -x c++ $SRC -o $OUTDIR/multicast_benchmark_seq.elf
$CLANG $CFLAGS -DIMPL=TREE $LDFLAGS -x c++ $SRC -o $OUTDIR/multicast_benchmark_tree.elf
$CLANG $CFLAGS -DIMPL=HW   $LDFLAGS -x c++ $SRC -o $OUTDIR/multicast_benchmark_hw.elf
echo "Done."

######################
# Run + extract loop #
######################

for IMPL in SEQ TREE HW; do
    SN_BINARY=$OUTDIR/multicast_benchmark_$(echo $IMPL | tr '[:upper:]' '[:lower:]').elf

    echo ""
    echo "=== Running $IMPL ==="
    make vsim-run-batch CHS_BINARY=$CHS_BINARY SN_BINARY=$SN_BINARY PRELMODE=3
    make traces sn-perf

    # Save perf.json per implementation
    cp logs/perf.json logs/perf_${IMPL}.json
done

######################
# Report results     #
######################

python3 - <<'EOF'
import json

TCK       = 5    # ps per cycle; 200 MHz clock
SIZE      = 1024 # bytes
BATCH     = 64   # bytes (SEQ only)
N_BATCHES = SIZE // BATCH  # 16

# DMA core of cluster N: hart_(1 + N*9 + 8)
def hart(cluster_idx):
    return f'hart_{1 + cluster_idx * 9 + 8}'

def cycles(ps):
    return ps // TCK

print()
print("=" * 52)
print(f"  Multicast benchmark  (SIZE={SIZE}B, N_ROWS=4, 4x4 mesh)")
print("=" * 52)

# --- SEQ ---
with open('logs/perf_SEQ.json') as f:
    perf = json.load(f)
c0  = perf[hart(0)]   # cluster 0  (row 0, col 0)
c15 = perf[hart(15)]  # cluster 15 (row 3, col 3)
# Warm (2nd) iteration region indices derived from gen_trace.py + ROI template:
#   region 36 = "batch 0" for cluster 0  (idx = 3 + N_BATCHES*2 + 0*2 + 1 = 36)
#   region 66 = "batch 15" for cluster 15 (idx = 3 + N_BATCHES*2 + 15*2 + 1 = 66)
start_ps = c0[36]['tstart']
end_ps   = c15[66]['tend']
seq_ps   = end_ps - start_ps
print(f"\nSEQ  (sequential, {N_BATCHES} batches x {BATCH}B)")
print(f"  Latency: {cycles(seq_ps):5d} cycles = {seq_ps/1000:.1f} ns")

# --- TREE ---
with open('logs/perf_TREE.json') as f:
    perf = json.load(f)
c0 = perf[hart(0)]   # cluster 0: initial fetch + all row/col levels
c8 = perf[hart(8)]   # cluster 8: last level-4 sender measured by experiments.py
# Warm iter region indices (from ROI template tree.json.tpl, N_ROWS=4):
#   cluster 0  region 14 = "level 0" (initial M→C fetch, warm iter)
#   cluster 8  region 14 = "level 4" (last tree level, warm iter)
start_ps = c0[14]['tstart']
end_ps   = c8[14]['tend']
tree_ps  = end_ps - start_ps
print(f"\nTREE (binary-tree broadcast, 5 levels)")
print(f"  Latency: {cycles(tree_ps):5d} cycles = {tree_ps/1000:.1f} ns")

# --- HW ---
with open('logs/perf_HW.json') as f:
    perf = json.load(f)
c0 = perf[hart(0)]
# Warm iter: region 5 = "transfer" (inner mcycle before DMA → outer mcycle after wait)
# Region layout: 0=startup,1=init_iter1,2=transfer_iter1,3=inter_iter,4=init_iter2,5=transfer_iter2
hw_r  = c0[5]
hw_ps = hw_r['tend'] - hw_r['tstart']
print(f"\nHW   (hardware NoC multicast, single DMA from cluster 0)")
print(f"  Latency: {cycles(hw_ps):5d} cycles = {hw_ps/1000:.1f} ns")

print()
print("=" * 52)
print(f"  Summary (warm/2nd iteration, cluster 0 → all 16)")
print("=" * 52)
print(f"  {'Impl':<6}  {'Cycles':>8}  {'Latency':>10}")
print(f"  {'-'*6}  {'-'*8}  {'-'*10}")
print(f"  {'SEQ':<6}  {cycles(seq_ps):>8}  {seq_ps/1000:>9.1f} ns")
print(f"  {'TREE':<6}  {cycles(tree_ps):>8}  {tree_ps/1000:>9.1f} ns")
print(f"  {'HW':<6}  {cycles(hw_ps):>8}  {hw_ps/1000:>9.1f} ns")
print()
EOF
