#!/usr/bin/env bash
set -euo pipefail

for program in python3 script jq; do
    command -v "$program" >/dev/null 2>&1 || { printf 'verify-recording: missing %s\n' "$program" >&2; exit 1; }
done
scaffold=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

# Python's standard-library PTY supplies a real terminal without an agent,
# container, credentials, network access or third-party test dependency.
exec python3 - "$scaffold" <<'PY'
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import termios
import time

scaffold = Path(sys.argv[1])
recorder = scaffold / "sandbox-record.sh"
passed = 0


def check(condition, message):
    if not condition:
        raise AssertionError(message)


class Terminal:
    def __init__(self, argv, env=None):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execvpe(argv[0], argv, env or os.environ)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        self.output = b""
        self.status = None

    def read(self, timeout=0.1):
        if select.select([self.fd], [], [], timeout)[0]:
            try:
                self.output += os.read(self.fd, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
        if self.status is None:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.status = os.waitstatus_to_exitcode(status)

    def until(self, predicate, timeout=15):
        deadline = time.monotonic() + timeout
        while not predicate():
            if time.monotonic() >= deadline:
                raise AssertionError("PTY timeout:\n" + self.output.decode(errors="replace"))
            self.read()

    def finish(self):
        self.until(lambda: self.status is not None)
        for _ in range(5):
            self.read(0.02)
        return self.status

    def close(self):
        if self.status is None:
            os.kill(self.pid, signal.SIGTERM)
            try:
                self.finish()
            except AssertionError:
                os.kill(self.pid, signal.SIGKILL)
                os.waitpid(self.pid, 0)
                raise
        os.close(self.fd)


with tempfile.TemporaryDirectory(prefix="sandbox-recording-test-") as temporary:
    root = Path(temporary)
    workspace = root / "workspace"
    workspace.mkdir()
    evidence = root / "evidence"
    fixture = root / "fixture.sh"
    fixture.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "[[ -t 0 && -t 1 && -t 2 ]]\n"
        "mode=$1; shift\n"
        "case $mode in\n"
        "  arguments) printf '<%s>\\n' \"$@\"; printf 'STDERR-MARKER\\n' >&2 ;;\n"
        "  fail) printf 'FAILURE-MARKER\\n' >&2; exit 42 ;;\n"
        "  input) printf 'INPUT-READY\\n'; IFS= read -r -s value; printf 'INPUT-RECEIVED\\n' ;;\n"
        "  progress) printf 'PROGRESS-BEFORE-WAIT\\n'; sleep 2; printf 'PROGRESS-AFTER-WAIT\\n' ;;\n"
        "  interrupt) printf 'INTERRUPT-READY\\n'; sleep 10 ;;\n"
        "  controlc) trap 'exit 130' INT; printf 'CONTROL-C-READY\\n'; sleep 10 ;;\n"
        "  resize) printf 'RESIZE-READY\\n'; IFS= read -r value; stty size ;;\n"
        "  exit125) exit 125 ;;\n"
        "esac\n",
        encoding="utf-8",
    )

    def arguments(label, mode, extras=(), output=evidence):
        return [
            "bash", str(recorder), "--label", label, "--workspace", str(workspace),
            "--output-root", str(output), "--", "bash", str(fixture), mode, *extras,
        ]

    def files(label):
        matches = list(evidence.glob(label + "-*"))
        check(len(matches) == 1, "Expected exactly one recording for " + label)
        return matches[0]

    def verify_files(directory):
        check(stat.S_IMODE(directory.stat().st_mode) == 0o700, "Private run directory")
        check(stat.S_IMODE(evidence.stat().st_mode) == 0o700, "Private output root")
        for file in directory.iterdir():
            check(stat.S_IMODE(file.stat().st_mode) == 0o600, "Private artifact: " + file.name)
        for line in (directory / "SHA256SUMS").read_text().splitlines():
            digest, name = line.split("  ", 1)
            check(hashlib.sha256((directory / name).read_bytes()).hexdigest() == digest, "Hash: " + name)
        return json.loads((directory / "outcome.json").read_text())

    def run(label, mode, expected=0, extras=()):
        terminal = Terminal(arguments(label, mode, extras))
        try:
            check(terminal.finish() == expected, terminal.output.decode(errors="replace"))
        finally:
            terminal.close()
        directory = files(label)
        return directory, verify_files(directory)

    special = ["space value", "apostrophe's", 'double"quote', "$literal;not-a-command", "", "two\nlines"]
    directory, outcome = run("arguments", "arguments", extras=special)
    check(outcome["state"] == "returned" and outcome["commandExitStatus"] == 0, "Normal return")
    launch = json.loads((directory / "launch.json").read_text())
    check(launch["command"] == ["bash", str(fixture), "arguments", *special], "Exact JSON argv")
    check((directory / "command.argv").read_bytes().split(b"\0")[:-1] ==
          [value.encode() for value in launch["command"]], "Exact NUL argv")
    output = (directory / "terminal.log").read_text()
    check("STDERR-MARKER" in output and "apostrophe's" in output and "$literal;not-a-command" in output, "Terminal output")
    passed += 1
    print("PASS argument preservation, TTY, stdout/stderr, permissions and hashes", flush=True)

    for label, mode, expected in [("failure", "fail", 42), ("launch125", "exit125", 125)]:
        directory, outcome = run(label, mode, expected)
        check(outcome["state"] == "returned" and outcome["commandExitStatus"] == expected and
              outcome["recorderExitStatus"] == expected and outcome["wrapperExitStatus"] == expected, "Exit propagation")
        passed += 1
        print("PASS launch exit " + str(expected), flush=True)

    terminal = Terminal(arguments("input", "input"))
    try:
        terminal.until(lambda: b"INPUT-READY" in terminal.output)
        time.sleep(0.1)
        os.write(terminal.fd, b"PRIVATE-INPUT-MARKER\n")
        check(terminal.finish() == 0, "Input run exit")
    finally:
        terminal.close()
    directory = files("input")
    verify_files(directory)
    check(b"PRIVATE-INPUT-MARKER" not in (directory / "terminal.log").read_bytes(), "No raw hidden-input capture")
    passed += 1
    print("PASS interactive input without hidden-input logging", flush=True)

    terminal = Terminal(arguments("progress", "progress"))
    try:
        terminal.until(lambda: b"PROGRESS-BEFORE-WAIT" in terminal.output)
        directory = files("progress")
        check(b"PROGRESS-BEFORE-WAIT" in (directory / "terminal.log").read_bytes(), "Output flushed while launch runs")
        check(not (directory / "command-exit.txt").exists(), "Launch is still running")
        check(terminal.finish() == 0, "Progress run exit")
    finally:
        terminal.close()
    verify_files(directory)
    passed += 1
    print("PASS live output retention before command completion", flush=True)

    terminal = Terminal(arguments("interrupt", "interrupt"))
    try:
        terminal.until(lambda: b"INTERRUPT-READY" in terminal.output)
        os.kill(terminal.pid, signal.SIGTERM)
        check(terminal.finish() == 143, "Interrupted wrapper status")
    finally:
        terminal.close()
    directory = files("interrupt")
    outcome = verify_files(directory)
    check(outcome["state"] == "interrupted" and outcome["interruptionSignal"] == "TERM", "Interruption outcome")
    check(b"INTERRUPT-READY" in (directory / "terminal.log").read_bytes(), "Interrupted output retained")
    passed += 1
    print("PASS owned-recorder interruption and retained partial output", flush=True)

    terminal = Terminal(arguments("controlc", "controlc"))
    try:
        terminal.until(lambda: b"CONTROL-C-READY" in terminal.output)
        os.write(terminal.fd, b"\x03")
        status = terminal.finish()
        check(status == 130, "Terminal Ctrl-C exit " + str(status) + ":\n" + terminal.output.decode(errors="replace"))
    finally:
        terminal.close()
    outcome = verify_files(files("controlc"))
    check(outcome["state"] == "returned" and outcome["commandExitStatus"] == 130, "Foreground interrupt exit")
    passed += 1
    print("PASS terminal Ctrl-C delivery and exit propagation", flush=True)

    terminal = Terminal(arguments("resize", "resize"))
    try:
        terminal.until(lambda: b"RESIZE-READY" in terminal.output)
        fcntl.ioctl(terminal.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 42, 132, 0, 0))
        time.sleep(0.1)
        os.write(terminal.fd, b"\n")
        check(terminal.finish() == 0 and b"42 132" in terminal.output, "Terminal resize reaches launch")
    finally:
        terminal.close()
    verify_files(files("resize"))
    passed += 1
    print("PASS terminal resize propagation", flush=True)

    result = subprocess.run(arguments("notty", "arguments"), stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    check(result.returncode == 125 and b"interactive terminal" in result.stderr, "Non-TTY refusal")
    check(not list(evidence.glob("notty-*")), "No non-TTY launch")
    passed += 1
    print("PASS non-interactive refusal", flush=True)

    public = root / "public"
    public.mkdir(mode=0o755)
    linked = root / "linked"
    linked.symlink_to(evidence, target_is_directory=True)
    for label, destination, diagnostic in [
        ("public", public, b"mode-700"),
        ("symlink", linked, b"Symlinked"),
        ("overlap", workspace / "evidence", b"overlaps"),
    ]:
        terminal = Terminal(arguments(label, "arguments", output=destination))
        try:
            check(terminal.finish() == 125 and diagnostic in terminal.output, terminal.output.decode(errors="replace"))
        finally:
            terminal.close()
        passed += 1
        print("PASS unsafe output refusal: " + label, flush=True)

    fake_bin = root / "fake-bin"
    fake_bin.mkdir()
    fake_script = fake_bin / "script"
    fake_script.write_text(
        "#!/usr/bin/env bash\n"
        "if [[ ${1:-} == --version ]]; then printf 'script from util-linux test\\n'; fi\n"
        "exit 0\n",
        encoding="utf-8",
    )
    fake_script.chmod(0o700)
    env = dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ["PATH"])
    terminal = Terminal(arguments("earlyexit", "arguments"), env)
    try:
        check(terminal.finish() == 125, "Recorder early-exit status")
    finally:
        terminal.close()
    outcome = verify_files(files("earlyexit"))
    check(outcome["state"] == "recording-error" and outcome["commandExitStatus"] is None, "No success-shaped fallback")
    passed += 1
    print("PASS recorder failure despite zero recorder exit", flush=True)

    fake_script.unlink()
    fake_hash = fake_bin / "sha256sum"
    fake_hash.write_text("#!/usr/bin/env bash\nprintf 'incomplete checksum output\\n'\nexit 1\n", encoding="utf-8")
    fake_hash.chmod(0o700)
    terminal = Terminal(arguments("hashfailure", "arguments"), env)
    try:
        check(terminal.finish() == 125 and b"Cannot finalize" in terminal.output, "Hash failure is explicit")
    finally:
        terminal.close()
    directory = files("hashfailure")
    check(not (directory / "SHA256SUMS").exists() and (directory / "terminal.log").exists(),
          "No partial published checksum list; evidence retained")
    passed += 1
    print("PASS checksum failure retains evidence without publishing completion", flush=True)

    original = files("arguments")
    before = {path.name: path.read_bytes() for path in original.iterdir()}
    terminal = Terminal(arguments("arguments", "arguments"))
    try:
        check(terminal.finish() == 0, "Repeated label run")
    finally:
        terminal.close()
    check(len(list(evidence.glob("arguments-*"))) == 2, "Repeated label creates a fresh directory")
    check(before == {path.name: path.read_bytes() for path in original.iterdir()}, "Previous recording unchanged")
    passed += 1
    print("PASS repeated labels never overwrite existing recordings", flush=True)

    default_command = arguments("default", "arguments")
    option = default_command.index("--output-root")
    del default_command[option:option + 2]
    state_root = root / "state"
    terminal = Terminal(default_command, dict(os.environ, XDG_STATE_HOME=str(state_root)))
    try:
        check(terminal.finish() == 0, "Default storage launch")
    finally:
        terminal.close()
    matches = list((state_root / "pera-sandbox-recordings").glob("default-*"))
    check(len(matches) == 1, "Default private XDG recording root")
    check(stat.S_IMODE(matches[0].parent.stat().st_mode) == 0o700, "Private default root")
    verify_files(matches[0])
    passed += 1
    print("PASS default storage under isolated XDG state", flush=True)

print(str(passed) + " recording checks passed; no agent or container launched.")
PY
