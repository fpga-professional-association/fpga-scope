// scope_rle — optional run-length encoder for the capture sample stream (issue #9).
//
// Sits between the trigger's aligned probe sample and scope_core's sample port. Transforms a
// raw sample stream (one sample per `in_valid` cycle, NEVER back-pressured — tracker rule 1)
// into a stream of RLE words `{is_count, value}` (width PROBE_W+1), emitting AT MOST ONE word
// per cycle. scope_core stores the words (instantiated PROBE_W+1 wide when RLE is enabled);
// the host decodes with rle_decode (sim/model/scope_ref.py, matched vector-for-vector).
//
//   * data word  (is_count=0): a sample that differs from its predecessor (or the first).
//   * count word (is_count=1): "the current data value repeated N more times", N in
//     1..MAX_RUN = 2^CNT_W-1; a longer run emits successive count words (value unchanged).
//
// One-word-per-cycle with a 1-DEEP SKID (`pend`): a value change with a pending run count
// produces TWO words (flush the old run's count + the new data word) in one cycle — emit the
// count, stash the data in `pend`. That is the ONLY 2-word case, it requires acc>0, and it
// resets acc=0; a following 2-word case needs intervening repeat cycles (which produce zero
// words and drain `pend`). So `pend` never needs more than one slot. Total words <= samples,
// plus at most the one in-flight skid word at flush => words <= samples+1 (formal (c)).
//
//   * `flush` (a between-samples pulse, in_valid low): emit any pending count so the current
//     run ends on a clean word boundary — used at the trigger instant and at window DONE so
//     the trigger sample is cleanly represented and the raw index bookkeeping stays exact.
//   * `enable`=0 (runtime RLE_CTRL[0]=0): pure bypass — word = {1'b0, in_data}, valid every
//     in_valid cycle; scope_core still stores PROBE_W+1 words (is_count always 0), so the host
//     decode reproduces the raw stream. (RLE_EN=0 at elaboration bypasses this module entirely
//     in scope_top; this runtime bypass is for RLE_EN=1 builds.)

module scope_rle #(
    parameter int unsigned PROBE_W = 32,
    parameter int unsigned CNT_W   = 8      // count-word field width (= DEPTH_LOG2)
) (
    input  logic               clk,
    input  logic               rst,         // synchronous, active high
    input  logic               enable,      // RLE_CTRL[0]; 0 => bypass
    input  logic [PROBE_W-1:0] in_data,
    input  logic               in_valid,
    input  logic               flush,       // between-samples pulse (in_valid low)

    output logic [PROBE_W:0]   word,        // {is_count, value}
    output logic               word_valid
);

  localparam logic [CNT_W-1:0] MAX_RUN = '1;  // 2^CNT_W - 1

  // run state
  logic               have_prev;
  logic [PROBE_W-1:0] prev;
  logic [CNT_W-1:0]   acc;        // repeats accumulated, not yet emitted (0..MAX_RUN-1)
  // 1-deep skid
  logic               pend_valid;
  logic [PROBE_W:0]   pend_word;

  // word constructors
  function automatic logic [PROBE_W:0] data_word(input logic [PROBE_W-1:0] v);
    data_word = {1'b0, v};
  endfunction
  function automatic logic [PROBE_W:0] count_word(input logic [CNT_W-1:0] n);
    count_word = {1'b1, {(PROBE_W-CNT_W){1'b0}}, n};
  endfunction

  // Per-cycle production (combinational): w0 is this cycle's primary word, w1 the optional
  // second word (2-word change case). At most one of the two is ever stashed into pend.
  logic             prod0, prod1;
  logic [PROBE_W:0] w0, w1;
  logic [CNT_W-1:0] acc_n;
  logic             have_n;
  logic [PROBE_W-1:0] prev_n;

  always_comb begin
    prod0 = 1'b0; prod1 = 1'b0;
    w0 = '0;       w1 = '0;
    acc_n = acc;   have_n = have_prev; prev_n = prev;

    if (enable) begin
      if (in_valid) begin
        if (!have_prev) begin                       // first sample -> data word
          prod0 = 1'b1; w0 = data_word(in_data);
          have_n = 1'b1; prev_n = in_data; acc_n = '0;
        end else if (in_data == prev) begin         // repeat
          if (acc == MAX_RUN - 1'b1) begin          // saturate -> emit count(MAX_RUN)
            prod0 = 1'b1; w0 = count_word(MAX_RUN);
            acc_n = '0;
          end else begin
            acc_n = acc + 1'b1;                      // accumulate, no word
          end
        end else begin                              // value change
          if (acc != '0) begin                      // flush old run's count, then data(new)
            prod0 = 1'b1; w0 = count_word(acc);
            prod1 = 1'b1; w1 = data_word(in_data);
          end else begin
            prod0 = 1'b1; w0 = data_word(in_data);
          end
          prev_n = in_data; acc_n = '0;
        end
      end else if (flush) begin                      // between-samples flush of a pending run
        if (acc != '0) begin
          prod0 = 1'b1; w0 = count_word(acc);
          acc_n = '0;
        end
      end
    end else begin
      // bypass: is_count always 0, one word per in_valid
      if (in_valid) begin prod0 = 1'b1; w0 = data_word(in_data); end
    end
  end

  // Output arbitration: pend has priority. A 2-word case (prod1) only arises with acc>0, which
  // (invariant) implies pend was drained during the run's repeats, so pend_valid is 0 then.
  always_comb begin
    if (pend_valid) begin
      word = pend_word; word_valid = 1'b1;   // draining the skid
    end else if (prod0) begin
      word = w0;        word_valid = 1'b1;
    end else begin
      word = '0;        word_valid = 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      have_prev <= 1'b0; prev <= '0; acc <= '0;
      pend_valid <= 1'b0; pend_word <= '0;
    end else begin
      have_prev <= have_n; prev <= prev_n; acc <= acc_n;
      if (pend_valid) begin
        // emitted pend this cycle; a same-cycle prod0 (never prod1 here) becomes the new pend
        pend_valid <= prod0;
        pend_word  <= w0;
      end else if (prod1) begin
        pend_valid <= 1'b1;      // emitted w0, stash w1
        pend_word  <= w1;
      end else begin
        pend_valid <= 1'b0;
      end
    end
  end

`ifdef FORMAL
  // property (c): the encoder never expands beyond samples + 1 (the in-flight skid word).
  // Counts raw samples in and words out; asserts words_out <= samples_in + 1 at all times.
  // Assume the first cycle is reset so the counters (and encoder state) start defined.
  logic f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;
  always_comb if (!f_past_valid) assume (rst);

  logic [31:0] f_samples, f_words;
  always_ff @(posedge clk) begin
    if (rst) begin f_samples <= '0; f_words <= '0; end
    else begin
      if (in_valid)   f_samples <= f_samples + 1'b1;  // a sample is consumed whether encoded or bypassed
      if (word_valid) f_words   <= f_words + 1'b1;
    end
  end
  always_comb if (f_past_valid && !rst) assert (f_words <= f_samples + 32'd1);
`endif

endmodule
