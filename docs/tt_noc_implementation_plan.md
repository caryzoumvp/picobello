# TT WormholeB0 NoC Features — Implementation Plan for picobello

## Overview

This plan describes how to implement TT WormholeB0 NoC capabilities within picobello's
existing FlooNoC-based architecture. The two NoCs are architecturally related but differ
in interface style:

| Aspect | WormholeB0 | picobello (FlooNoC) |
|---|---|---|
| Physical medium | 2D torus, 256-bit flits | 2D mesh, narrow (64-bit) + wide (512-bit) AXI4 |
| Initiation | MMIO-controlled NIU registers | Snitch iDMA / TCDM AMO |
| Multicast | Rectangle: StartX/EndX/StartY/EndY | Mask-based: 48-bit collective mask |
| Atomics | NIU-dispatched (ATINCGET, CAS, swap) | TCDM AMO (native to Snitch cluster) |
| Flow control | Phase-based NoC Overlay (64 streams) | FlooNoC request/response + pb_sync barrier |
| Routing | XY, 2-class + buddy + dateline VC | XY, narrow/wide separate networks |

**Strategy**: implement WormholeB0 semantics as a new RTL peripheral
(`pb_niu`) inserted into `cluster_tile`, bridged to FlooNoC's AXI4 ports.
Software uses a new `pb_niu.h` HAL that matches WormholeB0's programming model.

---

## Component Breakdown

### 1. NIU MMIO Register Block (`hw/pb_niu.sv`)

**What**: An AXI4-Lite slave that exposes WormholeB0-style NIU registers to Snitch
cores, and an AXI4 master that issues transactions onto FlooNoC.

**Address layout** (within each cluster, two NIUs: one per FlooNoC narrow network):

```
NIU_BASE_0  = <cluster_periph_base> + 0x8000   (maps to narrow FlooNoC)
NIU_BASE_1  = <cluster_periph_base> + 0x9000   (maps to wide FlooNoC, write-only)
```

Each NIU exposes 4 request initiators at offsets `i * 0x400`:

| Offset | Register | Width | Description |
|---|---|---|---|
| `+0x000` | `NOC_TARG_ADDR_LO` | 32 | Low 32b of target address |
| `+0x004` | `NOC_TARG_ADDR_MID` | 32 | High 4b addr + 6b X + 6b Y |
| `+0x00C` | `NOC_RET_ADDR_LO`  | 32 | Low 32b of return address |
| `+0x010` | `NOC_RET_ADDR_MID` | 32 | High 4b addr + 6b X + 6b Y |
| `+0x018` | `NOC_PACKET_TAG`   | 32 | [3:0] transaction ID, [8] multicast-src-include |
| `+0x01C` | `NOC_CTRL`         | 32 | Request type + flag bits (see below) |
| `+0x020` | `NOC_AT_LEN_BE`    | 32 | Length/byte-enable/atomic opcode |
| `+0x024` | `NOC_AT_DATA`      | 32 | Inline write data / atomic immediate |
| `+0x028` | `NOC_CMD_CTRL`     | 32 | Write 1 to bit 0 → dispatch; HW clears to 0 |

Status registers (shared across initiators, read-only):

| Offset | Register | Description |
|---|---|---|
| `+0x034` | `NIU_STATUS` | `[3:0]` = per-initiator busy bits |
| `+0x054` | `NIU_COMBINED_STATUS` | Global busy / any-pending |
| `+0x200` to `+0x2FC` | `NIU_COUNTERS[64]` | 32-bit performance counters (see §4) |

**RTL implementation**:

