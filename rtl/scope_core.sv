// scope_core — capture RAM controller: circular buffer + window FSM (capture domain only).
//
// Architecture: docs/DESIGN.md. Interface contract: docs/INTERFACES.md. Shared defs:
// rtl/scope_pkg.sv. Golden reference: sim/model/scope_ref.py (capture_model replays the
// same cycle-exact semantics).
//
// Responsibilities:
//   * Store `sample_data` into a DEPTH x PROBE_W circular buffer (prim_ram_1r1w, "old data"
//     read-during-write policy per issue #3) on every `sample_valid` cycle while capturing.
//     THE WRITE PATH HAS NO READY/BACK-PRESSURE — the capture side never stalls on the
//     transport (tracker rule 1). The buffer read port is same-clock, for the drain.
//   * Capture FSM: IDLE -> FILLING (store PRETRIG samples) -> ARMED (write pointer
//     free-runs, circular) -> TRIGGERED (store DEPTH-PRETRIG post-trigger samples, the
//     trigger sample counted as the first) -> DONE -> (windows remaining ? FILLING : stay
//     in DONE until arm/disarm). See "Policy decisions" below for the DONE behavior.
//   * Latch `trig_index` (buffer address of the trigger sample) and `ts_at_trig` (probe-
//     domain timestamp of the trigger sample). The sample present on `sample_data` in the
//     cycle `trig` is asserted IS the trigger sample and is always stored (formal (a), #6).
//   * `wrapped` = write pointer passed DEPTH once since (re)arm. The host reconstructs time
//     order from trig_index/wrapped/PRETRIG — the core does no reordering (PLAN.md §6.2).
//   * Free-running TS_W-bit timestamp `ts`, cleared only by rst (tracker rule 5: timestamps
//     originate in the probe domain).
//
// Policy decisions:
//   * `trig` is consumed as a registered input, aligned to the sample it fires on; there is
//     no combinational probe->write-enable path (tracker rule 3: 1-cycle registered trigger
//     latency is the trigger engine's documented behavior, this core just aligns to it).
//   * A trigger (incl. force_trig) is accepted only in ARMED with `sample_valid` high; in
//     FILLING it is ignored (the pretrig backlog does not exist yet — PLAN.md §5 decision,
//     recorded in DESIGN.md).
//   * After the LAST window the FSM parks in DONE (buffer + status stay readable) until
//     `arm` (new capture) or `disarm` (to IDLE); intermediate windows re-arm automatically
//     through FILLING. `disarm` aborts from any state.
//   * In DONE the write pointer does not advance (formal (b), #6).
//   * Per-window sample budget/window sizing lands in issue #7; this core counts windows
//     and re-arms with the full-depth budget per window.
module scope_core #(
    parameter int unsigned PROBE_W    = 32,   // 1..512
    parameter int unsigned DEPTH_LOG2 = 8,    // 8..15
    parameter int unsigned TS_W       = 48
) (
    input  logic                  clk,
    input  logic                  rst,           // synchronous, active high

    // sample stream (from RLE/bypass mux; never back-pressured)
    input  logic [PROBE_W-1:0]    sample_data,
    input  logic                  sample_valid,

    // trigger: 1-cycle pulse aligned to the trigger sample on sample_data
    input  logic                  trig,

    // control (from CSR; pulses for arm/disarm, levels for config)
    input  logic                  arm,
    input  logic                  disarm,
    input  logic [DEPTH_LOG2-1:0] pretrig,       // samples to keep before the trigger
    input  logic [7:0]            windows,       // captures per arm, >= 1

    // status
    output logic [2:0]            state,         // scope_pkg::scope_state_e encoding (STATUS.state)
    output logic                  triggered,
    output logic                  wrapped,
    output logic [7:0]            windows_done,
    output logic [DEPTH_LOG2-1:0] trig_index,
    output logic                  armed,

    // buffer read port (drain path, same clock; 1-cycle latency)
    input  logic [DEPTH_LOG2-1:0] rd_addr,
    output logic [PROBE_W-1:0]    rd_data,

    // timestamps (probe domain)
    output logic [TS_W-1:0]       ts,            // free-running, cleared only by rst
    output logic [TS_W-1:0]       ts_at_trig     // ts of the trigger sample
);

  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;
  localparam int unsigned PR_W = DEPTH_LOG2 + 1;  // post-counter width (holds DEPTH)

  scope_pkg::scope_state_e          st;
  logic [DEPTH_LOG2-1:0] wptr;
  logic [DEPTH_LOG2-1:0] fill_cnt;        // samples stored in FILLING (this window)
  logic [PR_W-1:0]       post_remaining;  // samples still to store after the trigger sample

  // Write path: no ready, no stall. Stores in FILLING/ARMED always, in TRIGGERED while the
  // post-trigger budget lasts, never in IDLE/DONE.
  wire capture_wr = sample_valid && (st == scope_pkg::SCOPE_ST_FILLING || st == scope_pkg::SCOPE_ST_ARMED ||
                                     (st == scope_pkg::SCOPE_ST_TRIGGERED && post_remaining != '0));
  wire trig_accept = trig && sample_valid && (st == scope_pkg::SCOPE_ST_ARMED);

  wire fill_wr = capture_wr && (st == scope_pkg::SCOPE_ST_FILLING);
  wire post_wr = capture_wr && (st == scope_pkg::SCOPE_ST_TRIGGERED);

  // Post-update counter values, used for prompt state transitions (exactly `pretrig`
  // samples are stored in FILLING; DONE is entered the cycle after the last post sample).
  wire [DEPTH_LOG2:0] fill_next = {1'b0, fill_cnt} + {{DEPTH_LOG2{1'b0}}, fill_wr};
  wire [PR_W-1:0] post_next = post_remaining - PR_W'(post_wr);

  always_ff @(posedge clk) begin
    if (rst) begin
      st             <= scope_pkg::SCOPE_ST_IDLE;
      wptr           <= '0;
      fill_cnt       <= '0;
      post_remaining <= '0;
      triggered      <= 1'b0;
      wrapped        <= 1'b0;
      windows_done   <= 8'h00;
      trig_index     <= '0;
      ts             <= '0;
      ts_at_trig     <= '0;
    end else begin
      ts <= ts + 1'b1;

      if (capture_wr) begin
        wptr <= wptr + 1'b1;
        if (wptr == DEPTH_LOG2'(DEPTH - 1)) wrapped <= 1'b1;  // pointer passes DEPTH
      end
      if (fill_wr) fill_cnt <= fill_cnt + 1'b1;
      if (post_wr) post_remaining <= post_next;

      if (trig_accept) begin
        trig_index     <= wptr;  // the trigger sample is being stored at wptr THIS cycle
        ts_at_trig     <= ts;
        triggered      <= 1'b1;
        // The trigger sample counts as the first of the DEPTH-PRETRIG post samples.
        post_remaining <= PR_W'(DEPTH) - PR_W'(pretrig) - PR_W'(1);
      end

      if (disarm) begin
        st <= scope_pkg::SCOPE_ST_IDLE;
      end else begin
        unique case (st)
          scope_pkg::SCOPE_ST_IDLE: begin
            if (arm) begin
              st           <= scope_pkg::SCOPE_ST_FILLING;
              wptr         <= '0;
              fill_cnt     <= '0;
              triggered    <= 1'b0;
              wrapped      <= 1'b0;
              windows_done <= 8'h00;
            end
          end
          scope_pkg::SCOPE_ST_FILLING: begin
            if (fill_next >= {1'b0, pretrig}) st <= scope_pkg::SCOPE_ST_ARMED;
          end
          scope_pkg::SCOPE_ST_ARMED: begin
            if (trig_accept) st <= scope_pkg::SCOPE_ST_TRIGGERED;
          end
          scope_pkg::SCOPE_ST_TRIGGERED: begin
            if (post_next == '0) begin
              st           <= scope_pkg::SCOPE_ST_DONE;
              windows_done <= windows_done + 8'h01;
            end
          end
          scope_pkg::SCOPE_ST_DONE: begin
            if (arm) begin  // fresh capture run
              st           <= scope_pkg::SCOPE_ST_FILLING;
              wptr         <= '0;
              fill_cnt     <= '0;
              triggered    <= 1'b0;
              wrapped      <= 1'b0;
              windows_done <= 8'h00;
            end else if (windows_done < windows) begin  // auto re-arm: next window
              st        <= scope_pkg::SCOPE_ST_FILLING;
              fill_cnt  <= '0;
              triggered <= 1'b0;
              wrapped   <= 1'b0;
            end
            // else: park in DONE; buffer and status stay readable until arm/disarm
          end
          default: st <= scope_pkg::SCOPE_ST_IDLE;  // unreachable encodings recover to IDLE
        endcase
      end
    end
  end

  assign state = st;  // enum's logic [2:0] base IS the STATUS.state encoding
  assign armed = (st == scope_pkg::SCOPE_ST_FILLING) || (st == scope_pkg::SCOPE_ST_ARMED);

  // Capture buffer: the design's only BRAM, "old data" read-during-write (tracker rule 2).
  prim_ram_1r1w #(
      .WIDTH     (PROBE_W),
      .DEPTH_LOG2(DEPTH_LOG2)
  ) u_buf (
      .clk    (clk),
      .wr_en  (capture_wr),
      .wr_addr(wptr),
      .wr_data(sample_data),
      .rd_en  (1'b1),
      .rd_addr(rd_addr),
      .rd_data(rd_data)
  );

`ifdef FORMAL
  // Formal properties (a) and (b) — issue #6, run by formal/scope_core.sby. Instantiated
  // under `ifdef FORMAL (rather than bind, which yosys releases in the CI baseline handle
  // inconsistently) so synthesis/Verilator never see the checker; the properties still live
  // in their own module/file: formal/scope_core_fchk.sv.
  scope_core_fchk #(
      .PROBE_W   (PROBE_W),
      .DEPTH_LOG2(DEPTH_LOG2)
  ) u_fchk (
      .clk           (clk),
      .rst           (rst),
      .state         (state),
      .wptr          (wptr),
      .trig_index    (trig_index),
      .post_remaining(post_remaining),
      .capture_wr    (capture_wr),
      .trig_accept   (trig_accept),
      .sample_data   (sample_data),
      .pretrig       (pretrig),
      .arm           (arm)
  );
`endif

endmodule
