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

# Source order: package first (scope_pkg, issue #4), then rtl/prim primitives (issue #3),
# then core RTL (issues #4..#9), then rtl/if + rtl/xport front-ends (issues #8, #11),
# then sim/model helpers, then the TB itself (appended per run_one call).
COMMON_SRCS=(
  # -- package (issue #4): rtl/scope_pkg.sv
  # -- primitives (issue #3): prim_ff_sync, prim_ram_1r1w, prim_fifo_sync, prim_fifo_async
  # -- core RTL (issues #4..#9): scope_core, scope_csr, scope_trigger, scope_rle, scope_drain, scope_top
  # -- front-ends (issues #8, #11): rtl/xport/scope_uart.sv, rtl/if/scope_avalon.sv, rtl/if/scope_axil.sv
  # -- sim models: none yet
)

# -Wall with no waivers. Add waivers only when strictly needed, each with a one-line
# justification comment (hyperram VFLAGS block is the precedent).
VFLAGS=(--binary --timing -Wall
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

run_one tb_smoke.sv tb_smoke    # issue #2: harness/CI plumbing proof

echo "=================================================================="
if [ "$overall" -eq 0 ]; then
  echo "ALL TESTBENCHES PASSED"
else
  echo "ONE OR MORE TESTBENCHES FAILED"
fi
exit "$overall"
