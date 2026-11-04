from pathlib import Path
import argparse, os, subprocess, struct, json, time, threading


def crc(data):
    c = 0xFFFF
    for v in data:
        c ^= v << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021 if c & 0x8000 else c << 1) & 0xFFFF
    return c


def image(request, session=1, full=True, change=False):
    w = h = 128 if full else 4
    body = struct.pack(
        "<I7HBB", request, request % 4, 320, 240, 10, 20, w, h, 1, 0
    ) + bytes([(request + int(change)) & 255]) * (w * h)
    head = b"\xaa\x55\x01\x01" + struct.pack("<IIH", session, request, len(body))
    data = head + struct.pack("<H", crc(head[2:])) + body
    return data + struct.pack("<H", crc(data[2:]))


def decode(data):
    rows = []
    while data:
        assert len(data) >= 18 and data[:4] == b"\xaa\x55\x01\x81", data[:32]
        sid, rid, n = struct.unpack_from("<IIH", data, 4)
        end = 18 + n
        assert n in (8, 16) and len(data) >= end
        assert crc(data[2:14]) == struct.unpack_from("<H", data, 14)[0]
        assert crc(data[2 : end - 2]) == struct.unpack_from("<H", data, end - 2)[0]
        status, decision, confidence, flags = struct.unpack_from("<4B", data, 16)
        rows.append(
            dict(
                session=sid,
                request=rid,
                status=status,
                decision=decision,
                confidence=confidence,
                flags=flags,
            )
        )
        data = data[end:]
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bridge", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    root = Path(args.output)
    root.mkdir(parents=True, exist_ok=True)
    records = []

    def case(name, payload, actions, extra=(), expect=None):
        d = root / name
        d.mkdir(exist_ok=True)
        script = d / "actions.txt"
        script.write_text("\n".join(actions) + "\n")
        cmd = [
            args.bridge,
            "--stdio",
            "--mock-script",
            str(script),
            "--result-ext",
            *extra,
        ]
        env = os.environ.copy()
        env["REPLY_REPEAT"] = "1"
        start = time.monotonic()
        p = subprocess.run(cmd, input=payload, capture_output=True, env=env, timeout=20)
        elapsed = time.monotonic() - start
        (d / "stdout.bin").write_bytes(p.stdout)
        (d / "stderr.log").write_bytes(p.stderr)
        assert p.returncode == 0, (
            name,
            p.returncode,
            p.stderr.decode(errors="replace"),
        )
        rows = decode(p.stdout)
        log = p.stderr.decode(errors="replace")
        assert all(r["flags"] & 1 for r in rows), (
            name,
            "mock reply missing simulated flag",
        )
        if expect:
            expect(rows, log)
        records.append(
            dict(name=name, passed=True, seconds=round(elapsed, 4), replies=rows)
        )
        return rows, log

    def normal(rows, log):
        assert sorted(r["request"] for r in rows) == [1, 2, 3, 4]
        assert all(r["status"] == 0 for r in rows)
        assert log.rfind("REQUEST t_ms=") < log.find(
            "PERF "
        ), "RX was blocked by inference"
        assert "peak_pending=4" in log and "overload=0" in log

    payload = b"".join(image(i) for i in range(1, 5))
    case("receive_while_inference", payload, ["delay 200 bird 0.95"] * 4, expect=normal)
    case(
        "four_workers",
        payload,
        ["delay 200 bird 0.95"] * 4,
        extra=["--workers", "4"],
        expect=lambda r, l: (
            normal(r, l),
            (
                None
                if "peak_running=4" in l
                else (_ for _ in ()).throw(
                    AssertionError("four workers did not overlap")
                )
            ),
        ),
    )
    case(
        "reply_delay_rx",
        payload,
        ["delay 20 none"] * 4,
        extra=["--reply-delay-ms", "100"],
        expect=lambda r, l: (
            None
            if len(r) == 4 and all(x["status"] == 0 for x in r)
            else (_ for _ in ()).throw(AssertionError(r))
        ),
    )

    def overload(rows, log):
        assert len(rows) == 5 and sum(r["status"] == 0 for r in rows) == 4
        assert next(r for r in rows if r["request"] == 5)["status"] == 2
        assert "overload=1" in log

    case(
        "bounded_overload", payload + image(5), ["delay 100 none"] * 5, expect=overload
    )

    def duplicate(rows, log):
        one = [r for r in rows if r["request"] == 1]
        assert sorted(r["status"] for r in one) == [0, 1] and len(rows) == 5
        assert (
            "duplicate_pending=1" in log
            and "inference_calls=4" in log
            and "conflicts=1" in log
        )

    case(
        "pending_duplicate_conflict",
        image(1)
        + image(1)
        + image(1, change=True)
        + b"".join(image(i) for i in range(2, 5)),
        ["delay 100 bird 0.9"] * 4,
        expect=duplicate,
    )
    broken = bytearray(image(1))
    broken[-1] ^= 0x40
    case(
        "crc_recovery",
        b"noise\x00\xff" + broken + image(2),
        ["none"],
        expect=lambda r, l: (
            None
            if len(r) == 1 and r[0]["request"] == 2 and "bad_crc=1" in l
            else (_ for _ in ()).throw(AssertionError((r, l)))
        ),
    )
    case(
        "bounded_deadline",
        payload,
        ["delay 300 bird 0.99"] * 4,
        extra=["--worker-ms", "100", "--request-ms", "150"],
        expect=lambda r, l: (
            None
            if len(r) == 4 and all(x["status"] == 4 and x["decision"] == 255 for x in r)
            else (_ for _ in ()).throw(AssertionError(r))
        ),
    )
    capture = root / "capture_limit" / ("captures_" + str(time.time_ns()))
    case(
        "capture_limit",
        payload,
        ["none"] * 4,
        extra=["--capture-dir", str(capture), "--capture-limit", "2"],
        expect=lambda r, l: (
            None
            if len(r) == 4
            and all(x["status"] == 0 for x in r)
            and "CAPTURE_LIMIT reached=2" in l
            else (_ for _ in ()).throw(AssertionError((r, l)))
        ),
    )
    assert len(list(capture.glob("*.ppm"))) == 2
    # Keep stdin open until completion, then replay: requires a genuinely polling
    # bridge, not an EOF-triggered batch processor.
    d = root / "live_cache_session"
    d.mkdir(exist_ok=True)
    script = d / "actions.txt"
    script.write_text("delay 60 bird 0.91\ndelay 150 none\ndelay 20 bird 0.92\n")
    env = os.environ.copy()
    env["REPLY_REPEAT"] = "1"
    p = subprocess.Popen(
        [args.bridge, "--stdio", "--mock-script", str(script), "--result-ext"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    log = []
    out = []
    event = threading.Condition()

    def stderr():
        for line in iter(p.stderr.readline, b""):
            with event:
                log.append(line.decode(errors="replace"))
                event.notify_all()

    def stdout():
        for byte in iter(lambda: p.stdout.read(1), b""):
            out.append(byte)

    a = threading.Thread(target=stderr)
    b = threading.Thread(target=stdout)
    a.start()
    b.start()

    def wait_text(text):
        end = time.monotonic() + 5
        with event:
            while text not in "".join(log):
                remain = end - time.monotonic()
                assert remain > 0, (text, log)
                event.wait(remain)

    p.stdin.write(image(1, full=False))
    p.stdin.flush()
    wait_text("REPLYSENT session=1 request=1")
    p.stdin.write(image(1, full=False))
    p.stdin.flush()
    wait_text("cache_hits=") if False else None
    time.sleep(0.03)
    p.stdin.write(image(2, full=False))
    p.stdin.flush()
    wait_text("request=2 bytes=")
    p.stdin.write(image(1, session=2, full=False))
    p.stdin.flush()
    time.sleep(0.01)
    p.stdin.write(image(3, session=1, full=False))
    p.stdin.close()
    p.wait(timeout=10)
    a.join(2)
    b.join(2)
    data = b"".join(out)
    text = "".join(log)
    (d / "stdout.bin").write_bytes(data)
    (d / "stderr.log").write_text(text)
    assert p.returncode == 0, text
    rows = decode(data)
    assert (
        sum(r["session"] == 1 and r["request"] == 1 and r["status"] == 0 for r in rows)
        == 2
    ), rows
    assert not any(r["session"] == 1 and r["request"] == 2 for r in rows), rows
    assert any(
        r["session"] == 2 and r["request"] == 1 and r["status"] == 0 for r in rows
    ), rows
    assert any(
        r["session"] == 1 and r["request"] == 3 and r["status"] == 5 for r in rows
    ), rows
    assert "cache_hits=1" in text and "cancelled=1" in text, text
    records.append(dict(name="live_cache_session", passed=True, replies=rows))
    report = dict(
        passed=True,
        records=records,
        scope="Real bidirectional process pipes with fragmented parser input and concurrent scripted workers; all classifications SIMULATED; no physical UART/NPU claim",
    )
    (root / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(
        json.dumps(
            dict(passed=True, cases=len(records), output=str(root / "result.json"))
        )
    )


if __name__ == "__main__":
    main()
