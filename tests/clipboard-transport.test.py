"""Exercise the byte/time boundaries used by GuardedTextField's paste path."""
from pathlib import Path
import subprocess
import time

helper = str(Path(__file__).resolve().parents[1] / "bin/omaconnect-exec")


def run(*command):
    return subprocess.run(
        [helper, "run", "16384", "--", *command], capture_output=True, timeout=4
    )


result = run("python3", "-c", 'import sys; sys.stdout.write("x" * 16385)')
assert result.returncode == 3 and not result.stdout

start = time.monotonic()
result = run(
    "timeout", "--kill-after=1s", "0.2s",
    "python3", "-c", "import time; time.sleep(20)",
)
assert result.returncode == 124 and time.monotonic() - start < 4

result = run("python3", "-c", 'print("hello", end="")')
assert result.returncode == 0 and result.stdout == b"hello"
print("PASS: paste transport rejects oversized and stalled output; normal output survives")
