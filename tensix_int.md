# TensixTile Integration Evaluation

## Overview

This document evaluates replacing the `snitch_cluster` tile in picobello with `TT_TensixTile_RTL`
and proposes a phased integration approach.

---

## TensixTile Architecture

- **Host cores**: 5× Ibex RV32IM cores (no F/D extensions, no OpenMP)
- **Tensix coprocessor**: matrix unit, vector/SFPU, packer, unpacker, mover, sync, config, misc units — 107 opcodes
- **L1 scratchpad**: 1464 KiB
- **NoC interface**: two independent 128-bit valid/ready flit streams (`noc0`, `noc1`) on `tensix_tile_top`
- **NIU status**: `noc_stub.sv` — complete placeholder; all L1 request ports tied off, TX held idle, RX silently discarded

---

## snitch_cluster Interface (current)

- **AXI4 narrow** (64-bit) + **AXI4 wide** (512-bit) — full 5-channel handshake (AW/W/B/AR/R)
- **TCDM** L1 scratchpad with banked crossbar
- **OpenMP runtime**, PULP LLVM toolchain (`riscv32-snitch-llvm`)
- Directly wired into FlooNoC via `snitch_cluster_floo_noc.sv` (generated)

---

## Hard Blockers

### 1. NIU is a stub
`noc_stub.sv` does not implement any L1 read/write logic. The NIU must be fully designed before
the tile can communicate with anything over the NoC.

### 2. Protocol mismatch: AXI4 vs raw flits
FlooNoC expects AXI4 on both narrow and wide ports. TensixTile exposes raw 128-bit valid/ready
flits with no burst, no ID tracking, no address channels. A full AXI4↔flit bridge would be
required — this is non-trivial and effectively reimplements the NIU.

### 3. Address space mismatch
picobello's address map (generated via `peakrdl` from `cfg/rdl/`) assigns each tile a region in
the global 64-bit address space routed over AXI4. TensixTile uses a proprietary MMIO map and
does not expose a standard AXI4 subordinate port for configuration by the CVA6 host.

### 4. ISA incompatibility
Snitch software uses the PULP LLVM toolchain with RV32IMAFD + Xfrep + Xssr extensions and an
OpenMP runtime. Ibex cores are RV32IM only. All existing Snitch kernels (gemm, flashattention,
summa_gemm, etc.) would need to be rewritten or cross-compiled for a different ISA.

### 5. Software stack
picobello's Snitch HAL (`sw/snitch/runtime/`), offload protocol, and experiment harness all
assume Snitch-specific CSRs, barrier registers, and DMA semantics. None of these apply to the
Tensix execution model.

---

## Feasibility Verdict

**Direct replacement is not feasible** without first completing the NIU and implementing a
full AXI4 bridge. The protocol gap alone represents months of RTL design work independent of
the software stack divergence.

---

## Recommended Approach: Add as a New Tile Type

Rather than replacing `snitch_cluster`, add `tensix_tile` as a new tile variant alongside the
existing tiles (analogous to `fhg_spu_tile`). This is lower risk and preserves existing
functionality while enabling incremental integration.

### Phase 1 — RTL Wrapper (prerequisite)

1. Implement the NIU in `TT_TensixTile_RTL/tensix_rtl/rtl/noc/` — this is the critical path.
   The NIU must translate between:
   - Incoming AXI4 write requests → L1 write transactions (via `l1_wr_req`/`l1_wr_addr`/`l1_wr_data`)
   - Incoming AXI4 read requests → L1 read transactions (via `l1_rd_req`/`l1_rd_addr`), returning responses
   - Outgoing L1 data → AXI4 read responses back to FlooNoC

2. Create `hw/tensix_tile.sv` — wrap `tensix_tile_top` with:
   - AXI4 narrow port (config/MMIO from CVA6 host → Ibex cores via JTAG or memory-mapped boot)
   - AXI4 wide port (bulk data → NIU → L1)
   - FlooNoC connections (reuse generated endpoint from `cfg/picobello_noc.yml`)

3. Add a `tensix_tile` entry to `cfg/picobello_noc.yml` and regenerate FlooNoC.

### Phase 2 — Software Offload

1. Write a minimal Ibex firmware that can receive a work descriptor from CVA6 over AXI4 MMIO
   and dispatch Tensix coprocessor instructions.
2. Add a Cheshire offload test that writes a descriptor to the tensix_tile address range and
   polls for completion (analogous to `sw/cheshire/tests/simple_offload.c`).

### Phase 3 — Collective Operations (long-term)

Once the NoC integration is stable, investigate whether Tensix's sync unit can participate in
picobello's barrier/multicast/reduction collective operations. This requires mapping Tensix
sync primitives to FlooNoC's multicast/barrier protocol.

---

## File Locations

| File | Purpose |
|------|---------|
| `TT_TensixTile_RTL/tensix_rtl/rtl/tile/tensix_tile_top.sv` | Top-level tile interface |
| `TT_TensixTile_RTL/tensix_rtl/rtl/noc/noc_stub.sv` | NIU placeholder (to be replaced) |
| `TT_TensixTile_RTL/tensix_rtl/doc/memory_map.md` | Tensix MMIO / address map |
| `TT_TensixTile_RTL/tensix_rtl/doc/interface_signals.md` | Port-level signal descriptions |
| `cfg/picobello_noc.yml` | FlooNoC topology (add tensix_tile entry here) |
| `hw/tensix_tile.sv` | Wrapper to create (Phase 1) |

---

## Effort Estimate

| Phase | Estimated effort | Blocker |
|-------|-----------------|---------|
| NIU design | 3–6 months (1 engineer) | Required for everything else |
| RTL wrapper + FlooNoC integration | 2–4 weeks | NIU complete |
| Minimal SW offload | 2–4 weeks | Ibex toolchain setup |
| Collective ops | TBD | Phase 2 complete |
