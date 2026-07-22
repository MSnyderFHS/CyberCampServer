#!/usr/bin/env bash
set -Eeuo pipefail

# PantherNet v1.337 installer for Ubuntu Server 24.04+
#
# Optional environment variables:
#   BIND_ADDRESS=0.0.0.0        Address on which the service listens
#   ALLOWED_CIDR=192.168.1.0/24 Source network allowed through UFW
#   OPEN_FIREWALL=1             Set to 0 to leave UFW unchanged
#
# Examples:
#   sudo ./install_panthernet.sh
#   sudo ALLOWED_CIDR=10.30.0.0/16 ./install_panthernet.sh
#   sudo OPEN_FIREWALL=0 ./install_panthernet.sh

SERVICE_NAME="panthernet"
SERVICE_USER="panthernet"
SERVICE_GROUP="panthernet"
INSTALL_DIR="/opt/panthernet"
CONFIG_DIR="/etc/panthernet"
SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
PORT="1337"
BIND_ADDRESS="${BIND_ADDRESS:-0.0.0.0}"
ALLOWED_CIDR="${ALLOWED_CIDR:-any}"
OPEN_FIREWALL="${OPEN_FIREWALL:-1}"

log() {
    printf '[PantherNet] %s\n' "$*"
}

fail() {
    printf '[PantherNet] ERROR: %s\n' "$*" >&2
    exit 1
}

if [[ ${EUID} -ne 0 ]]; then
    fail "Run this installer as root: sudo $0"
fi

if [[ "${OPEN_FIREWALL}" != "0" && "${OPEN_FIREWALL}" != "1" ]]; then
    fail "OPEN_FIREWALL must be 0 or 1."
fi

if ! command -v python3 >/dev/null 2>&1; then
    log "Installing Python 3..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3
fi

if ! command -v systemctl >/dev/null 2>&1; then
    fail "systemd is required."
fi

log "Creating the restricted service account..."
if ! getent group "${SERVICE_GROUP}" >/dev/null; then
    groupadd --system "${SERVICE_GROUP}"
fi
if ! id "${SERVICE_USER}" >/dev/null 2>&1; then
    useradd \
        --system \
        --gid "${SERVICE_GROUP}" \
        --home-dir "${INSTALL_DIR}" \
        --shell /usr/sbin/nologin \
        "${SERVICE_USER}"
fi

install -d -o root -g "${SERVICE_GROUP}" -m 0750 "${INSTALL_DIR}"
install -d -o root -g "${SERVICE_GROUP}" -m 0750 "${CONFIG_DIR}"

log "Installing the PantherNet server..."
cat > "${INSTALL_DIR}/server.py" <<'PYTHON'
#!/usr/bin/env python3
"""Harmless interactive PantherNet challenge service for Cybersecurity Camp."""

from __future__ import annotations

import logging
import os
import random
import secrets
import socket
import socketserver
import string
import threading
from pathlib import Path

HOST = os.environ.get("PANTHERNET_BIND", "0.0.0.0")
PORT = int(os.environ.get("PANTHERNET_PORT", "1337"))
IDLE_TIMEOUT_SECONDS = 180
MAX_LINE_BYTES = 256
MAX_SIMULTANEOUS_CLIENTS = 32
CONFIG_DIR = Path("/etc/panthernet")

BANNER = r"""
+------------------------------------------------------+
|                 PANTHERNET v1.337                    |
|            Unauthorized Husky detected.              |
+------------------------------------------------------+
This is a restricted Panther operations terminal.
Type HELP to view the available commands.
""".lstrip("\n")

HELP_TEXT = """Available commands:
  HELP      Show this command list
  WHOAMI    Identify the current intruder
  STATUS    Display Panther operations status
  CLUE      Request a clue from PantherNet
  JOKE      Receive a questionable cybersecurity joke
  MOTD      Display the message of the day
  ABOUT     Explain this service
  CLEAR     Redraw the PantherNet banner
  QUIT      Close the connection
"""

JOKES = (
    "Why did the password cross the network? It was trying to become stronger.",
    "There are 10 kinds of campers: those who understand binary and those who do not.",
    "A Panther, a Husky, and a firewall walk into a lab. The firewall blocks the punchline.",
    "Never trust a computer that says it has no secrets. Try the strings command.",
)

