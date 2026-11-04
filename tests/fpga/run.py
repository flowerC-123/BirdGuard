"""Run FPGA protocol, scheduling and display simulations."""

import argparse
import binascii
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
TESTS = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def simulator_binary(name, directory):
    if directory:
        base = Path(directory).expanduser().resolve()
        candidates = (base / name, base / f"{name}.exe")
        for path in candidates:
            if path.is_file():
                return str(path)
    found = shutil.which(name) or shutil.which(f"{name}.exe")
    if not found:
        raise SystemExit("Set MODELSIM_BIN or use --sim-bin to select ModelSim/Questa.")
    return found


def check_packets(directory):
    packets = sorted(directory.glob("packet_*.bin"))
    assert len(packets) == 5, "Expected five image packets"
    for packet in packets:
        data = packet.read_bytes()
        session, request, length, header_crc = struct.unpack_from("<IIHH", data, 4)
        assert session == 17 and len(data) == length + 18
        assert binascii.crc_hqx(data[2:14], 65535) == header_crc
        assert binascii.crc_hqx(data[2:-2], 65535) == int.from_bytes(
            data[-2:], "little"
        )
        frame, roi, sw, sh, x, y, width, height, fmt, reserved = struct.unpack_from(
            "<I7HBB", data, 16
        )
        assert roi == (request - 1) % 4 and (sw, sh) == (1280, 720)
        assert (width, height, fmt, reserved) == (16, 9, 1, 0)
        assert data[36:-2] == bytes([(frame * 17) % 256]) * (width * height)
    return len(packets)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sim-bin", default=os.environ.get("MODELSIM_BIN"))
    parser.add_argument(
        "--case",
        default="all",
        choices=(
            "all",
            "scheduler",
            "single_transport",
            "pipelined_transport",
            "result_windows",
            "reference_display",
            "voltage_overlay",
        ),
    )
    args = parser.parse_args()
    binaries = {
        name: simulator_binary(name, args.sim_bin) for name in ("vlib", "vlog", "vsim")
    }
    build = ROOT / "build/tests/fpga"
    build.mkdir(parents=True, exist_ok=True)
    sources = sorted((ROOT / "fpga/rtl/bird").rglob("*.v"))
    testbenches = sorted(TESTS.glob("tb_*.sv"))
    identity = {
        p.relative_to(ROOT).as_posix(): digest(p)
        for p in sources + testbenches + [Path(__file__)]
    }

    def execute(command, work, logname, timeout=1200):
        with (work / logname).open("wb") as log:
            result = subprocess.run(
                command,
                cwd=work,
                stdout=log,
                stderr=subprocess.STDOUT,
                timeout=timeout,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        text = (work / logname).read_text(errors="replace")
        if result.returncode or "** Error:" in text or "** Fatal:" in text:
            raise SystemExit(text[-6000:])
        return text

    execute([binaries["vlib"], "work"], build, "library.log")
    execute([binaries["vlog"], *map(str, sources)], build, "compile_design.log")
    execute(
        [binaries["vlog"], "-sv", *map(str, testbenches)], build, "compile_tests.log"
    )
    cases = [
        ("scheduler", {}, "PASS SCHEDULER_EDGES"),
        ("single_transport", {}, "PASS SINGLE_TIMEOUT"),
        ("pipelined_transport", {}, "PASS TRANSPORT"),
        ("result_windows", {"TRUSTED": 0}, "PASS RESULT_WINDOWS"),
        ("result_windows", {"TRUSTED": 1}, "PASS RESULT_WINDOWS"),
        (
            "reference_display",
            {"PROFILE": 0, "LOW_PROBE": 1, "FLIGHTS": 1},
            "PASS VOLTAGE_SYSTEM",
        ),
        (
            "reference_display",
            {"PROFILE": 0, "LOW_PROBE": 1, "FLIGHTS": 4},
            "PASS VOLTAGE_SYSTEM",
        ),
        ("voltage_overlay", {}, "PASS VOLTAGE_OSD"),
    ]
    results = []
    for index, (case, parameters, marker) in enumerate(cases):
        if args.case not in ("all", case):
            continue
        started = time.monotonic()
        case_dir = build / f"{case}_{index}"
        case_dir.mkdir(exist_ok=True)
        command = [
            binaries["vsim"],
            "-c",
            "-onfinish",
            "exit",
            "-wlf",
            "sim.wlf",
            "-lib",
            str(build / "work"),
            f"tb_{case}",
            *[f"-g{key}={value}" for key, value in parameters.items()],
            "-do",
            "onerror {quit -code 2}; onbreak {quit -code 2}; run -all; quit -code 0",
        ]
        log = execute(command, case_dir, "run.log")
        if marker not in log:
            raise SystemExit(f"Completion marker missing: {case}\n{log[-3000:]}")
        row = {
            "case": case,
            "parameters": parameters,
            "passed": True,
            "seconds": round(time.monotonic() - started, 2),
        }
        if case == "pipelined_transport":
            row["packets_verified"] = check_packets(case_dir)
        results.append(row)
        print(json.dumps(row), flush=True)
    stable = identity == {
        p.relative_to(ROOT).as_posix(): digest(p)
        for p in sources + testbenches + [Path(__file__)]
    }
    report = {
        "passed": stable and bool(results),
        "source_unchanged": stable,
        "inputs": identity,
        "cases": results,
    }
    (build / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    if not report["passed"]:
        raise SystemExit("Simulation input identity changed.")


if __name__ == "__main__":
    main()
