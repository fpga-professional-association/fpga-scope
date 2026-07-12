#!/usr/bin/env bash
# run.sh — build + run the fpga-scope self-checking Verilator testbenches.
#
# One verilator --binary build+run per testbench. Exits non-zero on any build, elaboration,
# or simulation failure (a TB signals failure with $fatal -> non-zero exit and prints
# "TB_RESULT: FAIL"; success prints "TB_RESULT: PASS" and $finish -> exit 0).
# Same contract as ../hyperram/sim/run.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RTL="$ROOT/rtl"
SIM="$ROOT/sim"
BUILD="$SIM/build"

# TBs load run.sh-generated golden vectors via repo-root-relative paths ($readmemh).
cd "$ROOT"

# Golden vectors (issue #4+): scope_ref.py replays the TB stimulus and writes the expected
# results as .mem files BEFORE the TBs run — no manual pre-steps.
gen_vectors() {
  echo "=================================================================="
  echo "== Generating golden vectors (sim/model/scope_ref.py)"
  echo "=================================================================="
  mkdir -p "$BUILD/vectors"
  # tb_capture_basic leg A: PROBE_W=32, DEPTH_LOG2=8, force-trig at sample DEPTH/2
  python3 "$SIM/model/scope_ref.py" capture --probe-w 32 --depth-log2 8 --pretrig 0 \
    --trig-sample 128 --count 640 --seed 0xC0FFEE01 \
    --out-prefix "$BUILD/vectors/cap_w32_d8" || { echo "TB_RESULT: FAIL (scope_ref.py)"; exit 1; }
  # tb_capture_basic leg B: PROBE_W=512, DEPTH_LOG2=10
  python3 "$SIM/model/scope_ref.py" capture --probe-w 512 --depth-log2 10 --pretrig 0 \
    --trig-sample 512 --count 2560 --seed 0xC0FFEE02 \
    --out-prefix "$BUILD/vectors/cap_w512_d10" || { echo "TB_RESULT: FAIL (scope_ref.py)"; exit 1; }
}

# Source order: package first (scope_pkg, issue #4), then rtl/prim primitives (issue #3),
# then core RTL (issues #4..#9), then rtl/if + rtl/xport front-ends (issues #8, #11),
# then sim/model helpers, then the TB itself (appended per run_one call).
COMMON_SRCS=(
  # -- package first:
  "$RTL/scope_pkg.sv"
  # -- primitives (issue #3):
  "$RTL/prim/prim_ff_sync.sv"
  "$RTL/prim/prim_ram_1r1w.sv"
  "$RTL/prim/prim_fifo_sync.sv"
  "$RTL/prim/prim_fifo_async.sv"
  # -- core RTL (issues #4..#9): scope_core, then scope_csr, scope_trigger, scope_rle, scope_drain, scope_top
  "$RTL/scope_core.sv"
  "$RTL/scope_csr.sv"
  # -- front-ends (issues #8, #11): rtl/xport/scope_uart.sv, rtl/if/scope_avalon.sv, rtl/if/scope_axil.sv
  # -- sim models: none yet (golden refs are Python-generated .mem files, see gen_vectors)
)

# -Wall with no waivers. Add waivers only when strictly needed, each with a one-line
# justification comment (hyperram VFLAGS block is the precedent).
# --timescale gives RTL files (which carry no timescale directive, per convention) the same
# 1ns/1ps scale as the TBs so -Wall's TIMESCALEMOD stays clean without per-file directives.
VFLAGS=(--binary --timing -Wall --timescale 1ns/1ps
        -I"$RTL" -I"$RTL/if" -I"$RTL/xport" -I"$RTL/prim" -j 4)

overall=0

run_one() {
  local tb="$1" top="$2"
  shift 2
  local extra_srcs=("$@")       # optional extra RTL sources for this TB only
  echo "=================================================================="
  echo "== Building $top"
  echo "=================================================================="
  local odir="$BUILD/$top"
  rm -rf "$odir"
  mkdir -p "$odir"
  if ! verilator "${VFLAGS[@]}" --top-module "$top" --Mdir "$odir" -o "$top" \
        ${COMMON_SRCS[@]+"${COMMON_SRCS[@]}"} ${extra_srcs[@]+"${extra_srcs[@]}"} \
        "$SIM/$tb" > "$odir/build.log" 2>&1; then
    echo "-- build FAILED; log follows --"
    cat "$odir/build.log"
    echo "TB_RESULT: FAIL ($top build error)"
    overall=1
    return
  fi
  echo "-- build ok"
  echo "== Running $top"
  if ! "$odir/$top"; then
    echo "TB_RESULT: FAIL ($top simulation error / non-zero exit)"
    overall=1
    return
  fi
}

gen_vectors

run_one tb_smoke.sv           tb_smoke            # issue #2: harness/CI plumbing proof
run_one tb_prim_ram.sv        tb_prim_ram         # issue #3: RAM read-during-write "old data" policy
run_one tb_prim_fifo_sync.sv  tb_prim_fifo_sync   # issue #3: sync FIFO fill/drain/boundary + scoreboard soak
run_one tb_prim_fifo_async.sv tb_prim_fifo_async  # issue #3: async FIFO 3:1 / 1:3 / ~1:1 CDC soak, >=100k/leg
run_one tb_capture_basic.sv   tb_capture_basic    # issue #4: scope_core capture bit-exact vs scope_ref.py
run_one tb_csr.sv             tb_csr              # issue #5: CSR matrix, cfg_err lockout, BUF_DATA drain

echo "=================================================================="
if [ "$overall" -eq 0 ]; then
  echo "ALL TESTBENCHES PASSED"
else
  echo "ONE OR MORE TESTBENCHES FAILED"
fi
exit "$overall"
