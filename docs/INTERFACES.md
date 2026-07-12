# fpga-scope — Interface Contract

**v1 — FROZEN at M2 (issue #5).** This file is **normative for module boundaries and the
host-visible register/frame contract**: no port name, direction, width, CSR offset, bit
packing, or frame byte may change without a documented interface-revision note here (and a
major-version bump of `SCOPE_VERSION` for host-visible changes). Internals are free.
`rtl/scope_pkg.sv` mirrors the constants defined here, one for one.

Revision history:
- v1 (M2, issue #5): CSR bus timing defined (combinational rdata); CSR map frozen — wide
  comparator config resolved as the CMP_SEL + lane-window scheme (replaces the draft
  `16+4k` linear layout, which only fits PROBE_W ≤ 32); TRIG_INDEX/TSTRIG_LO/TSTRIG_HI
  registers added (a CSR-only host cannot reorder the buffer without them); exact
  HWCFG/STATUS packings; TS_LO shadow-latch rule; frame opcode values fixed.
- v0 (M0, issue #2): draft transcription of PLAN.md §4/§6.

Legend: dir `I`=input, `O`=output. Widths use the parameters defined below. All interfaces are
synchronous to their stated clock, reset by synchronous active-high reset, unless noted.

Shared handshake rule (all `*_valid`/`*_ready` channels): **transfer happens on the cycle where
both `valid` and `ready` are high**; `valid` must not depend combinationally on `ready`.

---

## `scope_top` parameters

| Parameter | Range / default | Meaning |
|---|---|---|
| `PROBE_W` | 1..512 | probe group width in bits |
| `DEPTH_LOG2` | 8..15 | capture buffer depth = 2^`DEPTH_LOG2` samples |
| `NUM_CMP` | 4 (fixed in v1.0) | comparator units |
| `SEQ_STAGES` | 4 (fixed in v1.0) | trigger sequencer stages |
| `RLE_EN` | 0/1 | instantiate the run-length encoder |
| `TS_W` | 48 | timestamp counter width |
| `XPORT` | `"UART"` \| `"CSR"` \| `"STREAM"` | transport selection |
| `UART_DIV` | ≥ 1 | UART clock divisor = `xclk` frequency / baud |
| `ID_VALUE` | 32-bit | user tag readable over the transport |

## `scope_top` ports

| Port | Dir | Width | Notes |
|---|---|---|---|
| `clk` | I | 1 | probe/capture domain |
| `rst` | I | 1 | synchronous, active high, capture domain |
| `probe` | I | `PROBE_W` | sampled every `clk`; register externally if timing needs it |
| `trig_ext_i` | I | 1 | external/cross-instance trigger in |
| `trig_ext_o` | O | 1 | trigger out (fires when this instance triggers) |
| `xclk` | I | 1 | transport domain clock (may equal `clk`) |
| `xrst` | I | 1 | synchronous, active high, transport domain |
| `rx_data` | I | 8 | byte stream in (host→scope), `xclk` domain |
| `rx_valid` | I | 1 | |
| `rx_ready` | O | 1 | |
| `tx_data` | O | 8 | byte stream out (scope→host), `xclk` domain |
| `tx_valid` | O | 1 | |
| `tx_ready` | I | 1 | |
| `uart_rx` | I | 1 | only meaningful when `XPORT="UART"` |
| `uart_tx` | O | 1 | only meaningful when `XPORT="UART"` |
| `armed` | O | 1 | status (LED-friendly), capture domain |
| `triggered` | O | 1 | status (LED-friendly), capture domain |

Exactly **one CDC** exists in the design: drain/CSR traffic crosses `clk`↔`xclk` through two
`prim_fifo_async` instances (cmd in, data out). Capture logic never crosses domains anywhere
else and never stalls on the transport.

---

## Primitive library `rtl/prim/` (issue #3)

The only modules allowed to contain CDC logic or memory inference. Written to be vendored into
sibling repos unchanged.

### `prim_ff_sync` — N-stage flip-flop synchronizer

Parameters: `WIDTH` (default 1), `STAGES` (default 2), `ASYNC_RST` (default 0: sync reset;
1: async-assert reset), `RESET_VAL` (default '0). For quasi-static level/flag signals or
gray-coded values (≤1 bit changes per source edge) only — never multi-bit binary buses that
change per-cycle.

| Port | Dir | Width | Notes |
|---|---|---|---|
| `clk` | I | 1 | destination domain |
| `rst` | I | 1 | synchronous, active high; clears the chain |
| `d` | I | `WIDTH` | source-domain level |
| `q` | O | `WIDTH` | synchronized level, `STAGES` cycles later |

### `prim_ram_1r1w` — simple-dual-port RAM

Parameters: `WIDTH`, `DEPTH_LOG2`. One synchronous write port, one synchronous read port,
1-cycle read latency, inferred BRAM. **Read-during-write policy: "old data"** (same-cycle
same-address read returns pre-write content). No reset on the array; no bypass logic.

| Port | Dir | Width | Notes |
|---|---|---|---|
| `clk` | I | 1 | single clock, both ports |
| `wr_en` | I | 1 | |
| `wr_addr` | I | `DEPTH_LOG2` | |
| `wr_data` | I | `WIDTH` | |
| `rd_en` | I | 1 | read-address strobe |
| `rd_addr` | I | `DEPTH_LOG2` | |
| `rd_data` | O | `WIDTH` | valid 1 cycle after `rd_en` |

### `prim_fifo_sync` — single-clock FIFO (FWFT)

Parameters: `WIDTH`, `DEPTH_LOG2` (capacity = exactly 2^`DEPTH_LOG2` items, the FWFT output
stage counted; the full flag is exact). First-word-fall-through: `rd_data` is valid whenever
`rd_valid` is high; pop on `rd_valid && rd_ready`; `rd_valid` may lag a push into an empty
FIFO by ≤2 cycles (prefetch fill). Storage is `prim_ram_1r1w`.

| Port | Dir | Width | Notes |
|---|---|---|---|
| `clk`, `rst` | I | 1 | sync reset, active high |
| `wr_data` | I | `WIDTH` | |
| `wr_valid` | I | 1 | push on `wr_valid && wr_ready` |
| `wr_ready` | O | 1 | low exactly when full |
| `rd_data` | O | `WIDTH` | FWFT |
| `rd_valid` | O | 1 | low exactly when empty |
| `rd_ready` | I | 1 | pop on `rd_valid && rd_ready` |

### `prim_fifo_async` — dual-clock FIFO (FWFT, gray-coded pointers)

Same handshake contract as `prim_fifo_sync`; classic Cummings design (binary pointers
gray-encoded, crossed with `prim_ff_sync`, full/empty from synchronized opposite-domain
pointers). Parameters: `WIDTH`, `DEPTH_LOG2`, `SYNC_STAGES` (default 2). Usable capacity is
2^`DEPTH_LOG2` + 1 items (RAM ring plus the FWFT output stage). Storage is a flop/LUTRAM
array (not `prim_ram_1r1w`, which is single-clock) — intended for shallow CDC crossings.
Flags are exact but pessimistic across the pointer synchronizers: `wr_ready` may hold low up
to 2×`SYNC_STAGES` wclk after the read side frees space; a pushed word becomes `rd_valid`
after ~`SYNC_STAGES`+2 rclk. Never overflows, underflows, drops, duplicates, or reorders.

| Port | Dir | Width | Notes |
|---|---|---|---|
| `wclk`, `wrst` | I | 1 | write domain; sync reset, active high |
| `wr_data` | I | `WIDTH` | |
| `wr_valid` | I | 1 | |
| `wr_ready` | O | 1 | low exactly when full (write-domain view) |
| `rclk`, `rrst` | I | 1 | read domain; sync reset, active high |
| `rd_data` | O | `WIDTH` | FWFT |
| `rd_valid` | O | 1 | low exactly when empty (read-domain view) |
| `rd_ready` | I | 1 | |

Both resets must be asserted together (and each held ≥ `SYNC_STAGES`+1 cycles of its own clock)
before first use; nothing crosses during reset.

---

## Native CSR bus — v1 FROZEN (issue #5)

One bus contract, three masters: the drain engine (issue #8), `scope_avalon` and
`scope_axil` (issue #11). Word-addressed, single clock (`clk`, capture domain), zero wait
states. Mirrors the CSR slave convention of the hyperram repo's `hyperram_bw_test.sv`.

| Signal | Dir (slave) | Width | Notes |
|---|---|---|---|
| `csr_addr` | I | 8 | word address; register `k` sits at host byte offset `4*k` |
| `csr_wdata` | I | 32 | |
| `csr_write` | I | 1 | 1-cycle strobe; write commits at that clock edge |
| `csr_rdata` | O | 32 | **combinational** on `csr_addr` (zero wait states) |
| `csr_read` | I | 1 | 1-cycle strobe; REQUIRED for read-side-effect registers |

Timing rules (frozen):
- `csr_rdata` is combinational: a synchronous master samples it at the same clock edge that
  consumes its `csr_read` strobe.
- Read side effects (`BUF_DATA` pop, `TS_LO` shadow latch) occur at the edge consuming
  `csr_read`. Reads without the strobe still see valid data but trigger no side effects.
- Reserved/unmapped addresses read 0; writes to them are ignored (no `cfg_err`).

## CSR map — v1 FROZEN (32-bit registers, byte offset = index × 4)

`L` = ⌈`PROBE_W`/32⌉ implemented lanes (1..16). Reset values in parentheses.

| Idx | Name | Access | Contents |
|---|---|---|---|
| 0 | `ID` | RO | `0x5C09E000 \| SCOPE_VERSION` = `0x5C09E001` for v1 |
| 1 | `HWCFG` | RO | `[9:0]` PROBE_W, `[13:10]` DEPTH_LOG2, `[17:14]` NUM_CMP, `[18]` RLE_EN, `[31:19]` 0 |
| 2 | `CTRL` | W strobe | `[0]` arm, `[1]` disarm, `[2]` force_trig, `[3]` soft_rst — self-clearing, reads as 0 |
| 3 | `STATUS` | RO | `[2:0]` state (scope_pkg encoding), `[3]` triggered, `[4]` wrapped, `[5]` cfg_err (sticky), `[7:6]` 0, `[15:8]` windows_done, `[31:16]` 0 |
| 4 | `PRETRIG` | RW (0) | samples to keep before trigger; stored/read back truncated to `DEPTH_LOG2` bits |
| 5 | `WINDOWS` | RW (1) | captures per arm, 1..255; a write of 0 is stored as 1 |
| 6 | `RLE_CTRL` | RW (0) | `[0]` rle_enable (meaningful only when `RLE_EN=1`); other bits reserved-as-0 |
| 7 | `TS_LO` | RO | free-running timestamp `[31:0]`; **reading it latches `ts[47:32]` into the TS_HI shadow** |
| 8 | `TS_HI` | RO | the shadow latched by the last `TS_LO` read (coherent 48-bit reads) |
| 9 | `TRIG_INDEX` | RO | buffer address of the trigger sample (zero-extended) |
| 10 | `TSTRIG_LO` | RO | `ts_at_trig[31:0]` — timestamp of the trigger sample |
| 11 | `TSTRIG_HI` | RO | `ts_at_trig[47:32]` (zero-extended; no shadow needed, value is static after capture) |
| 15 | `CMP_SEL` | RW (0) | `[1:0]` comparator k (0..3), `[3:2]` field: 0=MASK, 1=VALUE, 2=EDGE_MASK, 3=EDGE_POL |
| 16..31 | `CMP_LANE[0..15]` | RW (0) | lane window of the field selected by `CMP_SEL`: word 16+j = probe bits `[32j+31:32j]`. Lanes ≥ L read 0 / drop writes; bits ≥ `PROBE_W` in the top lane read 0 |
| 64 | `TRIG_COMBINE` | RW (0) | stage n in bits `[8n+7:8n]`: `[3:0]` comparator select mask, `[4]` 1=AND of selected / 0=OR of selected, `[7:5]` reserved-as-0 |
| 65..68 | `SEQ_CNT0..3` | RW (1) | qualifying occurrences to advance sequencer stage n; 0 is treated as 1 |
| 96 | `BUF_CTRL` | W strobe | `[0]` drain start: resets the drain pointer to sample 0, lane 0 |
| 97 | `BUF_DATA` | RO, pop | each `csr_read` returns the next 32-bit lane of the current sample, lane-then-address order (L pops per sample, `DEPTH×L` pops per full buffer). First read ≥ 1 cycle after `BUF_CTRL` (RAM latency; any real transport satisfies this) |

Behavioral rules (frozen):
- **cfg_err lockout** (PLAN.md §6.4): any `csr_write` to the config address set
  {`PRETRIG`, `WINDOWS`, `RLE_CTRL`, `CMP_SEL`, `CMP_LANE[*]`, `TRIG_COMBINE`, `SEQ_CNT*`}
  while `STATUS.state != IDLE` is **ignored** and sets sticky `STATUS.cfg_err`. `cfg_err`
  clears **only on soft_rst** (accepted-write clearing would hide earlier errors).
- **force_trig** (PLAN.md §6.5): CTRL bit2 latches a pending force when strobed in
  FILLING/ARMED (ignored in IDLE/DONE — no capture to force); the pending force holds the
  core's `trig` input high until accepted at the first ARMED cycle with a valid sample, so
  it works even if comparators never match and across `sample_valid` gaps. Cleared by
  acceptance, disarm, soft_rst, or the run ending.
- **soft_rst**: disarms the core (FSM → IDLE) and clears `cfg_err`, the pending force, the
  drain pointer, and the TS shadow. It never touches capture BRAM contents or the config
  registers.
- `arm`/`disarm` are single-cycle pulses to the core, aligned to the CTRL write edge.

---

## Drain frame format — v1 FROZEN (byte stream, both transports)

```
0xA5 0x5C | cmd (1 byte) | len16 (2 bytes) | payload (len16 bytes) | crc16 (2 bytes)
```

- All multi-byte protocol fields (`len16`, CRC16, CSR addresses/data in payloads, drain
  header fields) are transmitted **big-endian** (network order) — one rule everywhere.
- CRC16-CCITT (poly 0x1021, init 0xFFFF) computed over `cmd..payload`.
- Command opcodes (scope_pkg): `PING`=0x01, `READ_CSR`=0x02, `WRITE_CSR`=0x03, `DRAIN`=0x04;
  error reply `NAK`=0x15 (bad CRC / unknown cmd). `DRAIN` returns a header
  `{trig_index, wrapped, ts48, rle_flag}` followed by samples (exact header packing fixed in
  issue #8 within this frame envelope).
- UART is 8N1, LSB-first bit order (standard), fixed divisor `UART_DIV`; auto-baud is v2.
- Same codec on both transports → one Python decoder (`host/fpgapa_scope/`).
