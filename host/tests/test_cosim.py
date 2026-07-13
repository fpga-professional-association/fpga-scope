"""Verilator co-simulation: the Python host drives the REAL scope_top over a byte pipe,
end-to-end, and the decoded capture is checked byte-for-byte against scope_ref.py for the
same seed. This is the issue-#10 milestone gate ("pytest green against Verilator co-sim").

Auto-skips when verilator is not installed, so the pure-Python unit tests still run anywhere.
"""
import pytest

import scope_ref
from fpgapa_scope import csr as C, frame
from fpgapa_scope.scope import Scope
from fpgapa_scope.reorder import reorder_window
from fpgapa_scope.vcd import write_vcd
from fpgapa_scope.sigrok import write_sr

import cosim_util

PROBE_W = 32
DEPTH_LOG2 = 8
DEPTH = 1 << DEPTH_LOG2

pytestmark = pytest.mark.skipif(not cosim_util.have_verilator(),
                                reason="verilator not installed")


@pytest.fixture(scope="session")
def cosim_binary(tmp_path_factory):
    mdir = tmp_path_factory.mktemp("cosim_build")
    return cosim_util.build_cosim(mdir)


def _expected(seed, pretrig, trig_sample):
    """Golden capture buffer + trigger metadata from scope_ref, using the SAME idle-prefix-2
    stimulus discipline tb_cosim drives (proven byte-exact by tb_drain_cdc)."""
    count = trig_sample + DEPTH + 8
    gen = scope_ref.gen_stimulus(seed, count, PROBE_W)
    stim = [0, 0] + gen[:count - 2]
    buf, trig_index, wrapped, _ = scope_ref.capture_model(stim, DEPTH_LOG2, pretrig, trig_sample)
    return buf, trig_index, wrapped


# pretrig=0 wraps deep (trig_index=44); pretrig=64 exercises the pre-trigger reorder path.
@pytest.mark.parametrize("seed,pretrig,trig_sample", [
    (0xC0FFEE01, 0, 300),
    (0x1234ABCD, 64, 300),
    (0xBADC0DE9, 0, 260),
])
def test_cosim_end_to_end(cosim_binary, tmp_path, seed, pretrig, trig_sample):
    buf_ref, trig_index_ref, wrapped_ref = _expected(seed, pretrig, trig_sample)

    stderr_log = tmp_path / "tb_cosim.stderr"
    with cosim_util.CosimTransport(cosim_binary, seed, trig_sample, stderr_log) as t:
        sc = Scope(t, probe_w=PROBE_W)

        # -- identify: PING carries ID_REG + the DUT's ID_VALUE parameter --------------------
        fr = sc.ping()
        assert fr.cmd == frame.OP_PING
        assert int.from_bytes(fr.payload[0:4], "big") == C.ID_REG
        assert int.from_bytes(fr.payload[4:8], "big") == 0xF00D1234

        # -- configure over the wire ---------------------------------------------------------
        sc.write_csr(C.WINDOWS, 1)
        sc.write_csr(C.PRETRIG, pretrig)
        assert not sc.status()["cfg_err"]
        hwcfg = sc.read_csr(C.HWCFG)
        assert (hwcfg & 0x3FF) == PROBE_W          # HWCFG.probe_w low 10 bits

        # -- arm the real core; tb_cosim auto-stimulates from the armed rise -----------------
        sc.arm()
        assert sc.wait_done(timeout=15.0), "capture never reached DONE"
        st = sc.status()
        assert st["triggered"] and st["state"] == C.STATE_DONE

        # -- drain + host decode -------------------------------------------------------------
        cap = sc.drain(pretrig_eff=pretrig)

    # === the acceptance: real RTL buffer == golden model, through the real frame codec =====
    assert cap.raw_buffer == buf_ref, "drained buffer != scope_ref.capture_model"
    assert cap.trig_index == trig_index_ref
    assert cap.wrapped == wrapped_ref

    # reorder consistency: time-ordered window is DEPTH long with the trigger at trig_pos
    ordered_ref, trig_pos_ref = reorder_window(buf_ref, trig_index_ref, wrapped_ref, pretrig)
    assert cap.samples == ordered_ref
    assert len(cap.samples) == DEPTH
    assert cap.trig_pos == trig_pos_ref
    assert cap.samples[cap.trig_pos] == buf_ref[trig_index_ref]

    # -- export the decoded capture and confirm the artifacts are well-formed ---------------
    vcd = tmp_path / "cap.vcd"
    write_vcd(vcd, cap.samples, PROBE_W, trig_pos=cap.trig_pos)
    text = vcd.read_text()
    assert "trigger" in text and "$comment trigger $end" in text

    sr = tmp_path / "cap.sr"
    write_sr(sr, cap.samples, PROBE_W)
    import zipfile
    with zipfile.ZipFile(sr) as z:
        assert len(z.read("logic-1-1")) == DEPTH * (PROBE_W // 8)
