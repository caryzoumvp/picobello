# In-Network Reduction RTL

The in-network reduction implementation is mainly supplied by the FlooNoC
Bender dependency:

- Router integration: `.bender/git/checkouts/floo_noc-051cdbf4a4876727/hw/floo_router.sv`
- Parallel/narrow reduction: `hw/floo_reduction_arbiter.sv`
- Input synchronization: `hw/floo_reduction_sync.sv`
- Wide/sequential reduction controller: `hw/floo_reduction_unit.sv`
- Output selection: `hw/floo_output_arbiter.sv`
- Collective opcodes and configuration: `hw/floo_pkg.sv`

The Picobello-specific Direct Compute Access (DCA) bridge is implemented in
`hw/cluster_tile.sv`. It maps FlooNoC `FpAdd`, `FpMul`, `FpMin`, and `FpMax`
offload requests onto the Snitch cluster's DCA FPU interface.

## Execution Path

```text
Collective AXI AW request
  -> NI encodes collective opcode and coordinate mask
  -> floo_nw_router selects the wide or narrow router
  -> floo_router detects reduction traffic
  -> floo_reduction_sync waits for all participating inputs
  -> floo_reduction_unit emits the two operands on offload_req
  -> cluster_tile maps the requested operation to Snitch DCA
  -> Snitch FPUs compute the vector result
  -> offload_rsp returns the result to floo_reduction_unit
  -> router reattaches the header and forwards a unicast result
```

## Reduction Classes

The narrow, router-local `floo_reduction_arbiter` implements:

- `CollectB`: merges AXI B responses for multicast.
- `LsbAnd`: AND-reduces payload bit zero for barriers.
- `SelectAW`: selects an AW flit for parallel reduction.

Wide arithmetic reductions use the sequential `floo_reduction_unit` and the
cluster DCA path. The supported operations are floating-point add, multiply,
minimum, and maximum.

This organization corresponds to Sections 3.1.3 through 3.2.1 of the paper,
*A Lightweight High-Throughput Collective-Capable NoC for Large-Scale ML
Accelerators* (arXiv:2603.26438).
