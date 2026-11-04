"""Build the selected FPGA profile with Tang Dynasty."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

from routed_signoff import check_routed

ROOT = Path(__file__).resolve().parents[1]
FPGA = ROOT / "fpga"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs(profile):
    paths = []
    for folder in ("rtl", "ip", "constraints", "project"):
        paths.extend(
            p
            for p in (FPGA / folder).rglob("*")
            if p.is_file() and p.suffix.lower() not in (".log", ".logw")
        )
    if profile == "pipelined":
        paths.append(FPGA / "profiles/pipelined/bird_board_top.v")
    return {p.relative_to(ROOT).as_posix(): digest(p) for p in sorted(paths)}


def build_identity(destination, executable):
    paths = [Path(__file__), Path(__file__).with_name("routed_signoff.py")]
    paths.extend(
        destination / "syn" / name
        for name in ("flow.tcl", "settings.cfg", "birdguard.prj")
    )
    return {
        "files": {p.relative_to(ROOT).as_posix(): digest(p) for p in paths},
        "tool_sha256": digest(executable),
    }


def render_settings(template):
    folders = {"RTL": "rtl", "IP": "ip", "CONSTRAINTS": "constraints"}

    def replace_reference(match):
        quoted = match[0].startswith('"')
        value = match[0].strip('"')
        for token, folder in folders.items():
            value = value.replace(f"@{token}@", (FPGA / folder).as_posix())
        return f'"{value}"' if quoted else "{" + value + "}"

    return re.sub(r'"@[A-Z]+@/[^\"]+"|@[A-Z]+@/[^\s"}]+', replace_reference, template)


def td_executable(directory):
    if directory:
        path = Path(directory).expanduser().resolve() / "td_commands_prompt.exe"
    else:
        found = shutil.which("td_commands_prompt.exe") or shutil.which(
            "td_commands_prompt"
        )
        if not found:
            raise SystemExit("Set TD_BIN or use --td-bin to select Tang Dynasty.")
        path = Path(found)
    if not path.is_file():
        raise SystemExit(f"Tang Dynasty executable not found: {path}")
    return path


def prepare(profile, destination):
    project_dir = FPGA / "project" / profile
    project = (project_dir / "birdguard.prj").read_text(encoding="utf-8")
    dependencies = []

    def absolute_reference(match):
        path = (project_dir / match[1]).resolve()
        if not path.is_file():
            raise FileNotFoundError(path)
        dependencies.append(path.relative_to(ROOT).as_posix())
        return f'Path="{path.as_posix()}"'

    project = re.sub(r'Path="([^"]+)"', absolute_reference, project)
    for phase in ("syn", "phy"):
        work = destination / phase
        work.mkdir(parents=True, exist_ok=True)
        (work / "birdguard.prj").write_text(project, encoding="utf-8")
        settings = (FPGA / f"project/settings_{phase}.cfg").read_text(encoding="utf-8")
        settings = render_settings(settings)
        (work / "settings.cfg").write_text(settings, encoding="utf-8")
        flow = (FPGA / "project/flow.tcl").read_text(encoding="utf-8")
        flow = flow.replace(
            "### Editable zone for opt_rtl ###",
            "set_param rtl min_control_set 2",
        ).replace(
            "### Editable zone for opt_gate ###",
            "set_param gate pack_effort high",
        )
        if phase == "phy" and profile == "pipelined":
            flow = flow.replace(
                "### Editable zone for opt_place ###",
                "set_param place enforce_phys_opt off\nset_param place phys_opt off",
            )
        flow = re.sub(r"^exit\s*$", "", flow, flags=re.M)
        if phase == "phy":
            flow += "\nreport_clock_intersection -file clock_intersection.rpt\n"
            flow += "report_timing_summary -file final_timing.rpt\n"
        flow = (
            "if {[catch {\n"
            + flow
            + "\n} result]} {puts stderr $result; exit 1}\n"
            + f'puts "BIRDGUARD_{phase.upper()}_COMPLETE"\nexit 0\n'
        )
        (work / "flow.tcl").write_text(flow, encoding="utf-8")
    return dependencies


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("single", "pipelined"), default="single")
    parser.add_argument(
        "--phase", choices=("prepare", "syn", "phy", "all"), default="all"
    )
    parser.add_argument("--td-bin", default=os.environ.get("TD_BIN"))
    args = parser.parse_args()
    destination = ROOT / "build/fpga" / args.profile
    dependencies = prepare(args.profile, destination)
    source_identity = inputs(args.profile)
    (destination / "source_identity.json").write_text(
        json.dumps(source_identity, indent=2) + "\n", encoding="utf-8"
    )
    if args.phase == "prepare":
        print(json.dumps({"profile": args.profile, "dependencies": len(dependencies)}))
        return
    executable = td_executable(args.td_bin)
    compiled_build_identity = build_identity(destination, executable)
    phases = ("syn", "phy") if args.phase == "all" else (args.phase,)
    for phase in phases:
        work = destination / phase
        if phase == "phy":
            previous = json.loads(
                (destination / "syn/compiled_identity.json").read_text()
            )
            if previous != source_identity:
                raise SystemExit("Run synthesis with the current design inputs first.")
            previous_build = json.loads(
                (destination / "syn/compiled_build_identity.json").read_text()
            )
            gate = destination / "syn/birdguard_gate.db"
            if previous_build["build"] != compiled_build_identity or previous_build[
                "gate_sha256"
            ] != digest(gate):
                raise SystemExit(
                    "Run synthesis with the current build configuration first."
                )
        phase_identity = {
            name: digest(work / name)
            for name in ("flow.tcl", "settings.cfg", "birdguard.prj")
        }
        started = time.monotonic()
        with (work / "run.log").open("wb") as log:
            result = subprocess.run(
                [str(executable), "flow.tcl"],
                cwd=work,
                stdout=log,
                stderr=subprocess.STDOUT,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        log = (work / "run.log").read_text(errors="replace")
        passed = (
            result.returncode == 0
            and f"BIRDGUARD_{phase.upper()}_COMPLETE" in log
            and "USR-8159" not in log
            and "USR-8012" not in log
            and inputs(args.profile) == source_identity
            and build_identity(destination, executable) == compiled_build_identity
            and phase_identity == {name: digest(work / name) for name in phase_identity}
        )
        record = {
            "profile": args.profile,
            "phase": phase,
            "passed": passed,
            "seconds": round(time.monotonic() - started, 2),
            "source_identity_sha256": digest(destination / "source_identity.json"),
            "tool_sha256": digest(executable),
            "build_identity": compiled_build_identity,
            "phase_inputs": phase_identity,
        }
        if passed and phase == "syn":
            (work / "compiled_identity.json").write_text(
                json.dumps(source_identity, indent=2) + "\n", encoding="utf-8"
            )
            (work / "compiled_build_identity.json").write_text(
                json.dumps(
                    {
                        "build": compiled_build_identity,
                        "gate_sha256": digest(work / "birdguard_gate.db"),
                    },
                    indent=2,
                )
                + "\n"
            )
        if passed and phase == "phy":
            record["timing"] = check_routed(work, work / "birdguard.bit")
            compressed_source = work / "birdguard_compress.bit"
            if (
                not compressed_source.is_file()
                or compressed_source.stat().st_size < 100000
            ):
                raise SystemExit("Compressed bitstream was not generated.")
            target = FPGA / "bitstreams" / f"birdguard_{args.profile}.bit"
            compressed_target = target.with_name(
                f"birdguard_{args.profile}_compress.bit"
            )
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(work / "birdguard.bit", target)
            shutil.copyfile(compressed_source, compressed_target)
            record["bitstream_sha256"] = digest(target)
            record["compressed_bitstream_sha256"] = digest(compressed_target)
        (work / "result.json").write_text(json.dumps(record, indent=2) + "\n")
        print(json.dumps(record), flush=True)
        if not passed:
            raise SystemExit(f"Build stopped; see {work / 'run.log'}")


if __name__ == "__main__":
    main()
