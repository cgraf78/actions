"""Send cancellation to the actual prerequisite step PID with only fixture tools."""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

TOOLS = {
    "apt-get": """
import os
import signal
import subprocess
import sys
import time

with open(os.environ['CALLS'], 'a') as calls:
    calls.write('apt-get\\n')
child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
def stop(*args):
    child.wait()
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
with open(os.environ['PACKAGE'], 'w') as package:
    package.write(f'{os.getpid()} {child.pid}\\n')
time.sleep(30)
""",
    "setsid": """
import os
import sys
import time
from pathlib import Path

if os.environ['PAUSE_SESSION']:
    Path(os.environ['PAUSE_SESSION']).write_text(f'{os.getpid()}\\n')
    time.sleep(30)
os.setsid()
with open(os.environ['SESSIONS'], 'a') as sessions:
    sessions.write(f'{os.getpid()}\\n')
os.execvp(sys.argv[1], sys.argv[1:])
""",
    "mktemp": """
import os
import subprocess
import sys
import time
from pathlib import Path

result = subprocess.check_output([os.environ['REAL_MKTEMP'], *sys.argv[1:]])
if os.environ['STARTUP'] and 'package-deadline.' in sys.argv[-1]:
    Path(os.environ['STARTUP']).touch()
    end = time.monotonic() + 5
    while not Path(os.environ['RESUME']).exists() and time.monotonic() < end:
        time.sleep(0.01)
sys.stdout.buffer.write(result)
""",
}


def action_command(action: Path) -> str:
    """Read the single shell step that GitHub hands to its sh entry process."""
    text = (action / "action.yml").read_text()
    assert "      shell: sh\n" in text, action
    prefix = "      run: "
    commands = [line[len(prefix) :] for line in text.splitlines() if line.startswith(prefix)]
    assert len(commands) == 1, action
    return commands[0]


