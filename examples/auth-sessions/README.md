# auth-sessions

Cookie sessions + a guard middleware on [zax](../..). `POST /login` sets a `session`
cookie; a middleware reads the `Cookies` extractor and returns `401` for protected
routes without a valid session.

## Run
```sh
zig build run     # http://127.0.0.1:8083
zig build test
```

## Try it
```sh
curl -s localhost:8083/                              # public
curl -s localhost:8083/me -i | head -1               # 401 (no cookie)
curl -s -c jar -XPOST localhost:8083/login -d '{"user":"ada","pass":"secret"}'
curl -s -b jar localhost:8083/me                     # "you are: ada"
curl -s -b jar -XPOST localhost:8083/logout
```

## How it works
`requireAuth` is a `Chain` middleware applied to `/me` via `getWith`. It reads the
`session` cookie, looks it up in the atomic-spinlock-guarded `Sessions` store, and
short-circuits `401` on miss. Login issues a token and sets it with
`Response.withCookie` (HttpOnly, SameSite=Lax). (Demo auth only — `pass == "secret"`,
non-CSPRNG tokens.)
