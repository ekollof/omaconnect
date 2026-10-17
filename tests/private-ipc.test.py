"""Private payloads use stdin/socket only; fake daemon never sends phone traffic."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile

helper = str(Path(__file__).resolve().parents[1] / "bin/omaconnect-exec")
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    (root / 'kcd').mkdir()
    path = root / 'kcd/kcd.sock'
    env = dict(os.environ, XDG_RUNTIME_DIR=directory, XDG_CONFIG_HOME=str(root / 'config'))
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(path))
    path.chmod(0o600)
    server.listen()
    server.settimeout(2)
    for command, extra in [('send_sms', {'phoneNumber': '+secret-number'}),
                           ('notify_reply', {'replyId': 'private-reply'})]:
        payload = {'deviceId': 'test-device', 'message': 'secret-☃\nmessage', **extra}
        request = {'cmd': command, 'payload': payload}
        proc = subprocess.Popen([helper, 'private'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=env)
        proc.stdin.write(json.dumps(request).encode() + b'\n')
        proc.stdin.flush()
        connection, _ = server.accept()
        with connection:
            received = connection.makefile('rb').readline()
            assert json.loads(received) == request
            cmdline = Path(f'/proc/{proc.pid}/cmdline').read_bytes()
            assert b'secret' not in cmdline and b'private-reply' not in cmdline
            assert b'secret' not in Path(f'/proc/{proc.pid}/environ').read_bytes()
            children = Path(f'/proc/{proc.pid}/task/{proc.pid}/children').read_text().strip()
            assert not children, 'private action must not launch a kcd client'
            connection.sendall(b'{"ok":true}\n')
        proc.stdin.close()
        proc.stdin = None
        out, err = proc.communicate(timeout=2)
        assert proc.returncode == 0 and b'secret' not in out + err

    for data in [b'x' * 65537, b'{}\n', b'{"cmd":"status","payload":{}}\n', b'invalid\n']:
        result = subprocess.run([helper, 'private'], input=data, capture_output=True, env=env, timeout=2)
        assert result.returncode == 3 and not result.stdout

    request = json.dumps({'cmd': 'send_sms', 'payload': {
        'deviceId': 'test', 'phoneNumber': '+secret', 'message': 'secret'}}).encode() + b'\n'
    for response in [b'{"ok":false,"error":"secret"}\n', b'x' * 65537, b'not json\n']:
        proc = subprocess.Popen([helper, 'private'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=env)
        proc.stdin.write(request)
        proc.stdin.close()
        proc.stdin = None
        connection, _ = server.accept()
        with connection:
            connection.recv(65536)
            connection.sendall(response)
        out, err = proc.communicate(timeout=2)
        assert proc.returncode == 3 and b'secret' not in out + err

    path.chmod(0o666)
    result = subprocess.run([helper, 'private'], input=request, capture_output=True, env=env, timeout=2)
    assert result.returncode == 3
    path.chmod(0o600)
    # Honor the same configured socket override as the native kcd client.
    config = root / 'config/kcd'
    config.mkdir(parents=True)
    alternate = root / 'alternate.sock'
    path.rename(alternate)
    (config / 'kcd.toml').write_text('socket_path = ' + json.dumps(str(alternate)) + '\n')
    proc = subprocess.Popen([helper, 'private'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=env)
    proc.stdin.write(request)
    proc.stdin.close()
    proc.stdin = None
    connection, _ = server.accept()
    with connection:
        assert json.loads(connection.recv(65536))['cmd'] == 'send_sms'
        connection.sendall(b'{"ok":true}\n')
    assert proc.communicate(timeout=2)[1] == b'' and proc.returncode == 0

    # A connected daemon which never answers also has a whole-action deadline.
    proc = subprocess.Popen([helper, 'private'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=env)
    proc.stdin.write(request)
    proc.stdin.close()
    proc.stdin = None
    connection, _ = server.accept()
    with connection:
        connection.recv(65536)
        proc.communicate(timeout=7)
    assert proc.returncode == 124
    # No stdin record must time out instead of waiting forever.
    proc = subprocess.Popen([helper, 'private'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=env)
    proc.wait(timeout=7)
    assert proc.returncode == 124
    proc.stdin.close()
    (config / 'kcd.toml').unlink()
    os.mkfifo(config / 'kcd.toml')
    result = subprocess.run([helper, 'private'], input=request, capture_output=True, env=env, timeout=2)
    assert result.returncode == 3, 'special-file config must not block the helper'
    server.close()
print('PASS: stdin/socket round trips, argv privacy, no children, limits, errors, permissions and timeout')
