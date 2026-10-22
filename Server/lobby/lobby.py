#!/usr/bin/env python3
"""Self-hosted multiplayer lobby compatible with Azahar / Citra web services.

Implements the subset of the (former) Citra web API that the emulator uses for public rooms:

  POST   /jwt/internal              x-username + x-token  -> JWT (text/html)
  POST   /jwt/external/<verifyUID>  Bearer JWT            -> room-scoped JWT (text/html)
  GET    /jwt/external/key.pem                            -> RS256 public key (text/plain)
  GET    /lobby                     anonymous             -> {"rooms": [...]}
  POST   /lobby                     Bearer JWT            -> register room, returns room + id
  POST   /lobby/<id>                Bearer JWT            -> update player list (heartbeat)
  DELETE /lobby/<id>                Bearer JWT            -> remove room

Works with: the 3DS_iOS app, Azahar desktop/Android (Settings → Web API URL), and the
dedicated `azahar-room --web-api-url http://host:port --token ...` server.

NOTE: Azahar's HTTP client speaks plain HTTP only (it builds an httplib::Client from host and
port), so serve this on http://, not https://.

Environment variables
  LOBBY_HOST            bind address                      (default 0.0.0.0)
  LOBBY_PORT            port                              (default 5000)
  LOBBY_DATA_DIR        where the RSA key is kept         (default ./data)
  LOBBY_USERS_FILE      optional "username:token" lines; when set only those accounts may
                        host public rooms. When unset the lobby is open: any non-empty token works.
  LOBBY_ROOM_TTL        seconds without heartbeat before a room disappears (default 60)
  LOBBY_TRUST_PROXY     "1" to take the client address from X-Forwarded-For
  LOBBY_PUBLIC_ADDRESS  address to advertise for rooms that register from a private/loopback
                        address (e.g. a dedicated room running next to the lobby in Docker)

Licensed under GPLv2 or any later version.
"""

from __future__ import annotations

import ipaddress
import json
import logging
import os
import re
import threading
import time
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

LOG = logging.getLogger("lobby")
ISSUER = "citra-core"
INTERNAL_AUDIENCE = "citra-services"
JWT_LIFETIME = 3600
NAME_RE = re.compile(r"^[A-Za-z0-9._\- ]{1,40}$")


class Config:
    def __init__(self) -> None:
        self.host = os.environ.get("LOBBY_HOST", "0.0.0.0")
        self.port = int(os.environ.get("LOBBY_PORT", "5000"))
        self.data_dir = Path(os.environ.get("LOBBY_DATA_DIR", "./data"))
        self.users_file = os.environ.get("LOBBY_USERS_FILE", "")
        self.room_ttl = int(os.environ.get("LOBBY_ROOM_TTL", "60"))
        self.trust_proxy = os.environ.get("LOBBY_TRUST_PROXY", "") == "1"
        self.public_address = os.environ.get("LOBBY_PUBLIC_ADDRESS", "")


class Keys:
    """RS256 key pair, persisted so tokens survive restarts."""

    def __init__(self, data_dir: Path) -> None:
        data_dir.mkdir(parents=True, exist_ok=True)
        key_path = data_dir / "jwt-key.pem"
        if key_path.exists():
            self.private_key = serialization.load_pem_private_key(key_path.read_bytes(), None)
        else:
            self.private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            key_path.write_bytes(
                self.private_key.private_bytes(
                    serialization.Encoding.PEM,
                    serialization.PrivateFormat.PKCS8,
                    serialization.NoEncryption(),
                )
            )
            os.chmod(key_path, 0o600)
        self.public_pem = (
            self.private_key.public_key()
            .public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
            .decode()
        )

    def issue(self, username: str, audience: str) -> str:
        now = int(time.time())
        claims = {
            "iss": ISSUER,
            "aud": audience,
            "sub": username,
            "username": username,
            "displayName": username,
            "avatarUrl": "",
            "iat": now,
            "exp": now + JWT_LIFETIME,
            "jti": uuid.uuid4().hex,
        }
        return jwt.encode(claims, self.private_key, algorithm="RS256")

    def verify_internal(self, token: str) -> str | None:
        try:
            claims = jwt.decode(
                token,
                self.private_key.public_key(),
                algorithms=["RS256"],
                audience=INTERNAL_AUDIENCE,
                issuer=ISSUER,
            )
        except jwt.PyJWTError as exc:
            LOG.info("rejected JWT: %s", exc)
            return None
        return claims.get("username")


