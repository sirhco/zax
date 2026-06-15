# HTTPS in production (TLS termination at a reverse proxy)

Zig 0.16.0's standard library ships a TLS **client** (`std.crypto.tls.Client`) but
**no server-side TLS**. Rather than vendor a from-scratch handshake or pull in a C
crypto library, Zax terminates TLS at a reverse proxy and serves plaintext
HTTP/1.1 on localhost. This is the standard, audited production pattern.

```
client ──HTTPS──▶  nginx / Caddy / Cloudflare  ──HTTP──▶  Zax (127.0.0.1:8080)
                   (terminates TLS,
                    sets X-Forwarded-*)
```

## 1. Bind Zax to localhost only

The proxy is the only thing that should reach Zax. Bind to `127.0.0.1` and enable
forwarded-header trust **only because** a proxy you control sits in front:

```zig
var app = try zax.App(*const Db).init(init.gpa, &db, .{ .trust_forwarded = true });
// ...
try app.serve(init.io, .{ .ip4 = .loopback(8080) });
```

> ⚠️ Set `trust_forwarded = true` only when Zax is actually behind a proxy you
> control. If Zax is directly reachable, a client can spoof `X-Forwarded-Proto:
> https` and the `Forwarded` extractor would believe it.

Read the proxied connection info in a handler:

```zig
fn whoami(f: zax.Forwarded) zax.Response {
    // f.scheme ("https"/"http"), f.host, f.client_ip (real client, not the proxy)
    return if (f.isHttps()) zax.Response.text("secure\n") else zax.Response.fromStatus(.forbidden);
}
```

## 2a. Caddy (automatic TLS)

Caddy obtains and renews Let's Encrypt certs automatically.

```caddy
api.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

Caddy sets `X-Forwarded-Proto`, `X-Forwarded-Host`, and `X-Forwarded-For` by
default — nothing else to configure.

## 2b. nginx

```nginx
server {
    listen 443 ssl;
    server_name api.example.com;

    ssl_certificate     /etc/letsencrypt/live/api.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header Connection        "";          # enable keep-alive upstream
        proxy_set_header X-Forwarded-Proto $scheme;     # http/https
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    }
}

# Redirect plain HTTP to HTTPS.
server {
    listen 80;
    server_name api.example.com;
    return 301 https://$host$request_uri;
}
```

`proxy_http_version 1.1` + `Connection ""` lets nginx reuse Zax's keep-alive
connections upstream.

## Notes

- Zax's `X-Forwarded-For` parsing takes the **first hop** as the originating
  client. Ensure your proxy appends (not overwrites) so spoofed values from
  beyond the proxy don't surface; nginx's `$proxy_add_x_forwarded_for` does this.
- In-process TLS (a `TlsStream` wrapping `Io.net.Stream`) is a candidate for a
  future Zax version if/when std ships a TLS server, or via an optional C-crypto
  build flag — out of scope today.
