# fpga-scope — Interface Contract

**v0 — DRAFT, frozen at M2 (issue #5).** Until the M2 freeze, the design document
([PLAN.md](PLAN.md), §4/§6) wins where this file and it disagree. After the freeze this file is
**normative for module boundaries**: no port name, direction, width, CSR offset, or frame byte
may change without a documented interface-revision note here. Internals are free.

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

## CSR map — DRAFT (32-bit registers, byte offset = index × 4)

Frozen at M2 (issue #5). `k` = comparator index 0..3, `L` = ⌈`PROBE_W`/32⌉ lanes.

| Idx | Name | Access | Contents |
|---|---|---|---|
| 0 | `ID` | RO | magic `0x5C09E000` \| version; instance tag via `ID_VALUE` readback (placement TBD at freeze) |
| 1 | `HWCFG` | RO | `PROBE_W`, `DEPTH_LOG2`, `NUM_CMP`, `RLE_EN` packed (bitfields fixed at freeze) |
| 2 | `CTRL` | WO/W1P | arm, disarm, force_trig, soft_rst |
| 3 | `STATUS` | RO | state[2:0], triggered, wrapped, windows_done[7:0], cfg_err (sticky) |
| 4 | `PRETRIG` | RW | samples to keep before trigger, 0..2^`DEPTH_LOG2`−1 |
| 5 | `WINDOWS` | RW | captures per arm, 1..255 |
| 6 | `RLE_CTRL` | RW | RLE enable/config (only when `RLE_EN=1`) |
| 7 | `TS_LO` | RO | free-running timestamp[31:0] |
| 8 | `TS_HI` | RO | free-running timestamp[`TS_W`−1:32] |
| 16+4k .. | `CMPk_MASK` | RW | ×L lanes, then `CMPk_VALUE` ×L, `CMPk_EDGE_MASK` ×L, `CMPk_EDGE_POL` ×L (exact lane layout fixed at freeze) |
| 64 | `TRIG_COMBINE` | RW | per-stage: 4-bit comparator select mask + AND/OR bit |
| 65..68 | `SEQ_CNT0..3` | RW | occurrences to advance stage n |
| 96 | `BUF_CTRL` | WO/W1P | drain start |
| 97 | `BUF_DATA` | RO | pops one buffer word per read |

Config-lockout rule (design doc §6.4): CSR writes to trigger/window config while `state!=IDLE`
are ignored and set sticky `STATUS.cfg_err`.

---

## Drain frame format — DRAFT (byte stream, both transports)

```
0xA5 0x5C | cmd (1 byte) | len16 (2 bytes) | payload (len16 bytes) | crc16 (2 bytes)
```

- CRC16-CCITT (poly 0x1021, init 0xFFFF) computed over `cmd..payload`, transmitted
  **big-endian** (high byte first) on the wire.
- `len16` byte order fixed at freeze (M2).
- Commands: `PING`, `READ_CSR`, `WRITE_CSR`, `DRAIN` (returns a header
  `{trig_index, wrapped, ts48, rle_flag}` followed by samples). Opcode values fixed at freeze.
- UART is 8N1, LSB-first (standard), fixed divisor `UART_DIV`; auto-baud is v2.
- Same codec on both transports → one Python decoder (`host/fpgapa_scope/`).
