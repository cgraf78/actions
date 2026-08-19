#!/usr/bin/env python3

import os
import signal
import subprocess
import sys


def main() -> int:
    timeout_seconds = int(sys.argv[1])
    kill_grace_seconds = int(sys.argv[2])
    command = sys.argv[4:]
    process = subprocess.Popen(command, start_new_session=True)
    try:
        return process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=kill_grace_seconds)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        return 124


if __name__ == "__main__":
    sys.exit(main())