```
hw/pb_niu.sv
  Ports:
    - clk_i, rst_ni
    - axi_lite_slave  (from cluster narrow-out mux, Snitch cores write here)
    - axi_master_req/rsp (to floo_narrow_req, for unicast/atomic/read)
    - axi_wide_master (to floo_wide_req, for wide broadcast/bulk write)
    - xy_coord_i [11:0]  (this cluster's physical X/Y from picobello_pkg)

  Internal:
    - 4x initiator register files (NOC_TARG_ADDR .. NOC_CMD_CTRL)
    - Dispatch FSM per initiator:
        IDLE → TRANSLATE → ISSUE → WAIT_ACK → UPDATE_COUNTERS → IDLE
    - Coordinate translator (§2 below)
    - Multicast mask generator (§3 below)
    - Counter array (§4 below)
```

**Integration in `hw/cluster_tile.sv`**:

- Add `pb_niu` as a new module after the existing `snitch_cluster` instantiation.
- Add a new address range for NIU registers to the cluster address decoder (currently
  handled by `snitch_cluster_addrmap.rdl.tpl`).
- Connect `pb_niu`'s AXI master port to the existing `cluster_narrow_ext_req/rsp`
  signals that already feed into the FlooNoC narrow port.
- For wide writes, connect to `cluster_wide_out_req/rsp`.

---

### 2. Coordinate Translation (`hw/pb_niu_coord_xlat.sv`)

**What**: Maps logical (software-visible) tile coordinates to physical FlooNoC
mesh coordinates, and vice versa for return address embedding.

**Picobello coordinate convention** (from `picobello_pkg.sv` / `pb_noc_cfg.h`):

- Physical mesh: 7 columns × 4 rows
- Cluster columns: X = 4..7 (4×4 array); memory tiles: X = 0..3; Cheshire: special
- Software uses row/col (0-based) via `pb_cluster_row_idx()` / `pb_cluster_col_idx()`

**Register**: NIU_CFG_0 bit 14 enables translation. When disabled, raw FlooNoC
coordinates are used.

**Table format** (analogous to WormholeB0 NIU_CFG_0 + translate tables):

```
NIU_BASE + 0x100: NIU_CFG_0
  [14]: coord_translate_en
NIU_BASE + 0x110: NOC_X_TRANSLATE_TABLE_0   (16 entries × 4b packed = 2 registers)
NIU_BASE + 0x118: NOC_Y_TRANSLATE_TABLE_0
```

**Default table** (no harvesting in picobello, simpler than WormholeB0):

| Logical X | Physical FlooNoC X |
|---|---|
| 0..3 | cluster col 0..3 → physical X 4..7 |
| 4..7 | memory tile 0..3 → physical X 0..3 |
| ≥8 | identity (raw) |

**Implementation**: A 32-entry × 6-bit lookup table (one per axis) in a small ROM,
initialised at reset from `pb_noc_cfg.h`. Software can reprogram via MMIO for
yield/harvest scenarios.

---

### 3. Broadcast / Multicast Mapping (`pb_niu_mcast_mask.sv`)

**What**: Convert WormholeB0's rectangle (StartX, EndX, StartY, EndY) encoded in
`NOC_TARG_ADDR_MID` bits [59:36] into FlooNoC's 48-bit collective mask.

**WormholeB0 encoding** (from MemoryMap.md):

```
NOC_TARG_ADDR_MID[41:36] = EndX   (6-bit logical X)
NOC_TARG_ADDR_MID[47:42] = EndY
NOC_TARG_ADDR_MID[53:48] = StartX
NOC_TARG_ADDR_MID[59:54] = StartY
```

**FlooNoC mask encoding** (from `floo_picobello_noc_pkg.sv`):

- 48-bit mask, one bit per cluster, bit = (row * PB_CLUSTER_PER_ROW + col)
- `en_narrow_multicast: true` / `en_wide_multicast: true` already in `cfg/picobello_noc.yml`

**Conversion logic** (purely combinational):

