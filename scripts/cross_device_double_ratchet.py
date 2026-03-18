#!/usr/bin/env python3

import argparse
import base64
import json
import os
import pathlib
import shlex
import subprocess
import sys
import time
import uuid


def log(message):
    print(message, flush=True)


class Endpoint:
    def __init__(self, name, repo, automation_dir, ssh_target=None):
        self.name = name
        self.raw_repo = repo
        self.raw_automation_dir = automation_dir
        self.ssh_target = ssh_target
        self.repo = self.expand_path(repo)
        self.automation_dir = self.expand_path(automation_dir)
        self.derived_data = f"{self.repo}/build/codex-macos"
        self.app_bundle = f"{self.derived_data}/Build/Products/Debug/bitchat.app"
        self.bundle_id = "chat.bitchat"

    def expand_path(self, path):
        if self.ssh_target is None:
            return os.path.expanduser(path)

        script = (
            "import os, sys\n"
            "print(os.path.expanduser(sys.argv[1]), end='')\n"
        )
        result = self.run_python(script, [path], capture_output=True)
        return result.stdout

    def run_shell(self, command, check=True, capture_output=False, tty=False):
        if self.ssh_target is None:
            return subprocess.run(
                ["/bin/zsh", "-lc", command],
                check=check,
                capture_output=capture_output,
                text=True,
            )

        ssh_command = ["ssh"]
        if tty:
            ssh_command.append("-tt")

        return subprocess.run(
            [*ssh_command, self.ssh_target, f"/bin/zsh -lc {shlex.quote(command)}"],
            check=check,
            capture_output=capture_output,
            text=True,
        )

    def run_python(self, script, args, check=True, capture_output=False):
        command = " ".join(
            shlex.quote(part)
            for part in ["/usr/bin/python3", "-c", script, *args]
        )
        return self.run_shell(command, check=check, capture_output=capture_output)

    def build(self):
        log(f"[{self.name}] building macOS app")
        command = (
            f"cd {shlex.quote(self.repo)} && "
            "xcodebuild "
            "-project bitchat.xcodeproj "
            "-scheme 'bitchat (macOS)' "
            "-destination 'platform=macOS' "
            f"-derivedDataPath {shlex.quote(self.derived_data)} "
            "CODE_SIGNING_ALLOWED=NO "
            "CODE_SIGNING_REQUIRED=NO "
            "CODE_SIGN_IDENTITY='' "
            "DEVELOPMENT_TEAM='' "
            "build"
        )
        self.run_shell(command)

    def launch(self):
        log(f"[{self.name}] launching app with automation dir {self.automation_dir}")
        quit_script = shlex.quote(f'tell application id "{self.bundle_id}" to quit')
        launch_arguments = (
            f"{shlex.quote(self.app_bundle)} --args "
            f"--automation-dir {shlex.quote(self.automation_dir)}"
        )

        if self.ssh_target is None:
            command = "\n".join(
                [
                    'uid="$(id -u)"',
                    (
                        'launchctl asuser "$uid" osascript '
                        f"-e {quit_script} "
                        '>/dev/null 2>&1 || true'
                    ),
                    "sleep 1",
                    "pkill -x bitchat >/dev/null 2>&1 || true",
                    f"rm -rf {shlex.quote(self.automation_dir)}",
                    f"mkdir -p {shlex.quote(self.automation_dir)}",
                    'launchctl asuser "$uid" open -n -a '
                    f"{launch_arguments}",
                ]
            )
            self.run_shell(command)
            return

        command = "\n".join(
            [
                f"osascript -e {quit_script} >/dev/null 2>&1 || true",
                "sleep 1",
                "pkill -x bitchat >/dev/null 2>&1 || true",
                f"rm -rf {shlex.quote(self.automation_dir)}",
                f"mkdir -p {shlex.quote(self.automation_dir)}",
                f"open -n -a {launch_arguments}",
            ]
        )
        self.run_shell(command, tty=True)

    def write_request(self, payload):
        request_id = payload["id"]
        encoded = base64.b64encode(
            json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
        ).decode("ascii")

        if self.ssh_target is None:
            request_dir = pathlib.Path(self.automation_dir) / "requests"
            request_dir.mkdir(parents=True, exist_ok=True)
            tmp_path = request_dir / f"{request_id}.tmp"
            final_path = request_dir / f"{request_id}.json"
            tmp_path.write_bytes(base64.b64decode(encoded))
            os.replace(tmp_path, final_path)
            return

        script = (
            "import base64, os, pathlib, sys\n"
            "root = pathlib.Path(os.path.expanduser(sys.argv[1]))\n"
            "request_dir = root / 'requests'\n"
            "request_dir.mkdir(parents=True, exist_ok=True)\n"
            "request_id = sys.argv[2]\n"
            "payload = base64.b64decode(sys.argv[3])\n"
            "tmp_path = request_dir / f'{request_id}.tmp'\n"
            "final_path = request_dir / f'{request_id}.json'\n"
            "tmp_path.write_bytes(payload)\n"
            "os.replace(tmp_path, final_path)\n"
        )
        self.run_python(script, [self.automation_dir, request_id, encoded])

    def read_text(self, path):
        if self.ssh_target is None:
            file_path = pathlib.Path(path)
            if not file_path.exists():
                return ""
            return file_path.read_text()

        script = (
            "import os, pathlib, sys\n"
            "path = pathlib.Path(os.path.expanduser(sys.argv[1]))\n"
            "print(path.read_text() if path.exists() else '', end='')\n"
        )
        result = self.run_python(script, [path], capture_output=True)
        return result.stdout

    def snapshot(self):
        text = self.read_text(f"{self.automation_dir}/state.json")
        if not text:
            return None
        return json.loads(text)

    def wait_for_snapshot(self, timeout_seconds):
        deadline = time.time() + timeout_seconds
        last_snapshot = None
        while time.time() < deadline:
            snapshot = self.snapshot()
            if snapshot and snapshot.get("myPeerID") and snapshot.get("myNoisePublicKeyHex"):
                return snapshot
            if snapshot:
                last_snapshot = snapshot
            time.sleep(0.5)
        raise RuntimeError(
            f"[{self.name}] automation state did not become ready within {timeout_seconds}s: "
            f"{json.dumps(last_snapshot, indent=2) if last_snapshot else 'no state.json'}"
        )

    def request(self, command, **fields):
        request_id = str(uuid.uuid4())
        payload = {"id": request_id, "command": command}
        payload.update(fields)
        self.write_request(payload)
        return self.wait_for_response(request_id, timeout_seconds=30)

    def wait_for_response(self, request_id, timeout_seconds):
        deadline = time.time() + timeout_seconds
        response_path = f"{self.automation_dir}/responses/{request_id}.json"
        while time.time() < deadline:
            text = self.read_text(response_path)
            if text:
                response = json.loads(text)
                if not response.get("ok"):
                    raise RuntimeError(
                        f"[{self.name}] automation command failed: {json.dumps(response, indent=2)}"
                    )
                return response
            time.sleep(0.5)
        raise RuntimeError(f"[{self.name}] timed out waiting for response {request_id}")