def is_running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def check_cancel(root: Path, case: Path, name: str, signum: signal.Signals) -> None:
    """Require package and watchdog cleanup before the step returns."""
    case.mkdir()
    fixture_bin = case / "bin"
    fixture_bin.mkdir()
    for tool in ("dirname", "env", "ln", "rm", "sh", "sleep"):
        (fixture_bin / tool).symlink_to(shutil.which(tool))
    for name_tool, script in TOOLS.items():
        tool_path = fixture_bin / name_tool
        tool_path.write_text(f"#!{sys.executable}\n{script}")
        tool_path.chmod(0o755)
    action_dir = root / ".github/actions"
    if name == "nested":
        # Shell prerequisites also call retry_pkg from staging subshells.
        command = 'exec sh "$GITHUB_ACTION_PATH/../package-manager/run.sh" "$NESTED"'
        nested = case / "nested.sh"
        nested.write_text(
            '#!/bin/sh\nset -eu\n. "$GITHUB_ACTION_PATH/../package-manager/lib.sh"\n'
            '(cd "$NESTED_CWD" && retry_pkg apt-get update)\n'
        )
        nested.chmod(0o755)
        (case / "other-cwd").mkdir()
        action = action_dir / "shell-ci-prereqs"
    else:
        action = action_dir / ("rust-ci-prereqs" if name.endswith("-startup") else name)
        command = action_command(action)
    package = case / "package"
    sessions = case / "sessions"
    calls = case / "calls"
    starting = case / "starting"
    resume = case / "resume"
    starting_session = case / "starting-session"
    temp_parent = case / "temporary"
    temp_parent.mkdir()
    relative_temp = "temporary" if name == "nested" else str(temp_parent)
    environment = {
        "PATH": str(fixture_bin),
        "HOME": str(case),
        "TMPDIR": relative_temp,
        "XDG_CONFIG_HOME": str(case / "config"),
        "XDG_STATE_HOME": str(case / "state"),
        "XDG_CACHE_HOME": str(case / "cache"),
        "XDG_DATA_HOME": str(case / "data"),
        "GITHUB_ACTION_PATH": str(action),
        "NESTED": str(case / "nested.sh"),
        "NESTED_CWD": str(case / "other-cwd"),
        "MATRIX_NAME": "Debian",
        "PROFILES": "base",
        "SETUP": "none",
        "RUNNER_OS": "Linux",
        "APT_MIRROR_LIST": str(case / "absent-mirrors"),
        "PKG_RETRIES": "3",
        "PKG_COMMAND_TIMEOUT": "30",
        "PKG_COMMAND_KILL_AFTER": "0.1",
        "PACKAGE": str(package),
        "SESSIONS": str(sessions),
        "CALLS": str(calls),
        "STARTUP": str(starting) if name.startswith("watchdog-") else "",
        "PAUSE_SESSION": str(starting_session) if name == "installer-startup" else "",
        "RESUME": str(resume),
        "REAL_MKTEMP": shutil.which("mktemp"),
    }
    with (case / "stderr").open("w+") as stderr:
        process = subprocess.Popen(
            [str(fixture_bin / "sh"), "-e", "-c", command],
            env=environment,
            cwd=case,
            start_new_session=True,
            stdout=subprocess.DEVNULL,
            stderr=stderr,
        )
        try:
            deadline = time.monotonic() + 3
            pids = []
            while time.monotonic() < deadline and process.poll() is None:
                if starting.is_file() or (
                    starting_session.is_file() and starting_session.stat().st_size
                ):
                    break
                if package.is_file():
                    pids = [int(item) for item in package.read_text().split()]
                    if len(pids) == 2:
                        break
                time.sleep(0.01)
            assert starting.is_file() or starting_session.is_file() or len(pids) == 2, (
                f"{name}: did not start: {command!r}"
            )
            process.send_signal(signum)
            if name == "watchdog-startup":
                # Release mktemp only after the step has published the signal.
                deadline = time.monotonic() + 3
                while (
                    not list(temp_parent.glob("package-step.*/cancel"))
                    and time.monotonic() < deadline
                ):
                    time.sleep(0.01)
                assert list(temp_parent.glob("package-step.*/cancel")), (
                    "startup: no cancellation event"
                )
                resume.touch()
            try:
                status = process.wait(timeout=3)
            except subprocess.TimeoutExpired as error:
                raise AssertionError(f"{name}: step did not exit on {signum.name}") from error
            stderr.seek(0)
            output = stderr.read()
            assert status == 128 + signum, f"{name}: unexpected exit {status}: {output}"
            assert all(not is_running(pid) for pid in pids), f"{name}: package process survived"
            assert not list(temp_parent.iterdir()), f"{name}: watchdog scratch survived"
            if name.endswith("-startup"):
                assert not calls.exists(), "startup: began a package command after cancellation"
            else:
                assert calls.read_text() == "apt-get\n", f"{name}: restarted the package command"
            if name == "installer-startup":
                assert not is_running(int(starting_session.read_text())), (
                    "startup: installer launcher survived before setsid"
                )
            assert "infra-stall:" not in output, f"{name}: cancellation was classified as a stall"
        finally:
            # Tests must also tear down known groups when the code fails to.
            groups = [process.pid]
            if sessions.is_file():
                groups.extend(int(item) for item in sessions.read_text().split())
            for group in reversed(groups):
                try:
                    os.killpg(group, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.wait()
    print(f"{name}: {signum.name} reaped the package step")


if __name__ == "__main__":
    repo, temp = (Path(arg).resolve() for arg in sys.argv[1:])
    for action_name, cancellation in (
        ("rust-ci-prereqs", signal.SIGINT),
        ("musl-build-prereqs", signal.SIGTERM),
        ("shell-ci-prereqs", signal.SIGINT),
        ("nested", signal.SIGTERM),
        ("watchdog-startup", signal.SIGINT),
        ("watchdog-parked-startup", signal.SIGTERM),
        ("installer-startup", signal.SIGTERM),
    ):
        check_cancel(repo, temp / f"cancel-{action_name}", action_name, cancellation)
