import re, hashlib
from pathlib import Path

if not __debug__:
    raise RuntimeError("Run timing verification without Python optimization.")


def check_cdc_exceptions(text, budgets):
    command = re.compile(
        r"set_max_delay\s+-from\s+\[get_clocks\s+\{([^}]+)\}\]\s+-to\s+\[get_clocks\s+\{([^}]+)\}\]\s+-datapath_only\s+([\d.]+)\s*$"
    )
    summary = text.split("MCP/SMD Summary", 1)[1].split("Min Check", 1)[0]
    rows = {pair: [] for pair in budgets}
    for m in re.finditer(
        r"^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(set_max_delay[^\r\n]+)", summary, re.M
    ):
        cmd = command.fullmatch(m[5].strip())
        if not cmd or (cmd[1], cmd[2]) not in budgets:
            continue
        pair = (cmd[1], cmd[2])
        counts = tuple(int(m[n]) for n in range(1, 5))
        assert float(cmd[3]) == budgets[pair], ("Unexpected CDC limit", pair, cmd[3])
        total, dominated, shadowed, ignored = counts
        assert total == dominated and total > 0 and shadowed == 0 and ignored == 0, (
            "CDC exception not fully effective",
            pair,
            counts,
        )
        rows[pair].append(counts)
    result = {}
    starts = list(re.finditer(r"^Path Group\s*:", text, re.M))
    for pair, limit in budgets.items():
        assert len(rows[pair]) == 1, (
            "Missing or duplicate CDC summary",
            pair,
            rows[pair],
        )
        groups = []
        for n, start in enumerate(starts):
            block = text[
                start.start() : (
                    starts[n + 1].start() if n + 1 < len(starts) else len(text)
                )
            ]
            header = block.split("Max Paths", 1)[0]
            found = []
            for line in header.splitlines():
                cmd = command.fullmatch(line.strip())
                if cmd and (cmd[1], cmd[2]) == pair:
                    found.append(cmd)
            if not found:
                continue
            assert all(float(cmd[3]) == limit for cmd in found), (
                "Wrong CDC group limit",
                pair,
            )
            assert re.search(r"^Type\s*:\s*SMD\s*$", header, re.M), (
                "CDC group ignored or not SMD",
                pair,
            )
            stats = re.findall(
                r"^(Max|Min)\s*:\s+(?:SWNS|HWNS)\s+([\d.-]+)ns,\s*(?:STNS|HTNS)\s+([\d.-]+)ns,\s*(\d+)\s+Viol Endpoints,\s*(\d+)\s+Total Endpoints\s*$",
                header,
                re.M,
            )
            assert stats and any(
                kind == "Max" and int(total) > 0
                for kind, wns, tns, viol, total in stats
            ), ("Empty CDC group", pair)
            for kind, wns, tns, viol, total in stats:
                assert float(wns) >= 0 and float(tns) == 0 and int(viol) == 0, (
                    "CDC timing violation",
                    pair,
                    kind,
                    wns,
                    tns,
                    viol,
                )
            path_budgets = [
                float(v) for v in re.findall(r"^Budget\s*:\s*([\d.]+)ns", block, re.M)
            ]
            delays = [
                float(v)
                for v in re.findall(r"^Data Path Delay\s*:\s*([\d.]+)ns", block, re.M)
            ]
            assert path_budgets and len(path_budgets) == len(delays), (
                "Missing CDC path evidence",
                pair,
            )
            assert all(v == limit for v in path_budgets), (
                "Wrong reported CDC budget",
                pair,
                path_budgets,
            )
            assert all(0 <= v <= limit for v in delays), (
                "CDC data delay exceeds limit",
                pair,
                delays,
            )
            groups.append(
                dict(
                    max_endpoints=sum(
                        int(total)
                        for kind, wns, tns, viol, total in stats
                        if kind == "Max"
                    ),
                    reported_paths=len(delays),
                    max_reported_data_delay_ns=max(delays),
                )
            )
        assert groups, ("Missing effective CDC SMD group", pair)
        result[" -> ".join(pair)] = dict(
            limit_ns=limit, dominated_paths=rows[pair][0][1], groups=groups
        )
    return result


def check_routed(root, bit_path=None):
    root = Path(root)
    text = (root / "final_timing.rpt").read_text(errors="replace")
    assert re.search(
        r"^Confidence\s*:\s*Routed\s*$", text, re.M
    ), "Timing is not routed"
    values = {
        k: float(re.search(k + r": ([\d.-]+)ns", text)[1])
        for k in ["SWNS", "STNS", "HWNS", "HTNS"]
    }
    assert (
        values["SWNS"] >= 0
        and values["HWNS"] >= 0
        and values["STNS"] == values["HTNS"] == 0
    ), values
    for name, mhz in [("sys_clk_50m", "50.000"), ("HDMI_PIXEL_CLK", "75.000")]:
        assert re.search(
            r"^\s*clk\d+:\s+"
            + re.escape(mhz)
            + r"\s+\d+\s+"
            + re.escape(name)
            + r"\s*$",
            text,
            re.M,
        ), name
    coverage = float(re.search(r"STA coverage\s*:\s*([\d.]+)%", text)[1])
    budgets = {
        ("sys_clk_50m", "HDMI_PIXEL_CLK"): 13.0,
        ("HDMI_PIXEL_CLK", "sys_clk_50m"): 13.0,
    }
    cdc = check_cdc_exceptions(
        (root / "birdguard_exception.timing").read_text(errors="replace"), budgets
    )
    intersection = (root / "clock_intersection.rpt").read_text(errors="replace")
    assert len(intersection) > 500 and all(
        x in intersection for x in ["sys_clk_50m", "HDMI_PIXEL_CLK"]
    )
    bit = Path(bit_path) if bit_path is not None else root / "bird_board.bit"
    assert bit.stat().st_size > 100000
    return dict(
        status="ROUTED_TIMING_PASS",
        timing_ns=values,
        sta_coverage_percent=coverage,
        cdc=cdc,
        bit_sha256=hashlib.sha256(bit.read_bytes()).hexdigest(),
        constraints_scope="Logic/display clock crossings constrained to 13 ns.",
    )
