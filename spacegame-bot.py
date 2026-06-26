#!/usr/bin/env python3
"""
spacegame-bot — a headless native spacegame client that plays over the real CE mesh.

It speaks the exact wire the browser frontend speaks (web/demos/spacegame/index.html): it talks only to
a local CE node's HTTP API (the libp2p mesh) via /mesh/subscribe, /mesh/publish and the
/mesh/messages/stream SSE push, with payloads carried as `payload_hex`. The authenticated player id is
the node's own NodeId (from /status) — exactly as in the game.

Used by the VM e2e to assert, against a live multi-node mesh, that the whole spacegame stack works:
join, mining, weapon select, combat/debris, the seamless cross-sector transit (infinite map), and the
live ruleset version (hot reload). It prints a single JSON summary line to stdout that the shell
harness parses; all logs go to stderr.

Stdlib only (urllib/json/threading) so it runs on a fresh VM with nothing installed but python3.

  spacegame-bot.py --node http://127.0.0.1:8844 --sector 0_0 --secs 20 --behavior fire
  spacegame-bot.py --sector 0_0 --watch-sector 1_0 --behavior east   # fly east, assert transit -> 1_0
"""
import argparse
import json
import os
import sys
import threading
import time
import urllib.request

HZ = 10  # input frames per second


def log(*a):
    print("[bot]", *a, file=sys.stderr, flush=True)


def find_token(node_url, explicit):
    if explicit:
        # Either a literal token or a path to api.token.
        if os.path.isfile(explicit):
            return open(explicit).read().strip()
        return explicit.strip()
    # Standard data-dir locations (Linux VM, then macOS).
    home = os.path.expanduser("~")
    for p in (
        os.path.join(home, ".local/share/ce/api.token"),
        os.path.join(home, "Library/Application Support/ce/api.token"),
        "/root/.local/share/ce/api.token",
    ):
        if os.path.isfile(p):
            return open(p).read().strip()
    return None


class Node:
    def __init__(self, base, token):
        self.base = base.rstrip("/")
        self.token = token

    def req(self, method, path, body=None):
        url = self.base + path
        data = body.encode() if isinstance(body, str) else body
        r = urllib.request.Request(url, data=data, method=method)
        if data is not None:
            r.add_header("Content-Type", "application/json")
        # Writes (non-GET) require the api.token bearer; GETs are open.
        if method != "GET" and self.token:
            r.add_header("Authorization", "Bearer " + self.token)
        with urllib.request.urlopen(r, timeout=15) as resp:
            return resp.read()

    def status(self):
        return json.loads(self.req("GET", "/status"))

    def subscribe(self, topic):
        self.req("POST", "/mesh/subscribe", json.dumps({"topic": topic}))

    def publish(self, topic, obj):
        payload_hex = json.dumps(obj).encode().hex()
        self.req("POST", "/mesh/publish", json.dumps({"topic": topic, "payload_hex": payload_hex}))


