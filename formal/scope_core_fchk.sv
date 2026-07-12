// scope_core_fchk — formal properties (a) and (b) for scope_core (issue #6).
//
// Instantiated INSIDE scope_core under `ifdef FORMAL (see the end of rtl/scope_core.sv), so
// synthesis and Verilator never see it and the checker gets direct port access to the
// internals it observes. Driven by formal/scope_core.sby (SymbiYosys, smtbmc/z3): BMC +
// induction at a reduced parameterization (PROBE_W=4, DEPTH_LOG2=3 — the FSM/pointer logic
// is parametric; small DEPTH makes wrap-around scenarios reachable within BMC depth).
// All scope_core inputs (arm/disarm/trig/sample_*/pretrig/windows) are left free.
//
// (a) The capture FSM never loses the trigger sample: at trigger acceptance the sample is
//     being written at wptr (== trig_index), and that buffer slot is never rewritten while
//     the same capture window is in flight (through DONE). Together with prim_ram_1r1w
//     correctness this implies buffer[trig_index] == probe_at_trigger — the 1-sample-shadow
//     reduction the issue prescribes (no RAM mirroring). The shadow is dropped when the
//     window ends (re-arm/IDLE): later windows legitimately reuse the buffer (DESIGN.md
//     deviation #4).
// (b) The write pointer never advances in DONE (nor in IDLE): asserted directly on the
//     write-enable, the only increment path, plus a $past-based pointer-stability check.
module scope_core_fchk #(
    parameter int unsigned PROBE_W    = 4,
    parameter int unsigned DEPTH_LOG2 = 3
) (
    input logic                  clk,
    input logic                  rst,
    input logic [2:0]            state,
    input logic [DEPTH_LOG2-1:0] wptr,
    input logic [DEPTH_LOG2-1:0] trig_index,
    input logic [DEPTH_LOG2:0]   post_remaining,
    input logic                  capture_wr,
    input logic                  trig_accept,
    input logic [PROBE_W-1:0]    sample_data,
    input logic [DEPTH_LOG2-1:0] pretrig,
    input logic                  arm
);

  localparam int unsigned DEPTH = 1 << DEPTH_LOG2;
  localparam logic [2:0] ST_IDLE = 3'd0, ST_FILLING = 3'd1, ST_ARMED = 3'd2,
                         ST_TRIGGERED = 3'd3, ST_DONE = 3'd4;

  // reset assumption: design starts in reset
  logic f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (rst);

  // ---------------- (a) one-sample shadow of the trigger slot ----------------
  logic                  f_shadow_valid;
  logic [DEPTH_LOG2-1:0] f_shadow_addr;
  logic [PROBE_W-1:0]    f_shadow_data;
  logic [DEPTH_LOG2:0]   f_post_target;  // DEPTH - pretrig - 1, latched at acceptance

  always @(posedge clk) begin
    if (rst) begin
      f_shadow_valid <= 1'b0;
    end else begin
      if (trig_accept) begin
        f_shadow_valid <= 1'b1;
        f_shadow_addr  <= wptr;
        f_shadow_data  <= sample_data;
        f_post_target  <= (DEPTH_LOG2+1)'(DEPTH) - {1'b0, pretrig} - 1'b1;
      end else if (state == ST_IDLE || state == ST_FILLING || state == ST_ARMED) begin
        // window over (re-arm or disarm): the old trigger slot is fair game again
        f_shadow_valid <= 1'b0;
      end
    end
  end

  always @(posedge clk) begin
    if (!rst && f_past_valid) begin
      // the trigger sample is stored in the acceptance cycle, at trig_index's address
      if (trig_accept) begin
        assert (capture_wr);
        // trig_index is latched from wptr in this same cycle
      end
      if (f_past_valid && $past(trig_accept) && !$past(rst)) begin
        assert (trig_index == f_shadow_addr);
        assert (state == ST_TRIGGERED || state == ST_IDLE);  // disarm may abort
      end
      // (a) core: the shadowed slot is never rewritten while the window is in flight.
      // Scoped to TRIGGERED: those are the only writes between acceptance and DONE — in
      // DONE (b) proves no writes at all, and once the FSM re-arms (FILLING/ARMED) the
      // window is over and the shadow is stale by definition (cleared next edge).
      if (f_shadow_valid && capture_wr && state == ST_TRIGGERED)
        assert (wptr != f_shadow_addr);
    end
  end

  // helper invariants (make (a) inductive): while TRIGGERED with a live shadow, the write
  // pointer is exactly (completed post-writes) ahead of the trigger slot and can never
  // come back around, because post_remaining bounds the writes that remain.
  always @(*) begin
    if (!rst && f_shadow_valid && state == ST_TRIGGERED) begin
      assert (post_remaining <= f_post_target);
      assert (DEPTH_LOG2'(wptr - f_shadow_addr) ==
              DEPTH_LOG2'(f_post_target - post_remaining + 1'b1));
      assert (f_post_target < (DEPTH_LOG2+1)'(DEPTH));
    end
    if (!rst && state == ST_TRIGGERED) assert (f_shadow_valid);
    if (!rst && f_shadow_valid && state == ST_DONE) assert (post_remaining == '0);
  end

  // ---------------- (b) write pointer frozen in DONE (and IDLE) ----------------
  always @(*) begin
    if (!rst && (state == ST_DONE || state == ST_IDLE)) assert (!capture_wr);
  end
  always @(posedge clk) begin
    if (f_past_valid && !$past(rst) && $past(state) == ST_DONE && !$past(arm))
      assert (wptr == $past(wptr));
  end

  // sanity: state encoding stays legal; reachability covers
  always @(*) if (!rst) assert (state <= ST_DONE);
  always @(posedge clk) begin
    if (!rst) begin
      cover (state == ST_DONE && f_shadow_valid);  // a full capture completes
      cover (f_shadow_valid && wptr == DEPTH_LOG2'(DEPTH - 1));  // wrap vicinity reached
    end
  end

endmodule
