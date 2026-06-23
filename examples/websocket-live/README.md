# websocket-live

A WebSocket echo endpoint on [zax](../..) that runs on **both** server backends with
the same handler. `on_message` receives whole reassembled messages; the framework
auto-replies to pings and does the close handshake.

## Run
```sh
zig build run              # threaded backend
zig build run -- evented   # evented (reactor) backend
# ws://127.0.0.1:8085/ws
```

## Try it
```sh
# with websocat (or wscat):
websocat ws://127.0.0.1:8085/ws
> hello        # server echoes: hello

# check the running echo count (shared across all connections):
curl http://127.0.0.1:8085/stats
# messages echoed: 3
```

Or in a browser console:
```js
const ws = new WebSocket("ws://127.0.0.1:8085/ws");
ws.onmessage = (e) => console.log("echo:", e.data);
ws.onopen = () => ws.send("hello from the browser");
```

Then open `http://127.0.0.1:8085/stats` to see the total message count across all connections.

## How it works
The `WebSocket` extractor's `onUpgrade(.{ .on_message = onMessage })` performs the RFC
6455 handshake and hands each whole message to `onMessage`, which increments a lock-free
atomic counter (reached via `conn.state(*Counter)`) and echoes the message back. The same
handler runs under `app.serve` and `app.serveEvented`.

`GET /stats` uses the `State(*Counter)` extractor to read the same global counter and
returns the running echo count as plain text — demonstrating that app state is truly
shared across all connections.