def find_peer(snapshot, remote_snapshot):
    remote_noise = remote_snapshot["myNoisePublicKeyHex"].lower()
    remote_peer_id = remote_snapshot["myPeerID"].lower()
    for peer in snapshot.get("peers", []):
        if peer["noisePublicKeyHex"].lower() == remote_noise:
            return peer
        if peer["peerID"].lower() == remote_peer_id:
            return peer
    return None


def find_chat(snapshot, counterpart_noise_key):
    target = counterpart_noise_key.lower()
    for chat in snapshot.get("privateChats", []):
        if (chat.get("counterpartNoisePublicKeyHex") or "").lower() == target:
            return chat
        if chat.get("conversationKey", "").lower() == target:
            return chat
    return None


def summarize_state(name, snapshot):
    peer_bits = []
    for peer in snapshot.get("peers", []):
        peer_bits.append(
            {
                "peerID": peer["peerID"],
                "name": peer["displayName"],
                "connected": peer["isConnected"],
                "favorite": peer["isFavorite"],
                "mutual": peer["isMutualFavorite"],
                "dr": peer["doubleRatchetEnabled"],
            }
        )
    return {
        "endpoint": name,
        "nickname": snapshot.get("nickname"),
        "myPeerID": snapshot.get("myPeerID"),
        "myNoisePublicKeyHex": snapshot.get("myNoisePublicKeyHex"),
        "myNostrPublicKey": snapshot.get("myNostrPublicKey"),
        "bluetoothState": snapshot.get("bluetoothState"),
        "peers": peer_bits,
    }