```systemverilog
// pb_niu_mcast_mask.sv
for (int r = 0; r < PB_CLUSTER_PER_COL; r++) begin
  for (int c = 0; c < PB_CLUSTER_PER_ROW; c++) begin
    logic x_in_range = (xlat_x(c) >= StartX) && (xlat_x(c) <= EndX);
    logic y_in_range = (xlat_y(r) >= StartY) && (xlat_y(r) <= EndY);
    mask[r*PB_CLUSTER_PER_ROW + c] = x_in_range && y_in_range;
  end
end
```

**AXI encoding**: FlooNoC's multicast AXI user field carries the mask. The dispatch
FSM in `pb_niu` sets `axi_req.aw.user.collective_mask = mask` when
`NOC_CTRL.NOC_CMD_BRCST_PACKET` is set.

**NOC_CMD_BRCST_XY** (axis preference): FlooNoC uses XY routing; this flag is
informational only in picobello — log it in NIU_CFG_0 but routing is fixed XY.

**NOC_CMD_BRCST_SRC_INCLUDE**: When set, include the initiating cluster in the mask.
When clear, clear the bit corresponding to `xy_coord_i` in the computed mask.

---

### 4. Transaction Counters (`hw/pb_niu_counters.sv`)

**What**: Per-NIU array of 32-bit counters at `NIU_BASE + 0x200`, tracking
outstanding requests by transaction ID and overall throughput.

**Counter table** (indices 0–15 map directly to WormholeB0's layout):

| Index | Name | Increment event |
|---|---|---|
| 0 | `NIU_MST_ATOMIC_RESP_RECEIVED` | AMO response arrives on narrow slave |
| 1 | `NIU_MST_WR_ACK_RECEIVED` | AXI BVALID received (non-posted write) |
| 2 | `NIU_MST_RD_RESP_RECEIVED` | AXI RVALID last beat received |
| 4 | `NIU_MST_CMD_ACCEPTED` | NOC_CMD_CTRL bit 0 written and dispatch begun |
| 10 | `NIU_MST_NONPOSTED_WR_REQ_SENT` | AW handshake for non-posted write |
| 11 | `NIU_MST_POSTED_WR_REQ_SENT` | AW handshake for posted write |
| 16..31 | `NIU_MST_REQS_OUTSTANDING_ID(i)` | +1 on dispatch, -1 on ack/resp |

**Transaction ID** = `NOC_PACKET_TAG[3:0]`. Maps to AXI ID field (AXI IDs in Snitch
clusters are 4–6 bits wide, compatible with 4-bit transaction IDs).

**Counter clear**: Write to `NIU_BASE + 0x050` clears all per-ID outstanding counters.

**Polling pattern** (WormholeB0 fence equivalent):

```c
// Wait until all outstanding requests for transaction ID 3 complete:
while (pb_niu_rd32(NIU_BASE + 0x200 + (16+3)*4) != 0) { /* spin */ }
```

**RTL**: Simple array of `logic [31:0] counters[64]`, incremented/decremented by
combinational decode of AXI handshake signals.

---

### 5. Virtual Channel Management

**What**: Map WormholeB0's VC flags (`NOC_CMD_VC_STATIC`, `NOC_CMD_VC_LINKED`,
`NOC_CMD_ARB_PRIORITY`) to FlooNoC's VC mechanisms.

**FlooNoC VC model** (from `cfg/picobello_noc.yml`):

- Narrow network: separate req/rsp channels (deadlock-free by construction)
- Wide network: separate wide channel
- FlooNoC does not expose VC class bits to software; routing is deterministic XY

**Mapping**:

| WormholeB0 flag | FlooNoC equivalent | Action |
|---|---|---|
| `NOC_CMD_VC_STATIC` [class bits 00/01] | Narrow req channel (class A or B) | Set `axi_req.aw.user.vc = class_bits[0]` in the floo_pkg user field |
| `NOC_CMD_VC_STATIC` [class bits 10] | Wide channel (broadcast) | Route to wide AXI master port |
| `NOC_CMD_VC_LINKED` | Linked transaction | Hold narrow req port exclusively until final request (`NOC_CMD_VC_LINKED`=0) |
| `NOC_CMD_ARB_PRIORITY` | Not directly supported by FlooNoC | Store in NIU register; future: extend floo_pkg AXI user field |