FALLBACK_CLUE = "You can't see a Panther hiding in the dark."
FALLBACK_MOTD = "Friendly rivalry is permitted. Unauthorized damage is not."

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
LOGGER = logging.getLogger("panthernet")
CLIENT_SLOTS = threading.BoundedSemaphore(MAX_SIMULTANEOUS_CLIENTS)


def read_text_file(name: str, fallback: str) -> str:
    """Read teacher-editable challenge text without interpreting it as code."""
    path = CONFIG_DIR / name
    try:
        text = path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError):
        return fallback
    return text[:2000] if text else fallback


def safe_peer(value: object) -> str:
    if isinstance(value, tuple) and value:
        return str(value[0])
    return "unknown"


class PantherNetHandler(socketserver.StreamRequestHandler):
    prompt = b"panthernet> "

    def send(self, text: str = "") -> None:
        data = (text + "\r\n").encode("utf-8", errors="replace")
        self.wfile.write(data)
        self.wfile.flush()

    def handle(self) -> None:
        if not CLIENT_SLOTS.acquire(blocking=False):
            self.send("PantherNet is busy. Try again shortly.")
            return

        peer = safe_peer(self.client_address)
        session_id = secrets.token_hex(3).upper()
        try:
            self.connection.settimeout(IDLE_TIMEOUT_SECONDS)
            LOGGER.info("connection opened peer=%s session=%s", peer, session_id)
            self.send(BANNER.rstrip("\n"))
            self.send(f"Session: {session_id}")

            while True:
                try:
                    self.wfile.write(self.prompt)
                    self.wfile.flush()
                    raw = self.rfile.readline(MAX_LINE_BYTES + 1)
                except (socket.timeout, TimeoutError):
                    self.send("Session timed out. The Panther has covered its tracks.")
                    break
                except (BrokenPipeError, ConnectionResetError, OSError):
                    break

                if not raw:
                    break
                if len(raw) > MAX_LINE_BYTES and not raw.endswith(b"\n"):
                    self.send("Command too long.")
                    self._discard_until_newline()
                    continue

                command = raw.decode("utf-8", errors="replace").strip()
                normalized = " ".join(command.upper().split())
                LOGGER.info(
                    "command peer=%s session=%s command=%r",
                    peer,
                    session_id,
                    normalized[:80],
                )

                if not normalized:
                    continue
                if normalized in {"QUIT", "EXIT", "LOGOUT"}:
                    self.send("Connection closed. Stay alert, Husky.")
                    break
                if normalized in {"HELP", "?"}:
                    self.send(HELP_TEXT.rstrip())
                elif normalized == "WHOAMI":
                    self.send(
                        "You are clearly not the Potomac Panther. "
                        "Your typing is far too dogged."
                    )
                elif normalized == "STATUS":
                    self.send("Klondike containment: TEMPORARY")
                    self.send("Panther confidence: SUSPICIOUSLY HIGH")
                    self.send("Husky investigation: IN PROGRESS")
                elif normalized == "CLUE":
                    self.send(read_text_file("clue.txt", FALLBACK_CLUE))
                elif normalized == "JOKE":
                    self.send(random.choice(JOKES))
                elif normalized == "MOTD":
                    self.send(read_text_file("motd.txt", FALLBACK_MOTD))
                elif normalized == "ABOUT":
                    self.send(
                        "PantherNet is a fictional Cybersecurity Camp service. "
                        "It provides no shell, account, or operating-system access."
                    )
                elif normalized == "CLEAR":
                    self.send(BANNER.rstrip("\n"))
                elif normalized in {"SUDO", "SU", "SHELL", "BASH", "SH"} or normalized.startswith("SUDO "):
                    self.send("Nice try. PantherNet is a decoy terminal, not a shell.")
                elif normalized in {"LS", "DIR"}:
                    self.send("README_PANTHER.txt  klondike_status.log  definitely_not_a_clue.txt")
                elif normalized.startswith("CAT ") or normalized.startswith("TYPE "):
                    self.send("Access denied. Try a command listed under HELP.")
                elif normalized == "1337":
                    self.send("LEET status confirmed. PantherNet approves.")
                elif normalized == "HUSKY":
                    self.send("Alert: persistent canine detected.")
                elif normalized == "PANTHER":
                    self.send("The Panther was here. Allegedly.")
                else:
                    self.send(f"Unknown command: {self.clean_for_display(command)}")
                    self.send("Type HELP for valid PantherNet commands.")
        finally:
            LOGGER.info("connection closed peer=%s session=%s", peer, session_id)
            CLIENT_SLOTS.release()

    def _discard_until_newline(self) -> None:
        while True:
            chunk = self.rfile.readline(1024)
            if not chunk or chunk.endswith(b"\n"):
                return

    @staticmethod
    def clean_for_display(value: str) -> str:
        allowed = set(string.ascii_letters + string.digits + " _-./")
        cleaned = "".join(ch for ch in value if ch in allowed)
        return cleaned[:80] or "[unprintable input]"


class PantherNetServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 32


def main() -> None:
    with PantherNetServer((HOST, PORT), PantherNetHandler) as server:
        LOGGER.info("PantherNet listening on %s:%d", HOST, PORT)
        server.serve_forever(poll_interval=0.5)


if __name__ == "__main__":
    main()
PYTHON

cat > "${CONFIG_DIR}/clue.txt" <<'EOF'
You can't see a Panther hiding in the dark.
EOF

cat > "${CONFIG_DIR}/motd.txt" <<'EOF'
Friendly rivalry is permitted. Unauthorized damage is not.
EOF

chown root:"${SERVICE_GROUP}" "${INSTALL_DIR}/server.py" "${CONFIG_DIR}/clue.txt" "${CONFIG_DIR}/motd.txt"
chmod 0750 "${INSTALL_DIR}/server.py"
chmod 0640 "${CONFIG_DIR}/clue.txt" "${CONFIG_DIR}/motd.txt"

log "Checking the Python service for syntax errors..."
python3 -m py_compile "${INSTALL_DIR}/server.py"
rm -rf "${INSTALL_DIR}/__pycache__"

log "Installing the systemd service..."
cat > "${SYSTEMD_UNIT}" <<EOF
[Unit]
Description=PantherNet Cybersecurity Camp Challenge
Documentation=man:systemd.service(5)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${INSTALL_DIR}
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=PANTHERNET_BIND=${BIND_ADDRESS}
Environment=PANTHERNET_PORT=${PORT}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/server.py
Restart=on-failure
RestartSec=2s
TimeoutStopSec=5s

# Service hardening: the challenge can listen on TCP but cannot become a shell.
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictAddressFamilies=AF_INET AF_INET6
CapabilityBoundingSet=
AmbientCapabilities=
UMask=0077
LimitNOFILE=256

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.service"

if [[ "${OPEN_FIREWALL}" == "1" ]] && command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q '^Status: active'; then
        log "UFW is active; adding the TCP ${PORT} rule..."
        if [[ "${ALLOWED_CIDR}" == "any" ]]; then
            ufw allow "${PORT}/tcp" comment 'PantherNet cyber camp challenge'
        else
            ufw allow from "${ALLOWED_CIDR}" to any port "${PORT}" proto tcp comment 'PantherNet cyber camp challenge'
        fi
    else
        log "UFW is installed but inactive; no firewall rule was needed."
    fi
elif [[ "${OPEN_FIREWALL}" == "0" ]]; then
    log "Firewall changes disabled by OPEN_FIREWALL=0."
else
    log "UFW is not installed; no firewall rule was added."
fi

sleep 1
if ! systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
    journalctl -u "${SERVICE_NAME}.service" -n 30 --no-pager || true
    fail "The service did not start. Review the status and journal output above."
fi

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
SERVER_IP="${SERVER_IP:-SERVER_IP}"

cat <<EOF

PantherNet v1.337 is installed and running.

Camper connection command:
  nc ${SERVER_IP} ${PORT}

Teacher commands:
  sudo systemctl status ${SERVICE_NAME}
  sudo journalctl -u ${SERVICE_NAME} -f
  sudo systemctl restart ${SERVICE_NAME}

Edit the clue without changing the program:
  sudo nano ${CONFIG_DIR}/clue.txt

The server reads clue.txt each time CLUE is entered, so no restart is required.
EOF
