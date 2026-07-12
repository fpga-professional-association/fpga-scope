// scope_pkg — shared types, opcodes, and CSR offsets for the fpga-scope embedded logic analyzer.
//
// Single source of truth (no magic numbers elsewhere): the capture-FSM state encoding, the
// drain-frame protocol constants, the CSR word offsets, and the ID register value all live
// here. Interface contract: docs/INTERFACES.md (v0 DRAFT — offsets/opcodes freeze at M2,
// issue #5). Architecture: docs/DESIGN.md.
package scope_pkg;

  /* verilator lint_off UNUSEDPARAM */
  // waiver: this package is the single source of truth for the whole design; the frame
  // opcodes and CSR offsets are consumed by scope_csr/scope_drain (issues #5/#8) — they are
  // "unused" only until those modules land.

  // ------------------------------------------------------------------------------------
  // Capture FSM state encoding — these values ARE the STATUS.state[2:0] field read by the
  // host (INTERFACES.md CSR map), not just an internal enum. Do not renumber after M2.
  //   IDLE      0: not armed; buffer readable from the last completed capture
  //   FILLING   1: armed, storing the PRETRIG backlog; triggers not yet accepted
  //   ARMED     2: circular capture, write pointer free-running, triggers accepted
  //   TRIGGERED 3: trigger latched, storing the DEPTH-PRETRIG post-trigger samples
  //   DONE      4: capture window complete; write pointer frozen
  // ------------------------------------------------------------------------------------
  typedef enum logic [2:0] {
    SCOPE_ST_IDLE      = 3'd0,
    SCOPE_ST_FILLING   = 3'd1,
    SCOPE_ST_ARMED     = 3'd2,
    SCOPE_ST_TRIGGERED = 3'd3,
    SCOPE_ST_DONE      = 3'd4
  } scope_state_e;

  // ------------------------------------------------------------------------------------
  // ID register: magic | version (CSR word 0). The 32-bit user tag lives in the ID_VALUE
  // parameter of scope_top and is readable separately (placement fixed at the M2 freeze).
  // ------------------------------------------------------------------------------------
  localparam logic [31:0] SCOPE_ID_MAGIC = 32'h5C09E000;
  localparam logic [7:0]  SCOPE_VERSION  = 8'h01;
  localparam logic [31:0] SCOPE_ID_REG   = SCOPE_ID_MAGIC | {24'h0, SCOPE_VERSION};

  // ------------------------------------------------------------------------------------
  // Drain frame protocol (issue #8): 0xA5 0x5C | cmd | len16 | payload | crc16-ccitt.
  // CRC16-CCITT poly 0x1021 init 0xFFFF over cmd..payload, big-endian on the wire.
  // ------------------------------------------------------------------------------------
  localparam logic [7:0] SCOPE_SYNC0 = 8'hA5;
  localparam logic [7:0] SCOPE_SYNC1 = 8'h5C;

  localparam logic [7:0] SCOPE_OP_PING      = 8'h01;
  localparam logic [7:0] SCOPE_OP_READ_CSR  = 8'h02;
  localparam logic [7:0] SCOPE_OP_WRITE_CSR = 8'h03;
  localparam logic [7:0] SCOPE_OP_DRAIN     = 8'h04;
  localparam logic [7:0] SCOPE_OP_NAK       = 8'h15;  // ASCII NAK; response to bad CRC/cmd

  // ------------------------------------------------------------------------------------
  // CSR word offsets (byte offset = index * 4) — draft map from INTERFACES.md v0.
  // ------------------------------------------------------------------------------------
  localparam int unsigned CSR_ID           = 0;
  localparam int unsigned CSR_HWCFG        = 1;
  localparam int unsigned CSR_CTRL         = 2;
  localparam int unsigned CSR_STATUS       = 3;
  localparam int unsigned CSR_PRETRIG      = 4;
  localparam int unsigned CSR_WINDOWS      = 5;
  localparam int unsigned CSR_RLE_CTRL     = 6;
  localparam int unsigned CSR_TS_LO        = 7;
  localparam int unsigned CSR_TS_HI        = 8;
  localparam int unsigned CSR_CMP_BASE     = 16;  // + 4*k for comparator k (see INTERFACES.md)
  localparam int unsigned CSR_TRIG_COMBINE = 64;
  localparam int unsigned CSR_SEQ_CNT_BASE = 65;  // 65..68 = SEQ_CNT0..3
  localparam int unsigned CSR_BUF_CTRL     = 96;
  localparam int unsigned CSR_BUF_DATA     = 97;
  /* verilator lint_on UNUSEDPARAM */

endpackage
