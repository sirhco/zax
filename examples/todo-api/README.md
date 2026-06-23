# todo-api

A REST/CRUD JSON API on [zax](../..). Demonstrates mutable shared state
(`App(*Store)` guarded by a `std.Thread.Mutex`), the `Json` / `Path` / `State`
extractors, JSON responses with real status codes (201/204/404), and
observability (an access log + Prometheus `/metrics`).

## Run

```sh
zig build run        # http://127.0.0.1:8082
zig build test       # store + handler unit tests
```

## Try it

```sh
curl -s localhost:8082/todos
curl -s -XPOST localhost:8082/todos -d '{"title":"buy milk"}'   # 201
curl -s localhost:8082/todos/1
curl -s -XPUT localhost:8082/todos/1 -d '{"done":true}'
curl -s -XDELETE localhost:8082/todos/1 -i | head -1            # 204
curl -s localhost:8082/metrics
```

## How it works

The `Store` holds the data behind a mutex; each method copies its result into the
request arena under the lock, so handlers serialize JSON without holding the lock and
are immune to concurrent mutation. State reaches handlers via `zax.State(*Store)`.
