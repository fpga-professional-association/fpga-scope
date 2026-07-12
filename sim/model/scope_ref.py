#!/usr/bin/env python3
"""scope_ref.py — golden reference model for the fpga-scope capture path (stdlib only).

Replays the same probe stimulus the SystemVerilog testbenches drive and computes the
expected capture-buffer contents, trigger index, and wrapped flag, cycle-exact against
rtl/scope_core.sv. Outputs are $readmemh-compatible .mem files consumed by the TBs.
Invoked from sim/run.sh before the TBs are verilated (no manual pre-steps).

Structure (grows with later issues): capture_model (this issue, #4), trigger_model (#6),
rle_encode (#9) — plus a small CLI.

Stimulus generator: the same address-seeded xorshift32 trick as the hyperram repo's
rtl/bench/hyperram_bw_test.sv gen_pattern() (x ^= x<<7; x ^= x>>9; x ^= x<<8), seeded per
sample index, folded/concatenated to PROBE_W. Pure function of (seed, sample index), so the
model and any future SV re-implementation agree without stored expectation memories.
"""

import argparse
import sys

MASK32 = 0xFFFFFFFF


def xorshift32(x: int) -> int:
    """One round of the hyperram_bw_test.sv gen_pattern() xorshift (32-bit)."""
    x &= MASK32
    x ^= (x << 7) & MASK32
    x ^= x >> 9
    x ^= (x << 8) & MASK32
    return x & MASK32


def gen_stimulus(seed: int, count: int, probe_w: int) -> list[int]:
    """Deterministic probe stream: sample k is xorshift32 chunks seeded by (seed + k)."""
    chunks = (probe_w + 31) // 32
    stim = []
    for k in range(count):
        word = 0
        x = (seed + k) & MASK32
        for c in range(chunks):
            x = xorshift32(x ^ (0x9E3779B9 * (c + 1) & MASK32))
            word |= x << (32 * c)
        stim.append(word & ((1 << probe_w) - 1))
    return stim


def capture_model(stim, depth_log2, pretrig, trig_sample):
    """Cycle-exact replay of scope_core's capture datapath from the first ARMED-phase-or-
    FILLING-phase sample (sample index 0 = first sample presented after arm, sample_valid
    high every cycle). `trig` is high during sample index `trig_sample`.

    Semantics mirrored from rtl/scope_core.sv:
      * FILLING stores exactly `pretrig` samples, then ARMED (transition uses the post-
        update fill count, so no extra FILLING sample is stored).
      * A trigger is accepted only in ARMED; the sample presented in the trig cycle IS the
        trigger sample, is stored, and its buffer address is trig_index.
      * The trigger sample counts as the first of the DEPTH-PRETRIG post samples; DONE is
        entered the cycle after the last post sample is stored.
      * wrapped = write pointer passed DEPTH once since arm (a write hit address DEPTH-1).

    Returns (buf, trig_index, wrapped, samples_consumed).
    """
    depth = 1 << depth_log2
    assert 0 <= pretrig < depth, "pretrig must be 0..DEPTH-1"
    assert trig_sample >= pretrig, "trigger must arrive at/after the ARMED transition"

    buf = [None] * depth
    st = "FILLING"
    wptr = 0
    fill = 0
    post = 0
    wrapped = False
    trig_index = None

    for k, sample in enumerate(stim):
        trig = k == trig_sample
        wr = st in ("FILLING", "ARMED") or (st == "TRIGGERED" and post != 0)
        acc = trig and st == "ARMED"
        fill_wr = wr and st == "FILLING"
        post_wr = wr and st == "TRIGGERED"

        if wr:
            buf[wptr] = sample
            if wptr == depth - 1:
                wrapped = True

        fill_next = fill + (1 if fill_wr else 0)
        post_next = post - (1 if post_wr else 0)

        if acc:
            trig_index = wptr
            post = depth - pretrig - 1
        else:
            post = post_next
        if wr:
            wptr = (wptr + 1) % depth
        fill = fill_next

        if st == "FILLING" and fill_next >= pretrig:
            st = "ARMED"
        elif st == "ARMED" and acc:
            st = "TRIGGERED"
        elif st == "TRIGGERED" and post_next == 0:
            st = "DONE"

        if st == "DONE":
            assert all(v is not None for v in buf), "completed capture must fill the buffer"
            return buf, trig_index, wrapped, k + 1

    raise SystemExit("scope_ref.py: stimulus exhausted before capture completed "
                     "(need >= trig_sample + DEPTH - pretrig samples)")


def write_mem(path, values, hex_digits):
    with open(path, "w") as f:
        for v in values:
            f.write(f"{v:0{hex_digits}x}\n")


def cmd_capture(args):
    if args.stim_in:
        with open(args.stim_in) as f:
            stim = [int(line, 16) for line in f if line.strip()]
    else:
        stim = gen_stimulus(args.seed, args.count, args.probe_w)

    buf, trig_index, wrapped, consumed = capture_model(
        stim, args.depth_log2, args.pretrig, args.trig_sample)

    digits = (args.probe_w + 3) // 4
    write_mem(f"{args.out_prefix}_stim.mem", stim, digits)
    write_mem(f"{args.out_prefix}_buf.mem", buf, digits)
    # meta: word 0 = trig_index, word 1 = wrapped, word 2 = samples consumed
    write_mem(f"{args.out_prefix}_meta.mem", [trig_index, int(wrapped), consumed], 16)
    print(f"scope_ref: {args.out_prefix}: {len(stim)} stimulus samples, "
          f"trig_index={trig_index}, wrapped={int(wrapped)}, consumed={consumed}")


def main(argv):
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("capture", help="expected capture-buffer contents for tb_capture_*")
    c.add_argument("--probe-w", type=int, required=True)
    c.add_argument("--depth-log2", type=int, required=True)
    c.add_argument("--pretrig", type=int, default=0)
    c.add_argument("--trig-sample", type=int, required=True,
                   help="sample index (from arm) that carries the trigger")
    c.add_argument("--seed", type=lambda s: int(s, 0), default=0xC0FFEE01)
    c.add_argument("--count", type=int, required=True, help="stimulus samples to generate")
    c.add_argument("--stim-in", default=None,
                   help="read stimulus from file (one hex vector per line) instead of generating")
    c.add_argument("--out-prefix", required=True)
    c.set_defaults(func=cmd_capture)

    args = p.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
