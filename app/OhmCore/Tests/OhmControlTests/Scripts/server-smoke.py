"""Compile the actual app listener and check its transport without touching user processes."""
import json
import os
from pathlib import Path
import select
import socket
import stat
import subprocess
import tempfile
import time
import uuid


def request(operation="top", target=None, version=1):
    return {"version": version, "id": str(uuid.uuid4()), "operation": operation,
            "target": target, "off": False}


def exchange(path, payload):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
        peer.settimeout(3)
        peer.connect(path)
        peer.sendall(payload)
        response = bytearray()
        while not response.endswith(b"\n"):
            chunk = peer.recv(4096)
            if not chunk:
                raise AssertionError("response closed before newline")
            response.extend(chunk)
            assert len(response) <= 65536
        return json.loads(response)


def start(binary, path, seconds):
    process = subprocess.Popen([str(binary), str(path), str(seconds)], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    readable, _, _ = select.select([process.stdout], [], [], 3)
    if not readable or process.stdout.readline().strip() != "READY":
        process.kill()
        _, error = process.communicate(timeout=3)
        raise AssertionError("listener startup failed: " + error)
    return process


def main():
    script = Path(__file__).resolve()
    package = script.parents[3]
    environment = dict(os.environ, CLANG_MODULE_CACHE_PATH="/tmp/t033a-clang",
                       SWIFTPM_MODULECACHE_OVERRIDE="/tmp/t033a-swift")
    build = subprocess.run(["swift", "build", "--target", "OhmControl", "--disable-sandbox",
                            "--cache-path", "/tmp/t033a-spm"], cwd=package, env=environment,
                           capture_output=True, text=True)
    assert build.returncode == 0, build.stdout + build.stderr
    products = Path(subprocess.check_output(["swift", "build", "--show-bin-path", "--disable-sandbox",
                                            "--cache-path", "/tmp/t033a-spm"], cwd=package,
                                           env=environment, text=True).strip())
    with tempfile.TemporaryDirectory(prefix="ohm-ctl-", dir="/tmp") as directory:
        directory = Path(directory)
        binary = directory / "server"
        compile_result = subprocess.run([
            "swiftc", "-disable-sandbox", "-swift-version", "6", "-target", "arm64-apple-macos26.0",
            "-module-cache-path", "/tmp/t033a-clang", "-I", str(products),
            str(package.parent / "OhmApp/Runtime/ControlServer.swift"),
            str(script.with_name("ServerHarness.swift")), str(products / "OhmControl.o"),
            str(products / "OhmModel.o"), "-o", str(binary)], capture_output=True, text=True)
        assert compile_result.returncode == 0, compile_result.stdout + compile_result.stderr
        path = directory / "control.sock"
        processes = []
        peers = []
        try:
            first = start(binary, path, 30)
            processes.append(first)
            assert stat.S_IMODE(path.stat().st_mode) == 0o600
            normal = request()
            response = exchange(str(path), json.dumps(normal).encode() + b"\n")
            assert response["id"].lower() == normal["id"] and response["top"]["watts"] == 1
            invalid = request(version=99)
            response = exchange(str(path), json.dumps(invalid).encode() + b"\n")
            assert response["error"]["code"] == "unsupportedVersion" and response["id"].lower() == invalid["id"]
            assert exchange(str(path), b"broken\n")["error"]["code"] == "malformed"
            assert exchange(str(path), b" " * 65537 + b"\n")["error"]["code"] == "tooLarge"
            duplicate = subprocess.run([str(binary), str(path), "1"], capture_output=True, text=True)
            assert duplicate.returncode == 1 and path.is_socket()
            for _ in range(8):
                peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                peer.settimeout(3)
                peer.connect(str(path))
                peer.sendall(b"{")
                peers.append(peer)
            time.sleep(0.2)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as excess:
                excess.settimeout(2)
                excess.connect(str(path))
                try:
                    assert excess.recv(1) == b""
                except ConnectionResetError:
                    pass
            time.sleep(2.2)
            for peer in peers:
                assert peer.recv(1) == b""
                peer.close()
            peers.clear()
            assert exchange(str(path), json.dumps(request()).encode() + b"\n")["message"] == "fixture"
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as delayed:
                delayed.settimeout(7)
                delayed.connect(str(path))
                delayed.sendall(json.dumps(request("freeze", "delay")).encode() + b"\n")
                started = time.monotonic()
                assert delayed.recv(1) == b""
                assert time.monotonic() - started < 6.5
            first.kill()
            first.communicate(timeout=3)
            assert path.is_socket()  # A real kill -9 leaves the app socket stale.
            restarted = start(binary, path, 1)
            processes.append(restarted)
            assert exchange(str(path), json.dumps(request()).encode() + b"\n")["message"] == "fixture"
            restarted.communicate(timeout=3)
            assert restarted.returncode == 0 and not path.exists()
            victim = directory / "victim"
            victim.write_text("untouched")
            path.symlink_to(victim)
            rejected = subprocess.run([str(binary), str(path), "1"], capture_output=True, text=True)
            assert rejected.returncode == 1 and path.is_symlink() and victim.read_text() == "untouched"
            print("CONTROL_SERVER_SMOKE_OK: 0600, UID path, JSON, bounds, timeouts, peer cap, duplicate, kill-9 restart, cleanup, symlink refusal")
        finally:
            for peer in peers:
                peer.close()
            for process in processes:
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=3)


if __name__ == "__main__":
    main()
