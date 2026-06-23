# file-upload

`multipart/form-data` upload + static file serving on [zax](../../README.md).

```
zig build run    # http://127.0.0.1:8084
zig build test   # sanitize unit test
```

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Usage hint |
| `POST` | `/upload` | Upload a file (field name: `file`) |
| `GET` | `/files/:name` | Retrieve an uploaded file |

## Try it

```sh
# Upload
curl -F 'file=@/path/to/photo.jpg' http://127.0.0.1:8084/upload

# Download
curl http://127.0.0.1:8084/files/photo.jpg -o photo.jpg
```

Uploaded files are written to `./uploads/` (relative to the working directory).
The filename is sanitised (path components stripped) before saving to prevent
directory traversal.

## How it works

`zax.Multipart` (a body extractor, last param) exposes `.file("file")`; the bytes are
written under `./uploads/` (filename sanitized to block path traversal). `zax.Files.dir`
serves saved files, bounded by the request body limits.