def sector_token(sx, sy):
    p = lambda v: ("n" + str(-v)) if v < 0 else str(v)
    return p(sx) + "_" + p(sy)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--node", default="http://127.0.0.1:8844")
    ap.add_argument("--sector", default="0_0")
    ap.add_argument("--watch-sector", default=None, help="extra sector to watch (transit assertion)")
    ap.add_argument("--name", default="bot")
    ap.add_argument("--secs", type=float, default=20.0)
    ap.add_argument("--behavior", choices=["idle", "east", "fire", "build", "weapon"], default="idle")
    ap.add_argument("--build-kind", default="tech-missile")
    ap.add_argument("--weapon-id", default="missile")
    ap.add_argument("--token", default=None)
    args = ap.parse_args()

    token = find_token(args.node, args.token)
    node = Node(args.node, token)

    try:
        st = node.status()
        my_id = str(st.get("node_id"))
    except Exception as e:
        print(json.dumps({"error": f"status failed: {e}"}))
        return 2
    log("my node id", my_id[:12], "behavior", args.behavior)

    GAME = "spacegame"
    in_topic = f"ce-game/{GAME}/{args.sector}/in"
    state_topic = f"ce-game/{GAME}/{args.sector}/state"
    watch_state = f"ce-game/{GAME}/{args.watch_sector}/state" if args.watch_sector else None

    for t in (in_topic, state_topic, watch_state):
        if t:
            try:
                node.subscribe(t)
            except Exception as e:
                log("subscribe failed", t, e)

    # Shared, latest-wins state captured from the SSE stream, plus cumulative event flags.
    latest = {"sector": None, "watch": None}
    seen = {"bullets": False, "beams": False, "debris": False, "explosions": False, "ruleset": 0, "peak_players": 0}
    stop = threading.Event()

    def inbox():
        backoff = 0.5
        while not stop.is_set():
            try:
                r = urllib.request.Request(node.base + "/mesh/messages/stream", method="GET")
                with urllib.request.urlopen(r, timeout=args.secs + 30) as resp:
                    buf = b""
                    while not stop.is_set():
                        chunk = resp.read(1)
                        if not chunk:
                            break
                        buf += chunk
                        if buf.endswith(b"\n\n"):
                            frame = buf.decode(errors="ignore")
                            buf = b""
                            data = "".join(
                                l[5:].lstrip() for l in frame.splitlines() if l.startswith("data:")
                            )
                            if not data:
                                continue
                            try:
                                msg = json.loads(data)
                            except Exception:
                                continue
                            topic = msg.get("topic")
                            ph = msg.get("payload_hex")
                            if not ph:
                                continue
                            try:
                                snap = json.loads(bytes.fromhex(ph).decode())
                            except Exception:
                                continue
                            if topic == state_topic:
                                latest["sector"] = snap
                                if snap.get("bullets"):
                                    seen["bullets"] = True
                                if snap.get("beams"):
                                    seen["beams"] = True
                                if snap.get("debris"):
                                    seen["debris"] = True
                                if snap.get("explosions"):
                                    seen["explosions"] = True
                                seen["ruleset"] = max(seen["ruleset"], int(snap.get("ruleset", 0)))
                                seen["peak_players"] = max(seen["peak_players"], len(snap.get("ships", [])))
                            elif watch_state and topic == watch_state:
                                latest["watch"] = snap
            except Exception as e:
                if stop.is_set():
                    return
                log("inbox reconnect", e)
                time.sleep(backoff)
                backoff = min(backoff * 2, 5)

    th = threading.Thread(target=inbox, daemon=True)
    th.start()

    # Join, then drive inputs.
    try:
        node.publish(in_topic, {"t": "join", "name": args.name})
    except Exception as e:
        log("join failed", e)

    did_oneshot = False
    transited = False
    t0 = time.time()
    while time.time() - t0 < args.secs:
        frame = {"t": "in", "thrust": False, "turn": 0, "fire": False}
        if args.behavior == "east":
            frame["thrust"] = True
            frame["aim"] = 0.0  # heading +x -> fly toward the eastern edge -> transit to (sx+1, sy)
        elif args.behavior == "fire":
            frame["fire"] = True
            frame["aim"] = 0.0
        elif args.behavior in ("build", "weapon") and not did_oneshot:
            node_topic = in_topic
            try:
                if args.behavior == "build":
                    node.publish(node_topic, {"t": "build", "kind": args.build_kind})
                else:
                    node.publish(node_topic, {"t": "build", "kind": args.build_kind})
                    node.publish(node_topic, {"t": "weapon", "id": args.weapon_id})
            except Exception as e:
                log("oneshot failed", e)
            did_oneshot = True
        try:
            node.publish(in_topic, frame)
        except Exception as e:
            log("input failed", e)
        # Transit assertion: did our id show up in the watched neighbour sector?
        w = latest["watch"]
        if w and any(s.get("id") == my_id for s in w.get("ships", [])):
            transited = True
        time.sleep(1.0 / HZ)

    stop.set()

    snap = latest["sector"] or {}
    ships = snap.get("ships", [])
    me = next((s for s in ships if s.get("id") == my_id), None)
    # Track factions (the always-alive economy + the NPC fleet under command).
    factions = snap.get("factions", [])
    my_faction = next((f for f in factions if f.get("owner") == my_id), None)
    npc_ships = [s for s in ships if s.get("role", "player") != "player"]
    my_fleet = [s for s in npc_ships if s.get("owner") == my_id]
    summary = {
        "node_id": my_id,
        "sector": args.sector,
        "present": me is not None,
        "minerals": (me or {}).get("minerals", 0),
        "kills": (me or {}).get("kills", 0),
        "weapon": (me or {}).get("weapon", ""),
        "weapons": (me or {}).get("weapons", []),
        "ruleset": max(int(snap.get("ruleset", 0)), seen["ruleset"]),
        "players_seen": sorted({s.get("id") for s in ships if s.get("role", "player") == "player"}),
        "peak_players": seen["peak_players"],
        "saw_bullets": seen["bullets"],
        "saw_beams": seen["beams"],
        "saw_debris": seen["debris"],
        "saw_explosions": seen["explosions"],
        "transited_to": args.watch_sector if transited else None,
        "tick": snap.get("tick", 0),
        # Faction tracking:
        "factions_tracked": len(factions),
        "my_faction": my_faction,  # {minerals,energy,alloys,buildings,drones,fighters,haulers,fleet_alive,power,command}
        "npc_ships_seen": len(npc_ships),
        "my_fleet_alive": len(my_fleet),
    }
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
