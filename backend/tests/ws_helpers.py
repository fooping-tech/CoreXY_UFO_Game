"""What the WebSocket tests share: start a GameServer on a free port, send a command
and wait for its answer, wait for a message of one type."""

from __future__ import annotations

import asyncio
import json

from corexy_ufo_backend.websocket.server import GameServer


async def start_server(robot, **kwargs):
    """A GameServer for `robot` on a free local port: (server, port)."""
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30, **kwargs)
    await srv.start()
    return srv, next(iter(srv._server.sockets)).getsockname()[1]


async def cmd(ws, name, params=None, rid="r", events=None, timeout=10.0):
    """Sends a command and returns its answer (the message with this request_id).
    `events`: a list that collects the devicehub_event messages seen on the way."""
    await ws.send(json.dumps({"type": "command", "request_id": rid, "data": {"name": name, "params": params or {}}}))
    while True:
        m = json.loads(await asyncio.wait_for(ws.recv(), timeout))
        if m.get("type") == "devicehub_event" and events is not None:
            events.append(m["data"])
        if m.get("request_id") == rid:
            return m


async def cmd_kw(ws, rid, name, **params):
    """As cmd(), with the request_id first and the parameters as keywords. The answer
    must be an ack or a nack (nothing else carries a command's request_id)."""
    m = await cmd(ws, name, params, rid=rid)
    assert m["type"] in ("ack", "nack"), m
    return m


async def recv_type(ws, t, timeout=3.0):
    """The next message of type `t`. Fails when none comes within `timeout` seconds:
    AssertionError while other messages keep coming, TimeoutError on a silent socket."""
    loop = asyncio.get_event_loop()
    end = loop.time() + timeout
    while loop.time() < end:
        m = json.loads(await asyncio.wait_for(ws.recv(), timeout))
        if m.get("type") == t:
            return m
    raise AssertionError(f"no {t}")
