# Collective Software–Hardware Interface

Collectives use ordinary stores or DMA transfers. Software configures the AXI
AWUSER field first; the subsequent write transaction carries the collective
opcode and participant mask.

## Software API

```c
snrt_dma_start_1d_reduction(dst, src, bytes, comm, SNRT_REDUCTION_FADD);
snrt_dma_wait_all();

snrt_enable_reduction(mask, SNRT_REDUCTION_BARRIER);
*barrier_ptr = 0;
snrt_disable_reduction();
snrt_fence();
```

Use `snrt_dma_start_1d_mcast()` for DMA multicast, or
`snrt_enable_multicast()` around a scalar store. The implementations are in
the Snitch runtime `sw/runtime/src/{sync,dma}.h`.

## Instruction and Transaction Encoding

LSU software uses `csrw user_low` and `csrw user_high`; DMA software uses the
`dmuser` instruction. These configure later LSU stores or DMA copies,
respectively. The encoded 64-bit value is:

```text
bits [3:0]   collective opcode
bits [63:4]  collective address/participant mask
```

The active RTL consumes `collective_op[3:0]` and `collective_mask[47:0]`.

| Opcode | Operation |
|---:|---|
| 0 | Unicast |
| 1 | Multicast |
| 2 | Barrier / LsbAnd |
| 3 | FP add |
| 4 | FP multiply |
| 5 | FP minimum |
| 6 | FP maximum |

The Picobello DCA bridge supports the four FP operations. Integer operations
present in the software enum are not mapped by this bridge.

## Multicast Configuration

`snrt_enable_multicast(mask)` does not write an MMIO address and does not
start a separate multicast engine. It creates a `snrt_collective_t` with
opcode `SNRT_COLLECTIVE_MULTICAST` (`1`) and calls `snrt_set_awuser()`. The
latter writes the custom Snitch `user_low` and `user_high` CSRs. A later,
ordinary LSU store generates AXI `AW` and `W`; its `AWUSER` carries the saved
opcode and mask. FlooNoC decodes that metadata and forks the write to the
selected destinations.

```c
snrt_enable_multicast(mask);  // Configure AWUSER only.
*remote_destination = value; // Ordinary store launches the transaction.
snrt_disable_multicast();     // Clear AWUSER.
```

DMA follows the same model but uses `dmuser` to configure the DMA frontend.

## `dmuser` Custom Instruction

`dmuser rs1, rs2` is a custom Snitch DMA instruction. It does not access
memory, enqueue a DMA transfer, or return a value. It stores AXI user metadata
for a future `dmcpy` or `dmcpyi` command:

```text
USER[31:0]  = rs1[31:0]
USER[63:32] = rs2[31:0]  (truncated to the configured AXI user width)
```

The runtime emits it through inline C assembly:

```c
asm volatile ("dmuser %[lo], %[hi]"
              :: [lo] "r"(user_low), [hi] "r"(user_high));
```

For a collective DMA transfer, the normal sequence is:

```asm
dmsrc   ...            # Configure source address.
dmdst   ...            # Configure destination address.
dmuser  rs1, rs2       # Configure collective opcode and mask.
dmcpyi  rd, rs1, imm   # Enqueue/start the DMA transfer.
```

When `dmcpyi` builds its descriptor, it captures the saved user field. The
iDMA AXI writer later forwards it as `AWUSER`, where FlooNoC applies the
collective operation. A following `dmuser x0, x0`, emitted by
`snrt_dma_disable_multicast()` or `snrt_dma_disable_reduction()`, restores
unicast metadata.

`dmuser` uses RISC-V custom opcode `0b0101011` (`0x2b`), with `funct7 = 8`,
`funct3 = 0`, and `rd = x0`. For example, `dmuser x10, x11` encodes as
`0x10B5002B`.

The mnemonic is supported by the repository's custom Snitch LLVM toolchain,
not by a separate assembler script. Its opcode declaration is in
`sw/deps/riscv-opcodes/opcodes-dma_CUSTOM`; that declaration was incorporated
when building the LLVM toolchain. At application build time, Clang's integrated
assembler recognizes `dmuser` and emits the instruction into the ELF `.text`
section. The Snitch RTL then decodes it and forwards its operands to iDMA.

## Cluster Address Map

There are 16 cluster tiles, indexed as `c = 4*x + y`, for `x,y` in `0..3`.
Each has a 256 KiB global window:

```text
base(c) = 0x0000_2000_0000 + c * 0x0004_0000
range   = base(c) .. base(c) + 0x0003_FFFF
```

| Offset | Region |
|---:|---|
| `0x00000–0x1FFFF` | TCDM / L1 (128 KiB) |
| `0x20000–0x20FFF` | Boot ROM |
| `0x21000–0x211BF` | Cluster peripheral registers |
| `0x211A0` | Cluster interrupt set |
| `0x211A8` | Cluster interrupt clear |
| `0x30000–0x3EFFF` | Zero memory |

Use `snrt_remote_l1_ptr(ptr, src_cluster, dst_cluster)` rather than manual
address arithmetic; it applies the `0x40000` cluster stride. Collective
traffic is supported only by cluster tiles: memory/L2-SPM and Cheshire tiles
accept unicast transactions only.
