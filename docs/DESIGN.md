# fpga-scope — Architecture & Design Notes

Stub at M0 — grows with each milestone. Source of truth for interfaces is
[INTERFACES.md](INTERFACES.md) (normative after the M2 freeze); the full design document is
[PLAN.md](PLAN.md). This file records the architecture, the policy decisions, and any
deviations from the plan made during implementation.

## Block architecture (PLAN.md §5)

```
probe ─►[scope_trigger]──trig──►┐
probe ─►(opt scope_rle)─►[scope_core: DEPTH×(PROBE_W+TS?) simple-dual-port BRAM,
                                  write ptr free-runs while armed, stop_cnt after trig]
                                  │ read port (drain, same clk)
                    [scope_csr]◄──┤            capture domain
   ══════ prim_fifo_async ═══════╪═══════════  transport domain
                    [scope_drain: frames buffer + CSR reads into byte stream]──►[scope_uart | if/*]
```

- **Capture FSM (`scope_core`):** `IDLE → FILLING (until pretrig satisfied) → ARMED (circular)
  → TRIGGERED (count post = DEPTH−PRETRIG) → DONE → (windows left? re-arm : IDLE)`. The trigger
  sample itself is always stored, and its buffer index is latched (`trig_index`).
- **Trigger:** all comparator/sequencer outputs are registered; the 1-cycle trigger latency is
  specified behavior, not an implementation accident.
- **Clock domains:** exactly one CDC in the whole design — drain/CSR traffic through two
  `prim_fifo_async` (cmd in, data out). The capture path never stalls on the transport.

## Policy decisions

| # | Decision | Where asserted |
|---|---|---|
| 1 | `prim_ram_1r1w` read-during-write returns **old data**; the whole design assumes it | `sim/tb_prim_ram.sv` (issue #3) |
| 2 | Trigger latency is 1 registered cycle | `docs/INTERFACES.md`, trigger TBs (issue #6) |
| 3 | Trigger index refers to the **raw sample count**, carried sideband through RLE | `sim/tb_rle.sv` (issue #9) |
| 4 | Timestamps are captured in the probe domain and drained through the same FIFO as data | drain TBs (issue #8) |
| 5 | UART is LSB-first; CRC16-CCITT is big-endian on the wire | first two assertions of `sim/tb_uart.sv` (issue #8) |

## Deviations from PLAN.md

| Issue | Deviation | Rationale |
|---|---|---|
| #3 | `prim_fifo_async` storage is a flop/LUTRAM array with combinational read, not `prim_ram_1r1w` | `prim_ram_1r1w` is single-clock; a dual-clock FIFO needs its write port in `wclk` and read in `rclk`. The array is safe (slot content is stable ≥ SYNC_STAGES rclk before the read pointer can reach it) and is the classic Cummings shape. Intended for shallow CDC crossings only. |
| #3 | `prim_fifo_async` usable capacity is 2^`DEPTH_LOG2` + 1 (RAM ring + FWFT output stage); `prim_fifo_sync` capacity is exactly 2^`DEPTH_LOG2` | FWFT over a 1-cycle-latency RAM needs a prefetched output register. The sync FIFO counts that register inside its capacity budget (exact full flag, one RAM slot idles while the output stage holds data); the async FIFO cannot without adding a cross-domain count, so its extra stage adds one slot. Both are documented in INTERFACES.md and asserted in the TBs. |

## Milestone notes

### M0 (issues #2, #3)

- Repo skeleton, sim harness, and CI follow the sibling `../hyperram` repo verbatim
  (`sim/run.sh` contract, `TB_RESULT: PASS/FAIL`, `verilator --binary --timing -Wall`).
- The external `fpgapa-prim` dependency named in PLAN.md does not exist; the primitives are
  vendored under `rtl/prim/` (issue #3), written to be extracted later unchanged.
- FWFT discipline (both FIFOs): the oldest word is prefetched into an output register
  whenever the ring is non-empty and the register is empty or being popped, so `rd_data`
  never changes under a stalled consumer and throughput is 1 word/cycle.
- `prim_fifo_async` reset contract: assert `wrst` and `rrst` together (overlapping), each
  ≥ `SYNC_STAGES`+2 cycles of its own clock; each side is inert (ready/valid low) while its
  reset is asserted, so nothing crosses during reset. Asserted in `tb_prim_fifo_async`.
- `tb_prim_fifo_async` soaks ≥110k scoreboarded transfers per leg at 3:1, 1:3, and ~1:1
  drifting-phase clock ratios, with directed fill-to-full/drain-to-empty and flag-exactness
  checks. A fault-injection run (broken full detection) was verified to trip the scoreboard.
