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

*(none yet — record every deviation here with the issue number and rationale)*

## Milestone notes

### M0 (issues #2, #3)

- Repo skeleton, sim harness, and CI follow the sibling `../hyperram` repo verbatim
  (`sim/run.sh` contract, `TB_RESULT: PASS/FAIL`, `verilator --binary --timing -Wall`).
- The external `fpgapa-prim` dependency named in PLAN.md does not exist; the primitives are
  vendored under `rtl/prim/` (issue #3), written to be extracted later unchanged.
