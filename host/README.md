# fpgapa-scope — host tool

Python host for the [fpga-scope](../README.md) embedded logic analyzer: configure, arm, download,
and export captures to **VCD** (GTKWave / Surfer) and **sigrok `.sr`** (PulseView). One frame
codec speaks to every transport — UART (pyserial), a CSR window, or a co-sim pipe — because the
codec speaks bytes only.

## Install

```sh
pip install -e host            # stdlib only
pip install -e 'host[serial]'  # add pyserial for the UART transport
```

## CLI

```sh
# liveness + identity
fpgapa-scope --port /dev/ttyUSB0 --baud 3000000 ping

# configure trigger / capture params (runtime, over CSR — no rebuild)
fpgapa-scope --port /dev/ttyUSB0 config --pretrig 256 --windows 1

# arm, wait for the trigger, download, and write a VCD with named signals
fpgapa-scope --port /dev/ttyUSB0 --probe-w 32 arm --wait \
    --out capture.vcd --probes probes.json
```

`probes.json` maps probe bit lanes to names (`[msb, lsb]`, inclusive); unmapped bits export as
`probe[k]`:

```json
{ "cs_n": [0, 0], "rwds": [1, 1], "state": [4, 2] }
```

## Library

```python
from fpgapa_scope import Scope, write_vcd
sc = Scope(transport, probe_w=32)     # transport: pyserial Serial / co-sim pipe / BytesTransport
sc.write_csr(fpgapa_scope.csr.PRETRIG, 256)
sc.arm(); sc.force_trig(); sc.wait_done()
cap = sc.drain(pretrig_eff=256)       # -> Capture (reordered, RLE-decoded)
write_vcd("out.vcd", cap.samples, cap.probe_w, trig_pos=cap.trig_pos)
```

## Verification

`pytest host/tests` (run in CI):
- **frame codec** — build/parse round-trip, CRC16-CCITT **cross-checked against `sim/model/scope_ref.py`** (which the RTL is proven against in `tb_uart`/`tb_drain_cdc`, so a match here is a match to silicon), corrupted-CRC → error, resync after garbage, NAK; decode of DRAIN_DATA frames produced by the SV-side `scope_ref.cmd_drain_data`.
- **reorder** — the DESIGN.md issue-#7 worked examples + an end-to-end DRAIN decode placing the trigger sample correctly.
- **RLE decode** — matches `scope_ref.rle_decode` across widths.
- **VCD** — round-trips named + bus signals + the trigger marker through a minimal VCD reader.

**Remaining for full #10 acceptance:** the sigrok `.sr` writer, and the Verilator co-simulation
that drives the real `scope_top` (XPORT="STREAM") over a pipe end-to-end (ping → config → arm →
stimulate → download → VCD vs `scope_ref`). GTKWave/PulseView load-checks are a manual one-time step.