class Accounts:
    def __init__(self, users_file: str) -> None:
        self.closed = bool(users_file)
        self.users: dict[str, str] = {}
        if users_file:
            for line in Path(users_file).read_text().splitlines():
                line = line.strip()
                if not line or line.startswith("#") or ":" not in line:
                    continue
                name, token = line.split(":", 1)
                self.users[name.strip()] = token.strip()

    def check(self, username: str, token: str) -> bool:
        if not username or not token or not NAME_RE.match(username):
            return False
        if not self.closed:
            return True
        return self.users.get(username) == token


class Rooms:
    def __init__(self, ttl: int) -> None:
        self.ttl = ttl
        self.lock = threading.Lock()
        self.rooms: dict[str, dict] = {}

    def _expire(self) -> None:
        now = time.time()
        for rid in [r for r, room in self.rooms.items() if now - room["_seen"] > self.ttl]:
            LOG.info("room %s expired", rid)
            del self.rooms[rid]

    def list(self) -> list[dict]:
        with self.lock:
            self._expire()
            return [{k: v for k, v in room.items() if not k.startswith("_")} for room in self.rooms.values()]

    def register(self, owner: str, address: str, body: dict) -> dict:
        room = {
            "id": uuid.uuid4().hex,
            "externalGuid": str(uuid.uuid4()),
            "address": address,
            "owner": owner,
            "port": int(body.get("port", 24872)),
            "name": str(body.get("name", ""))[:64],
            "description": str(body.get("description", ""))[:512],
            "preferredGameName": str(body.get("preferredGameName", ""))[:128],
            "preferredGameId": int(body.get("preferredGameId", 0)),
            "maxPlayers": int(body.get("maxPlayers", 16)),
            "netVersion": int(body.get("netVersion", 0)),
            "hasPassword": bool(body.get("hasPassword", False)),
            "players": _clean_players(body.get("players", [])),
            "_seen": time.time(),
        }
        with self.lock:
            self._expire()
            # One room per owner+address+port: re-registering replaces the old entry.
            for rid in [
                r for r, x in self.rooms.items()
                if x["owner"] == owner and x["address"] == address and x["port"] == room["port"]
            ]:
                del self.rooms[rid]
            self.rooms[room["id"]] = room
        return {k: v for k, v in room.items() if not k.startswith("_")}

    def update(self, rid: str, owner: str, players: list) -> bool:
        with self.lock:
            room = self.rooms.get(rid)
            if room is None or room["owner"] != owner:
                return False
            room["players"] = _clean_players(players)
            room["_seen"] = time.time()
            return True

    def delete(self, rid: str, owner: str) -> bool:
        with self.lock:
            room = self.rooms.get(rid)
            if room is None or room["owner"] != owner:
                return False
            del self.rooms[rid]
            return True


def _clean_players(players) -> list[dict]:
    out = []
    if not isinstance(players, list):
        return out
    for p in players[:64]:
        if not isinstance(p, dict):
            continue
        entry = {
            "nickname": str(p.get("nickname", ""))[:32],
            "gameName": str(p.get("gameName", ""))[:128],
            "gameId": int(p.get("gameId", 0)),
        }
        if p.get("username"):
            entry["username"] = str(p["username"])[:64]
            entry["avatarUrl"] = str(p.get("avatarUrl", ""))[:256]
        out.append(entry)
    return out


def _is_private(addr: str) -> bool:
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False
    return ip.is_private or ip.is_loopback or ip.is_link_local