**Linked transactions**: The dispatch FSM tracks a "linked" state flag. While linked,
the NIU holds the AXI AW channel granted (or uses a separate side-channel register to
queue the next request before releasing). This prevents interleaving from other
initiators or the overlay.

---

### 6. Path Reservation (`NOC_CMD_PATH_RESERVE`)

**What**: Before a broadcast, confirm all routers along the tree have reserved VC
bandwidth. WormholeB0 does this automatically when the flag is set.

**FlooNoC status**: FlooNoC's barrier mechanism (`en_barrier: true`) provides a
similar two-phase commit for collective operations. However, it operates at the barrier
level, not per-broadcast.

**Implementation**:

- When `NOC_CMD_PATH_RESERVE` is set, the `pb_niu` dispatch FSM sends a probe
  write to each destination in the rectangle (using the barrier collective op) before
  sending the actual data.
- This reuses `floo_pkg::CollectiveBarrier` from `cfg/picobello_noc.yml`:
  `collective_op: barrier` in the AXI user field → FlooNoC routers reserve VC.
- Add a state `PATH_RESERVE → WAIT_READY → SEND_DATA` in the FSM.
- If any destination NACK's (FlooNoC uses credit-based backpressure, so NACK =
  backpressure stall), the FSM retries with randomized backoff (implement a 4-bit
  LFSR counter in RTL).

---

### 7. NoC Overlay — Streaming DMA (`hw/pb_overlay.sv`)

**What**: Phase-based streaming DMA coprocessor. Each Tensix tile in WormholeB0 has
64 streams; each stream can be a unicast receiver, multicast transmitter, or gather
source/sink. In picobello, this maps to an extension of the existing iDMA framework
plus the FlooNoC multicast/gather capabilities.

**Scope**: This is the largest sub-component. Recommend implementing a **reduced
overlay** (16 streams, unicast + multicast transmit only) as Phase 1.

**Stream configuration registers** (per stream `s`, at `OVERLAY_BASE + s * 0x40`):

| Register | WormholeB0 name | Description |
|---|---|---|
| `+0x00` | `STREAM_BUF_START` | Local L1 buffer base address |
| `+0x04` | `STREAM_BUF_SIZE` | Buffer size in bytes |
| `+0x08` | `STREAM_MSG_INFO_PTR` | Pointer to message info word in L1 |
| `+0x0C` | `STREAM_REMOTE_SRC` | Source X/Y + stream ID (for receive) |
| `+0x10` | `STREAM_REMOTE_DEST` | Dest X/Y + buffer start + size (for transmit) |
| `+0x14` | `STREAM_MCAST_DEST` | Multicast rectangle (StartX/EndX/StartY/EndY) |
| `+0x18` | `STREAM_PHASE_ADVANCE` | Write 1 to advance to next phase |
| `+0x1C` | `STREAM_STATUS` | [0]=active, [1]=phase-done, [2]=error |
| `+0x20` | `STREAM_MISC_CFG` | VC class, linked, remote-src-is-multi |

**Phase state machine** per stream:

```
IDLE → CONFIGURE → ACTIVE → {RECEIVE | TRANSMIT} → PHASE_END → IDLE
                                    ↑                    |
                                    └────────────────────┘  (multi-phase loop)
```

**RTL structure**:

```
hw/pb_overlay.sv
  Submodules:
    - pb_overlay_stream[16]  (one per stream)
    - pb_overlay_arb         (round-robin arbiter for AXI master port)
    - pb_overlay_mcast       (multicast mask generator, shares pb_niu_mcast_mask logic)
  Ports:
    - axi_lite_slave         (Snitch cores configure streams)
    - axi_narrow_master      (unicast streams: receive DMA pulls, transmit pushes)
    - axi_wide_master        (wide multicast transmit)
    - stream_irq_o[16]       (phase-done interrupt to Snitch cluster)
```

