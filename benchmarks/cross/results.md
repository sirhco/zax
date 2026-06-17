# Cross-framework results

Record runs here. Include the methodology so numbers are interpretable.

## Environment

- Date:
- Hardware (CPU, cores, RAM):
- OS:
- zig / rustc / go versions:
- Load generator + version:
- `DURATION` / `CONNS`:
- Client location: same host (loopback) | separate machine
- Core pinning: none | server/client isolated

## Results (median of N runs)

### static — `GET /`

| Framework | req/s | p50 | p99 |
|-----------|------:|----:|----:|
| zax       |       |     |     |
| axum      |       |     |     |
| go        |       |     |     |

### param — `GET /users/42`

| Framework | req/s | p50 | p99 |
|-----------|------:|----:|----:|
| zax       |       |     |     |
| axum      |       |     |     |
| go        |       |     |     |

### json — `POST /echo`

| Framework | req/s | p50 | p99 |
|-----------|------:|----:|----:|
| zax       |       |     |     |
| axum      |       |     |     |
| go        |       |     |     |

## Notes

- (anomalies, GC pauses, saturation, anything that affects interpretation)
