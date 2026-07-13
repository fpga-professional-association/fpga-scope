# fpga-scope — Vendor-Neutral Embedded Logic Analyzer

A drop-in, instantiate-in-RTL logic analyzer that replaces SignalTap / ChipScope-ILA / Reveal
for **any FPGA and any flow**, including Yosys+nextpnr users who currently have nothing.
Capture into BRAM in the probe's clock domain, trigger on comparator/edge/sequence conditions,
drain over a byte-stream transport (UART built in; CSR window for Avalon-MM/AXI-Lite; anything
else via the exposed stream), view in GTKWave/Surfer/PulseView via a Python host tool. This is
the productized form of the [hyperram](https://github.com/fpga-professional-association/hyperram)
repo's `hyperram_bw_test` instrumentation pattern. Clean-room SystemVerilog, no vendor
primitives, Apache-2.0.

Design document: [docs/PLAN.md](docs/PLAN.md) ·
Interface contract: [docs/INTERFACES.md](docs/INTERFACES.md) ·
Architecture: [docs/DESIGN.md](docs/DESIGN.md) ·
Tracker: [issue #1](https://github.com/fpga-professional-association/fpga-scope/issues/1)

## Status

| Milestone | Content | Issue | Status |
|---|---|---|---|
| M0 | Repo bootstrap: skeleton, CI, sim harness, INTERFACES.md v0 | [#2](https://github.com/fpga-professional-association/fpga-scope/issues/2) | done |
| M0 | Primitive library `rtl/prim/`: ff_sync, sync/async FIFOs, 1r1w RAM | [#3](https://github.com/fpga-professional-association/fpga-scope/issues/3) | done |
| M1 | Capture core: `scope_pkg` + `scope_core` + golden ref | [#4](https://github.com/fpga-professional-association/fpga-scope/issues/4) | done |
| M2 | CSR block + INTERFACES.md v1 freeze | [#5](https://github.com/fpga-professional-association/fpga-scope/issues/5) | done |
| M3 | Trigger engine: comparators + combine + sequencer | [#6](https://github.com/fpga-professional-association/fpga-scope/issues/6) | done |
| M4 | Pre-trigger + capture windows | [#7](https://github.com/fpga-professional-association/fpga-scope/issues/7) | done |
| M5 | Drain + CDC + UART + `scope_top` assembly | [#8](https://github.com/fpga-professional-association/fpga-scope/issues/8) | done |
| M6 | RLE encoder (`scope_rle` + model + formal) | [#9](https://github.com/fpga-professional-association/fpga-scope/issues/9) | encoder done; `scope_top` integration open |
| M7 | Python host (`fpgapa-scope`): frame codec, VCD/sigrok export | [#10](https://github.com/fpga-professional-association/fpga-scope/issues/10) | open |
| M8 | Bus front-ends: Avalon-MM + AXI4-Lite | [#11](https://github.com/fpga-professional-association/fpga-scope/issues/11) | done |
| M9 | AXC3000 board demo: scope watching hyperram bring-up | [#12](https://github.com/fpga-professional-association/fpga-scope/issues/12) | open (hardware ready) |
| v1.0 | Acceptance: random-config soak, 3 Mbaud drain, dual-instance | [#13](https://github.com/fpga-professional-association/fpga-scope/issues/13) | open |

8 of 13 milestone issues closed. The core RTL — capture, CSR, trigger, pre-trigger + windows,
drain/CDC/UART + `scope_top`, RLE encoder, and the Avalon-MM/AXI4-Lite front-ends — is done,
`-Wall` clean, with all four SBY formal properties proving in CI.

## Features

**Capture** — single probe group up to 512 bits, BRAM depth 2^N (N = 8..15), sampled every
probe-clock edge · pre/post-trigger circular capture · N capture windows per arm (segmented) ·
48-bit timestamp · optional run-length compression.

**Trigger** — 4 comparator units (mask/value + per-bit rising/falling edge) with AND/OR combine ·
4-stage sequencer with occurrence counters · `force_trig` "just show me the bus" button ·
cross-instance triggering (`trig_ext_i/o`) · all runtime-reconfigurable over CSR, no rebuild.

**Readout** — one framed byte-stream codec over any transport: built-in **UART** (pins to a $2
USB dongle), a **CSR** window with thin **Avalon-MM** and **AXI4-Lite** front-ends (drops into
Platform Designer / Vivado block designs), or a raw byte stream. A Python host (in progress, #10)
exports **VCD** (GTKWave / Surfer) and **sigrok `.sr`** (PulseView).

**Quality** — clean-room SystemVerilog, no vendor primitives, one clock-domain crossing, capture
path never stalls on the transport · self-checking Verilator testbenches + four SBY formal proofs
in CI · works instantiated twice in one design (per-instance `ID_VALUE`).

## Why not just use the vendor ILA?

SignalTap, ChipScope/ILA, and Reveal are each excellent — inside one vendor's walled garden.
fpga-scope is **one open, spec'd, formally-verified core that works on every FPGA and every flow,
including Yosys+nextpnr, which has no ILA at all**, drains without a JTAG cable (UART or on-chip
bus), and writes open waveform formats. Full capability matrix, honestly marked (✅ shipped /
🟡 partial / 🔜 planned), and the gaps where the vendor GUIs still lead: **[docs/COMPARISON.md](docs/COMPARISON.md)**.

## Hardware bring-up (M9)

The board demo targets the **Arrow AXC3000** (Agilex 3 `A3CY100BM16AE7S`) over a **USB Blaster III**,
reusing the [hyperram](https://github.com/fpga-professional-association/hyperram) repo's proven
flow: build in the `alterafpga/quartus-pro:26.1-agilex3` container, program with `quartus_pgm`,
and drive the CSR/UART readout from `system-console` (or straight UART) — all under the shared
`/tmp/axc3000-devkit.lock`. See [issue #12](https://github.com/fpga-professional-association/fpga-scope/issues/12).

## Verify

All testbenches are self-checking (`$fatal` on mismatch, `TB_RESULT: PASS`/`FAIL` contract) and
run under stock Verilator ≥ 5.0 (`--binary --timing -Wall`):

```sh
bash sim/run.sh
```

The script exits non-zero if any testbench fails; CI runs the same script on every push.

## Quickstart (stub — grows with the milestones)

1. Instantiate `scope_top` in your design, wire `probe[PROBE_W-1:0]` to the signals you want to
   watch, and connect the UART pins (or the byte-stream / CSR ports). *(lands at M5, issue #8)*
2. `pip install fpgapa-scope`, then `fpgapa-scope arm && fpgapa-scope download --vcd out.vcd`.
   *(lands at M7, issue #10)*
3. Open the VCD in GTKWave / Surfer / PulseView.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
