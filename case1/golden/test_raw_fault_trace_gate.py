"""Negative tests for RAW recovery evidence; no fixture files are written."""
import json
from pathlib import Path
from unittest.mock import patch

from check_portable_soc_numerical_trace import check


def main() -> None:
    drain = "C1_SOC_INFLIGHT_WRITE_ABORT_DRAIN_PASS pending=2 held_cycles=64 aw=20 b=20 no_restart=1"
    recovery = "C1_SOC_RAW_RASTER_FAULT_PASS pending=2 held_cycles=64 captures=3 errors=1 done=1 reset=0"
    cases = {
        "missing": drain,
        "duplicate": "\n".join((drain, recovery, recovery)),
        "single_writer": "\n".join((drain, recovery.replace("pending=2", "pending=1"))),
        "unretired": "\n".join((drain.replace("b=20", "b=19"), recovery)),
        "pending_mismatch": "\n".join((drain.replace("pending=2", "pending=3"), recovery)),
        "reversed": "\n".join((recovery, drain)),
        "no_fault": "\n".join((drain, recovery.replace("errors=1", "errors=0"))),
        "reset_used": "\n".join((drain, recovery.replace("reset=0", "reset=1"))),
    }
    for name, log in cases.items():
        def fake_read(path, *args, **kwargs):
            if path.name == "status.json":
                return json.dumps({"state": "complete", "exit_code": 0})
            if path.name == "xsim.stdout.log":
                return log
            raise AssertionError(f"{name}: invalid evidence escaped gate to {path}")

        with patch.object(Path, "read_text", fake_read):
            try:
                check(Path("fixture"), Path("unused"), require_raw_fault_recovery=True)
            except ValueError as exc:
                if "RAW" not in str(exc):
                    raise AssertionError(f"{name}: rejected by unrelated gate") from exc
            else:
                raise AssertionError(f"{name}: invalid evidence accepted")
    print(f"C1_RAW_FAULT_TRACE_NEGATIVE_PASS cases={len(cases)} files_written=0")
    wait = "C1_SOC_RAW_EOF_WAIT_PASS cycles=64 bus_drained=1 cleanup_held=1"
    eof = "C1_SOC_RAW_MISSING_EOF_PASS bus_hold=64 boundary_wait=64 captures=3 errors=1 done=1 reset=0"
    eof_cases = [eof, wait, eof+"\n"+wait, wait+"\n"+wait+"\n"+eof,
                 wait.replace("bus_drained=1", "bus_drained=0")+"\n"+eof]
    for log in eof_cases:
        def fake_eof_read(path, *args, **kwargs):
            if path.name == "status.json":
                return json.dumps({"state": "complete", "exit_code": 0})
            if path.name == "xsim.stdout.log":
                return log
            raise AssertionError("invalid EOF evidence escaped its gate")
        with patch.object(Path, "read_text", fake_eof_read):
            try:
                check(Path("fixture"), Path("unused"), require_missing_eof_recovery=True)
            except ValueError as exc:
                if "EOF boundary" not in str(exc):
                    raise AssertionError("EOF rejected by unrelated gate") from exc
            else:
                raise AssertionError("invalid EOF evidence accepted")
    print(f"C1_MISSING_EOF_TRACE_NEGATIVE_PASS cases={len(eof_cases)} files_written=0")
    idle = "C1_SOC_RAW_IDLE_TIMEOUT_PASS threshold=4096 code=46 captures=3 errors=1 done=1 reset=0"
    idle_cases = ["", idle+"\n"+idle, idle.replace("code=46", "code=45"),
                  idle.replace("reset=0", "reset=1")]
    for log in idle_cases:
        def fake_idle_read(path, *args, **kwargs):
            if path.name == "status.json":
                return json.dumps({"state": "complete", "exit_code": 0})
            if path.name == "xsim.stdout.log":
                return log
            raise AssertionError("invalid idle evidence escaped its gate")
        with patch.object(Path, "read_text", fake_idle_read):
            try:
                check(Path("fixture"), Path("unused"), require_idle_timeout_recovery=True)
            except ValueError as exc:
                if "idle timeout evidence" not in str(exc):
                    raise AssertionError("idle evidence rejected by unrelated gate") from exc
            else:
                raise AssertionError("invalid idle evidence accepted")
    print(f"C1_IDLE_TIMEOUT_TRACE_NEGATIVE_PASS cases={len(idle_cases)} files_written=0")
    explicit = "C1_SOC_EXPLICIT_RECOVERY_PASS flushes=1 captures=3 errors=1 done=1 reset=0"
    drained = "C1_SOC_EXPLICIT_RECOVERY_DRAIN_PASS pending=2 held_cycles=64 source_stopped=1"
    explicit_cases = ["", explicit, drained, explicit+"\n"+drained,
                      drained+"\n"+explicit+"\n"+explicit,
                      drained.replace("pending=2", "pending=1")+"\n"+explicit,
                      drained.replace("source_stopped=1", "source_stopped=0")+"\n"+explicit,
                      drained+"\n"+explicit.replace("flushes=1", "flushes=2")]
    for log in explicit_cases:
        def fake_explicit_read(path, *args, **kwargs):
            if path.name == "status.json":
                return json.dumps({"state": "complete", "exit_code": 0})
            if path.name == "xsim.stdout.log":
                return log
            raise AssertionError("invalid explicit recovery escaped its gate")
        with patch.object(Path, "read_text", fake_explicit_read):
            try:
                check(Path("fixture"), Path("unused"), require_explicit_recovery=True)
            except ValueError as exc:
                if "explicit recovery evidence" not in str(exc):
                    raise AssertionError("explicit recovery rejected by unrelated gate") from exc
            else:
                raise AssertionError("invalid explicit recovery accepted")
    print(f"C1_EXPLICIT_RECOVERY_TRACE_NEGATIVE_PASS cases={len(explicit_cases)} files_written=0")
    late = "C1_SOC_EXPLICIT_RECOVERY_LATE_ACK_PASS cycles=32 bus_drained=1 ownership_held=1"
    late_cases = ["", late, drained+"\n"+late, late+"\n"+late+"\n"+drained,
                  late.replace("ownership_held=1", "ownership_held=0")+"\n"+drained,
                  late.replace("bus_drained=1", "bus_drained=0")+"\n"+drained]
    for log in late_cases:
        def fake_late_read(path, *args, **kwargs):
            if path.name == "status.json":
                return json.dumps({"state": "complete", "exit_code": 0})
            if path.name == "xsim.stdout.log":
                return log
            raise AssertionError("invalid late source ACK escaped its gate")
        with patch.object(Path, "read_text", fake_late_read):
            try:
                check(Path("fixture"), Path("unused"), require_late_source_ack=True)
            except ValueError as exc:
                if "late source ACK evidence" not in str(exc):
                    raise AssertionError("late ACK rejected by unrelated gate") from exc
            else:
                raise AssertionError("invalid late source ACK accepted")
    print(f"C1_LATE_SOURCE_ACK_TRACE_NEGATIVE_PASS cases={len(late_cases)} files_written=0")
    accept = "C1_SOC_EXPLICIT_RECOVERY_APB_ACCEPT_PASS diagnostic=46 busy=1 duplicate_rejected=1"
    finish = "C1_SOC_EXPLICIT_RECOVERY_APB_PASS hardware_request=0 completion_read=1 completion_cleared=1"
    apb_cases = ["", accept+"\n"+finish, finish+"\n"+drained+"\n"+accept,
                 accept+"\n"+drained+"\n"+finish+"\n"+finish,
                 accept+"\n"+drained+"\n"+finish.replace("hardware_request=0", "hardware_request=1"),
                 accept.replace("duplicate_rejected=1", "duplicate_rejected=0")+"\n"+drained+"\n"+finish]
    for log in apb_cases:
        def fake_apb_read(path, *args, **kwargs):
            if path.name == "status.json":
                return json.dumps({"state": "complete", "exit_code": 0})
            if path.name == "xsim.stdout.log":
                return log
            raise AssertionError("invalid APB recovery escaped its gate")
        with patch.object(Path, "read_text", fake_apb_read):
            try:
                check(Path("fixture"), Path("unused"), require_apb_recovery=True)
            except ValueError as exc:
                if "APB recovery evidence" not in str(exc):
                    raise AssertionError("APB rejected by unrelated gate") from exc
            else:
                raise AssertionError("invalid APB recovery accepted")
    print(f"C1_APB_RECOVERY_TRACE_NEGATIVE_PASS cases={len(apb_cases)} files_written=0")


if __name__ == "__main__":
    main()