class Handler(BaseHTTPRequestHandler):
    server_version = "AzaharLobby/1.0"
    cfg: Config
    keys: Keys
    accounts: Accounts
    rooms: Rooms

    # ----- helpers ---------------------------------------------------------------------------
    def log_message(self, fmt, *args):  # noqa: N802 - stdlib name
        LOG.info("%s %s", self.client_ip(), fmt % args)

    def client_ip(self) -> str:
        if self.cfg.trust_proxy:
            fwd = self.headers.get("X-Forwarded-For", "")
            if fwd:
                return fwd.split(",")[0].strip()
        addr = self.client_address[0]
        if addr.startswith("::ffff:"):
            addr = addr[7:]
        return addr

    def send(self, status: int, body: bytes | str, content_type: str) -> None:
        if isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, status: int, obj) -> None:
        self.send(status, json.dumps(obj), "application/json; charset=utf-8")

    def body_json(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length > 256 * 1024:
            return None
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return {}
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return None

    def bearer_user(self) -> str | None:
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return None
        return self.keys.verify_internal(auth[7:].strip())

    # ----- routes ----------------------------------------------------------------------------
    def do_GET(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/lobby":
            return self.send_json(200, {"rooms": self.rooms.list()})
        if path == "/jwt/external/key.pem":
            return self.send(200, self.keys.public_pem, "text/plain; charset=utf-8")
        if path in ("/", "/health"):
            rooms = self.rooms.list()
            return self.send_json(200, {"status": "ok", "rooms": len(rooms),
                                        "players": sum(len(r["players"]) for r in rooms),
                                        "mode": "closed" if self.accounts.closed else "open"})
        return self.send_json(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/jwt/internal":
            username = self.headers.get("x-username", "")
            token = self.headers.get("x-token", "")
            if not self.accounts.check(username, token):
                return self.send(401, "invalid credentials", "text/html; charset=utf-8")
            return self.send(200, self.keys.issue(username, INTERNAL_AUDIENCE), "text/html; charset=utf-8")

        user = self.bearer_user()
        if path.startswith("/jwt/external/"):
            if not user:
                return self.send(401, "unauthorized", "text/html; charset=utf-8")
            verify_uid = path[len("/jwt/external/"):]
            if not verify_uid or "/" in verify_uid:
                return self.send(400, "bad request", "text/html; charset=utf-8")
            return self.send(200, self.keys.issue(user, f"external-{verify_uid}"), "text/html; charset=utf-8")

        if path == "/lobby":
            if not user:
                return self.send_json(401, {"error": "unauthorized"})
            body = self.body_json()
            if not isinstance(body, dict) or not body.get("name"):
                return self.send_json(400, {"error": "bad room"})
            address = self.client_ip()
            if self.cfg.public_address and _is_private(address):
                address = self.cfg.public_address
            room = self.rooms.register(user, address, body)
            LOG.info("room '%s' registered by %s at %s:%s", room["name"], user, address, room["port"])
            return self.send_json(200, room)

        m = re.fullmatch(r"/lobby/([0-9a-f]{32})", path)
        if m:
            if not user:
                return self.send_json(401, {"error": "unauthorized"})
            body = self.body_json()
            if not isinstance(body, dict):
                return self.send_json(400, {"error": "bad body"})
            if not self.rooms.update(m.group(1), user, body.get("players", [])):
                return self.send_json(404, {"error": "no such room"})
            return self.send_json(200, {})
        return self.send_json(404, {"error": "not found"})

    def do_DELETE(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        m = re.fullmatch(r"/lobby/([0-9a-f]{32})", path)
        if not m:
            return self.send_json(404, {"error": "not found"})
        user = self.bearer_user()
        if not user:
            return self.send_json(401, {"error": "unauthorized"})
        if not self.rooms.delete(m.group(1), user):
            return self.send_json(404, {"error": "no such room"})
        return self.send_json(200, {})


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    cfg = Config()
    Handler.cfg = cfg
    Handler.keys = Keys(cfg.data_dir)
    Handler.accounts = Accounts(cfg.users_file)
    Handler.rooms = Rooms(cfg.room_ttl)
    server = ThreadingHTTPServer((cfg.host, cfg.port), Handler)
    LOG.info("Azahar-compatible lobby on http://%s:%d (%s mode)", cfg.host, cfg.port,
             "closed" if Handler.accounts.closed else "open")
    server.serve_forever()


if __name__ == "__main__":
    main()