def wait_for_discovery(local, remote, timeout_seconds):
    deadline = time.time() + timeout_seconds
    last_local = None
    last_remote = None
    while time.time() < deadline:
        local_snapshot = local.snapshot()
        remote_snapshot = remote.snapshot()
        if local_snapshot and remote_snapshot:
            last_local = local_snapshot
            last_remote = remote_snapshot
            local_peer = find_peer(local_snapshot, remote_snapshot)
            remote_peer = find_peer(remote_snapshot, local_snapshot)
            if (
                local_peer is not None
                and remote_peer is not None
                and local_peer["isConnected"]
                and remote_peer["isConnected"]
            ):
                return local_snapshot, remote_snapshot, local_peer, remote_peer
        time.sleep(1.0)

    raise RuntimeError(
        "Peer discovery timed out.\n"
        f"Local: {json.dumps(summarize_state(local.name, last_local or {}), indent=2)}\n"
        f"Remote: {json.dumps(summarize_state(remote.name, last_remote or {}), indent=2)}"
    )


def wait_for_mutual_double_ratchet(local, remote, timeout_seconds):
    deadline = time.time() + timeout_seconds
    last_local = None
    last_remote = None
    while time.time() < deadline:
        local_snapshot = local.snapshot()
        remote_snapshot = remote.snapshot()
        if local_snapshot and remote_snapshot:
            last_local = local_snapshot
            last_remote = remote_snapshot
            local_peer = find_peer(local_snapshot, remote_snapshot)
            remote_peer = find_peer(remote_snapshot, local_snapshot)
            if (
                local_peer is not None
                and remote_peer is not None
                and local_peer["isMutualFavorite"]
                and remote_peer["isMutualFavorite"]
                and local_peer["doubleRatchetEnabled"]
                and remote_peer["doubleRatchetEnabled"]
            ):
                return local_snapshot, remote_snapshot, local_peer, remote_peer
        time.sleep(1.0)

    raise RuntimeError(
        "Mutual favorites / double-ratchet activation timed out.\n"
        f"Local: {json.dumps(summarize_state(local.name, last_local or {}), indent=2)}\n"
        f"Remote: {json.dumps(summarize_state(remote.name, last_remote or {}), indent=2)}"
    )


def wait_for_message(endpoint, counterpart_noise_key, token, timeout_seconds):
    deadline = time.time() + timeout_seconds
    last_snapshot = None
    while time.time() < deadline:
        snapshot = endpoint.snapshot()
        if snapshot:
            last_snapshot = snapshot
            chat = find_chat(snapshot, counterpart_noise_key)
            if chat:
                for message in chat.get("messages", []):
                    if message.get("content") == token:
                        return snapshot, chat, message
        time.sleep(1.0)

    raise RuntimeError(
        f"[{endpoint.name}] did not receive expected token {token!r}.\n"
        f"State: {json.dumps(summarize_state(endpoint.name, last_snapshot or {}), indent=2)}"
    )


def require_ndr_transport(endpoint, response):
    details = response.get("details") or {}
    transport_used = details.get("transportUsed")
    if transport_used != "ndr":
        raise RuntimeError(
            f"[{endpoint.name}] expected transportUsed=ndr but got "
            f"{transport_used!r}. Response: {json.dumps(response, indent=2)}"
        )
    return transport_used


def parse_args():
    parser = argparse.ArgumentParser(
        description="Build, launch, and verify cross-device bitchat double-ratchet messaging."
    )
    default_remote_host = os.environ.get("BITCHAT_REMOTE_HOST")
    parser.add_argument(
        "--local-repo",
        default=os.getcwd(),
        help="Path to the local bitchat repo. Defaults to the current working directory.",
    )
    parser.add_argument(
        "--remote-host",
        default=default_remote_host,
        help="SSH target for the second Mac. Required unless BITCHAT_REMOTE_HOST is set.",
    )
    parser.add_argument(
        "--remote-repo",
        default="~/src/bitchat",
        help="Path to the bitchat repo on the remote Mac.",
    )
    parser.add_argument(
        "--local-automation-dir",
        default="/tmp/bitchat-automation-laptop",
        help="Local automation state/request directory.",
    )
    parser.add_argument(
        "--remote-automation-dir",
        default="/tmp/bitchat-automation-mini",
        help="Remote automation state/request directory.",
    )
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="Reuse existing app builds instead of rebuilding.",
    )
    parser.add_argument(
        "--discover-timeout",
        type=int,
        default=60,
        help="Seconds to wait for BLE peer discovery.",
    )
    parser.add_argument(
        "--session-timeout",
        type=int,
        default=120,
        help="Seconds to wait for mutual favorites and double-ratchet activation.",
    )
    parser.add_argument(
        "--message-timeout",
        type=int,
        default=120,
        help="Seconds to wait for each private message to arrive.",
    )
    parser.add_argument(
        "--reply-settle-seconds",
        type=int,
        default=15,
        help="Seconds to wait after the first delivery before sending the reverse DR message.",
    )
    args = parser.parse_args()
    if not args.remote_host:
        parser.error("--remote-host is required unless BITCHAT_REMOTE_HOST is set")
    return args


