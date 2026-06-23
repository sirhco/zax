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
```

Or in a browser console:
```js
const ws = new WebSocket("ws://127.0.0.1:8085/ws");
ws.onmessage = (e) => console.log("echo:", e.data);
ws.onopen = () => ws.send("hello from the browser");
```

## How it works
The `WebSocket` extractor's `onUpgrade(.{ .on_message = onMessage })` performs the RFC
6455 handshake and hands each whole message to `onMessage`, which increments a lock-free
atomic counter (reached via `conn.state(*Counter)`) and echoes the message back. The same
handler runs under `app.serve` and `app.serveEvented`.