**Integration**: Mount `pb_overlay` as a second peripheral alongside `pb_niu` in
`cluster_tile.sv`. Share the same AXI wide master port (arbitrated with `pb_niu`).

**Gather** (`Gather.md`): Deferred to Phase 2. Requires multiple source descriptors
per stream → add a linked-list descriptor ring in L1 (analogous to iDMA's scatter-gather).

---

### 8. Software HAL (`sw/snitch/runtime/src/pb_niu.h`)

New header providing a typed API matching WormholeB0's programming model, adapted to
picobello's address map.

```c
// pb_niu.h — NIU MMIO programming interface

#define PB_NIU0_BASE  0x40040000UL   // cluster-relative, from snitch_cluster_addrmap.h
#define PB_NIU1_BASE  0x40041000UL
#define NOC_CMD_BUF_OFFSET 0x400

// Register offsets within one initiator
#define NOC_TARG_ADDR_LO  0x000
#define NOC_TARG_ADDR_MID 0x004
#define NOC_RET_ADDR_LO   0x00C
#define NOC_RET_ADDR_MID  0x010
#define NOC_PACKET_TAG    0x018
#define NOC_CTRL          0x01C
#define NOC_AT_LEN_BE     0x020
#define NOC_AT_DATA       0x024
#define NOC_CMD_CTRL      0x028
#define NIU_COUNTERS_BASE 0x200

// NOC_CTRL flags
#define NOC_CMD_RD            0x00
#define NOC_CMD_AT            0x01
#define NOC_CMD_WR            0x02
#define NOC_CMD_RESP_MARKED   (1u << 4)
#define NOC_CMD_BRCST_PACKET  (1u << 5)
#define NOC_CMD_VC_LINKED     (1u << 6)
#define NOC_CMD_VC_STATIC     (1u << 7)
#define NOC_CMD_PATH_RESERVE  (1u << 8)
#define NOC_CMD_BRCST_XY      (1u << 16)
#define NOC_CMD_BRCST_SRC_INCLUDE (1u << 17)

// Coordinate encoding in ADDR_MID
#define NOC_TARG_ADDR_MID_X(x)  (((uint32_t)(x) & 0x3F) << 6)
#define NOC_TARG_ADDR_MID_Y(y)  (((uint32_t)(y) & 0x3F) << 12)

// Broadcast rectangle encoding
#define NOC_BRCST_ENDX(x)   (((uint64_t)(x)) << 36)
#define NOC_BRCST_ENDY(y)   (((uint64_t)(y)) << 42)
#define NOC_BRCST_STARTX(x) (((uint64_t)(x)) << 48)
#define NOC_BRCST_STARTY(y) (((uint64_t)(y)) << 54)

static inline volatile uint32_t* pb_niu_initiator(int niu, int init) {
    uintptr_t base = (niu == 0) ? PB_NIU0_BASE : PB_NIU1_BASE;
    return (volatile uint32_t*)(base + init * NOC_CMD_BUF_OFFSET);
}

// Unicast write: src_addr → dst_x,dst_y:tgt_addr, length bytes
void pb_niu_write(int niu, int init, uint32_t src_addr,
                  uint8_t dst_x, uint8_t dst_y, uint32_t tgt_addr,
                  uint32_t len, bool posted);

// Unicast read: dst_x,dst_y:tgt_addr → ret_addr, length bytes
void pb_niu_read(int niu, int init, uint8_t dst_x, uint8_t dst_y,
                 uint32_t tgt_addr, uint32_t ret_addr, uint32_t len);

// Rectangular broadcast write
void pb_niu_bcast_write(int niu, int init,
                        uint32_t src_addr,
                        uint8_t startx, uint8_t endx,
                        uint8_t starty, uint8_t endy,
                        uint32_t tgt_addr, uint32_t len,
                        bool path_reserve);

// Atomic increment (non-posted)
void pb_niu_atomic_inc(int niu, int init,
                       uint8_t dst_x, uint8_t dst_y,
                       uint32_t tgt_addr, uint32_t ret_addr,
                       uint32_t delta, uint8_t int_width,
                       uint8_t tx_id);

// Wait for transaction ID to complete (poll NIU_COUNTERS)
void pb_niu_wait_id(int niu, uint8_t tx_id);

// Fence: wait for all outstanding requests
void pb_niu_fence(int niu);
```

Add a corresponding `pb_niu.c` for the non-trivial implementations (bcast_write, wait_id).

---

### 9. Register-File Integration (`cfg/rdl/pb_niu.rdl`)

Define the NIU address map in the existing PeakRDL flow so it appears in auto-generated
headers (`pb_addrmap.h`, `pb_addrmap.svh`).

```
addrmap pb_niu_addrmap {
    default hw = r;
    default sw = rw;

    // 4 initiators
    pb_niu_initiator niu0_init0 @ 0x0000;
    pb_niu_initiator niu0_init1 @ 0x0400;
    pb_niu_initiator niu0_init2 @ 0x0800;
    pb_niu_initiator niu0_init3 @ 0x0C00;

    // Config
    pb_niu_cfg niu0_cfg @ 0x1000;

    // Counters (read-only)
    pb_niu_counters niu0_counters @ 0x1200;
};
```

Regenerate with `make pb-soc-regs` after adding the RDL file to `cfg/rdl/`.

---

### 10. Tests

#### SW Unit Tests (`sw/snitch/tests/niu_test.c`)

```c
// Test 1: Unicast write + read-back
// Test 2: Atomic increment, check return value and counter
// Test 3: Rectangular broadcast write, all clusters verify L1
// Test 4: Path-reserved broadcast (NOC_CMD_PATH_RESERVE)
// Test 5: Transaction ID counter polling fence
// Test 6: Multi-initiator parallel unicast writes
```

Compile as a Snitch test (added to `sw/snitch/tests/`, built by `make sn-tests`).

#### RTL Simulation Regression

- Run `make vsim-run-batch` with `niu_test.elf` for each test case.
- Verify perf.json counters match expected cycle counts.
- Compare broadcast latency with existing `multicast_benchmark_hw.elf` baseline.

#### Overlay Tests (`sw/snitch/tests/overlay_test.c`)

```c
// Test 1: Single unicast stream (transmit side)
// Test 2: Receive stream (DMA pull from remote cluster)
// Test 3: Multicast stream to 4-cluster row
// Test 4: Two-phase sequential stream operation
```

---

## Implementation Phases

### Phase 1 — Core NIU (4 weeks)

1. `hw/pb_niu.sv`: register file + dispatch FSM for unicast write/read/atomic
2. `hw/pb_niu_coord_xlat.sv`: coordinate translation
3. `hw/pb_niu_counters.sv`: counters 0–15 + per-ID outstanding (16–31)
4. Integration into `cluster_tile.sv`
5. `cfg/rdl/pb_niu.rdl` + regenerate headers
6. `sw/snitch/runtime/src/pb_niu.h` + `pb_niu.c` (unicast write/read/atomic)
7. `sw/snitch/tests/niu_test.c` tests 1–2–5

### Phase 2 — Broadcast + Multicast (2 weeks)

1. `hw/pb_niu_mcast_mask.sv`: rectangle → FlooNoC mask converter
2. Add `NOC_CMD_BRCST_PACKET` / `NOC_CMD_PATH_RESERVE` / `NOC_CMD_BRCST_SRC_INCLUDE`
   to dispatch FSM
3. Integrate path-reservation retry FSM (LFSR backoff)
4. `sw/snitch/runtime/src/pb_niu.h`: `pb_niu_bcast_write()`
5. `sw/snitch/tests/niu_test.c` tests 3–4

### Phase 3 — VC & Linked Transactions (1 week)

1. `NOC_CMD_VC_STATIC`, `NOC_CMD_VC_LINKED` in dispatch FSM
2. AXI user field mapping for VC class bits
3. `NOC_CMD_ARB_PRIORITY`: propagate to FlooNoC AXI user field (requires extending
   `floo_pkg` — file issue upstream)
4. `sw/snitch/tests/niu_test.c` test 6

### Phase 4 — NoC Overlay (4 weeks)

1. `hw/pb_overlay_stream.sv`: single stream FSM (unicast transmit only)
2. `hw/pb_overlay.sv`: 16-stream array + AXI arbiter
3. Integration into `cluster_tile.sv` alongside `pb_niu`
4. `sw/snitch/runtime/src/pb_overlay.h` + `pb_overlay.c`
5. `sw/snitch/tests/overlay_test.c` tests 1–3
6. Phase-advance IRQ wiring to Snitch cluster interrupt controller
7. Multi-phase streaming (test 4)
8. Gather support (descriptor ring in L1)

---

## Key Files to Create / Modify

| File | Action | Phase |
|---|---|---|
| `hw/pb_niu.sv` | Create | 1 |
| `hw/pb_niu_coord_xlat.sv` | Create | 1 |
| `hw/pb_niu_counters.sv` | Create | 1 |
| `hw/pb_niu_mcast_mask.sv` | Create | 2 |
| `hw/pb_overlay.sv` | Create | 4 |
| `hw/pb_overlay_stream.sv` | Create | 4 |
| `hw/cluster_tile.sv` | Modify: add pb_niu + pb_overlay instantiation | 1,4 |
| `cfg/rdl/pb_niu.rdl` | Create | 1 |
| `sw/snitch/runtime/impl/pb_noc_cfg.h` | Modify: add NIU base addresses | 1 |
| `sw/snitch/runtime/src/pb_niu.h` | Create | 1 |
| `sw/snitch/runtime/src/pb_niu.c` | Create | 1 |
| `sw/snitch/runtime/src/pb_overlay.h` | Create | 4 |
| `sw/snitch/runtime/src/pb_overlay.c` | Create | 4 |
| `sw/snitch/tests/niu_test.c` | Create | 1–3 |
| `sw/snitch/tests/overlay_test.c` | Create | 4 |

---

## Critical Differences from WormholeB0 to Note

1. **No response network separate from request**: FlooNoC uses a separate `floo_rsp`
   channel (not a VC class `0b11` on the same physical wires). The dispatch FSM must
   wait for AXI BVALID/RVALID on the `cluster_narrow_in_req/rsp` slave port.

2. **No DRAM NIU**: WormholeB0 DRAM tiles have NIUs with no initiation capability;
   picobello mem_tiles are always targets (AXI slave only). Memory tile addresses are
   accessed from cluster tiles via normal AXI reads/writes — no special handling needed.

3. **Torus vs. mesh**: WormholeB0 is a 2D torus (left/right and top/bottom edges
   connected). FlooNoC in picobello is a 2D mesh (no wrap-around). Route planning for
   broadcast rectangles must not assume wrap-around connectivity.

4. **Overlay vs. iDMA**: WormholeB0's overlay is the primary DMA engine for all
   inter-tile transfers. Picobello's iDMA is already integrated in the Snitch cluster.
   The `pb_overlay` module operates in *parallel* with iDMA (not replacing it), and the
   AXI master port is time-multiplexed using an arbiter.

5. **Harvest / coordinate translation**: WormholeB0's translation tables exist for
   yield management (fused-off rows). Picobello currently has no harvesting. The
   translation block should be implemented but initialised to identity by default,
   allowing future yield support without RTL changes.