def main():
    args = parse_args()

    local = Endpoint(
        name="laptop",
        repo=args.local_repo,
        automation_dir=args.local_automation_dir,
    )
    remote = Endpoint(
        name="mac-mini",
        repo=args.remote_repo,
        automation_dir=args.remote_automation_dir,
        ssh_target=args.remote_host,
    )

    if not args.skip_build:
        local.build()
        remote.build()

    local.launch()
    remote.launch()

    local_snapshot = local.wait_for_snapshot(timeout_seconds=45)
    remote_snapshot = remote.wait_for_snapshot(timeout_seconds=45)
    log(
        f"[laptop] ready peerID={local_snapshot['myPeerID']} "
        f"noise={local_snapshot['myNoisePublicKeyHex'][:8]}... "
        f"bluetooth={local_snapshot['bluetoothState']}"
    )
    log(
        f"[mac-mini] ready peerID={remote_snapshot['myPeerID']} "
        f"noise={remote_snapshot['myNoisePublicKeyHex'][:8]}... "
        f"bluetooth={remote_snapshot['bluetoothState']}"
    )

    local_snapshot, remote_snapshot, local_peer, remote_peer = wait_for_discovery(
        local,
        remote,
        timeout_seconds=args.discover_timeout,
    )
    log(
        f"[discovery] laptop sees {local_peer['displayName']} "
        f"({local_peer['peerID'][:8]}...) and mac-mini sees {remote_peer['displayName']} "
        f"({remote_peer['peerID'][:8]}...)"
    )

    local.request("setFavorite", target=local_peer["noisePublicKeyHex"], value=True)
    remote.request("setFavorite", target=remote_peer["noisePublicKeyHex"], value=True)
    local.request(
        "setFavoritedUs",
        target=local_peer["noisePublicKeyHex"],
        value=True,
        nostrPublicKey=remote_snapshot.get("myNostrPublicKey"),
    )
    remote.request(
        "setFavoritedUs",
        target=remote_peer["noisePublicKeyHex"],
        value=True,
        nostrPublicKey=local_snapshot.get("myNostrPublicKey"),
    )
    log("[favorites] forced mutual favorite state on both sides")

    local_snapshot, remote_snapshot, local_peer, remote_peer = wait_for_mutual_double_ratchet(
        local,
        remote,
        timeout_seconds=args.session_timeout,
    )
    log(
        "[double-ratchet] active on both sides "
        f"(laptop status={local_peer['doubleRatchetStatus']}, "
        f"mac-mini status={remote_peer['doubleRatchetStatus']})"
    )

    token_a = f"codex-auto-laptop-{int(time.time())}"
    token_b = f"codex-auto-mini-{int(time.time())}"

    send_response = local.request(
        "sendPrivateMessageViaNostr",
        target=remote_snapshot["myNoisePublicKeyHex"],
        text=token_a,
    )
    transport_used = require_ndr_transport(local, send_response)
    log(f"[message] laptop -> mac-mini token={token_a} transport={transport_used}")
    remote_snapshot, _, _ = wait_for_message(
        remote,
        counterpart_noise_key=local_snapshot["myNoisePublicKeyHex"],
        token=token_a,
        timeout_seconds=args.message_timeout,
    )
    time.sleep(args.reply_settle_seconds)

    send_response = remote.request(
        "sendPrivateMessageViaNostr",
        target=local_snapshot["myNoisePublicKeyHex"],
        text=token_b,
    )
    transport_used = require_ndr_transport(remote, send_response)
    log(f"[message] mac-mini -> laptop token={token_b} transport={transport_used}")
    local_snapshot, _, _ = wait_for_message(
        local,
        counterpart_noise_key=remote_snapshot["myNoisePublicKeyHex"],
        token=token_b,
        timeout_seconds=args.message_timeout,
    )

    result = {
        "status": "ok",
        "local": summarize_state(local.name, local_snapshot),
        "remote": summarize_state(remote.name, remote_snapshot),
        "messages": {
            "laptop_to_mac_mini": token_a,
            "mac_mini_to_laptop": token_b,
        },
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
