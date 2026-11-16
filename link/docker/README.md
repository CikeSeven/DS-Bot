# DS Bot link Relay Server (v2) in Docker

The Relay Server for protocol v2 is the Rust binary `dsbot-link-relay` (`link/crates/relay`). It forwards encrypted frames between phones and computers and cannot read them. It listens on plain `ws://` at `/v2/link`; put it behind a TLS proxy and give phones and computers the `wss://` address.

## Build

From the `link/` directory:

```sh
docker build -f docker/Dockerfile -t dsbot-link-relay .
```

The image holds one static binary on `distroless/static`, runs as a non-root user (uid 65532) and keeps the device table in the `/data` volume.

`link/.dockerignore` keeps the build context to the Rust workspace.

## Run

```sh
docker network create dsbot-link
docker volume create dsbot-link-data
docker run -d --name dsbot-link-relay --restart unless-stopped \
  --network dsbot-link \
  -v dsbot-link-data:/data \
  -e DSBOT_LINK_TRUST_PROXY=1 \
  dsbot-link-relay
```

The relay prints its address (`ws://0.0.0.0:8787/v2/link`) as the first line on stdout and logs to stderr; `RUST_LOG` sets the log level (default `info`). `GET /healthz` answers `ok`. It stops cleanly on `SIGTERM` or `SIGINT` and saves the device table before it exits.

Without a proxy, for a local test only: add `-p 127.0.0.1:8787:8787` and leave out `DSBOT_LINK_TRUST_PROXY`.

## Settings

All optional. They are the v1 relay's variables, plus `DSBOT_LINK_GRACE_SECONDS`.

| Variable | Default | |
|---|---|---|
| `HOST`, `PORT` | `0.0.0.0`, `8787` | Where the relay listens. `PORT=0` picks a free port |
| `DSBOT_LINK_DATA` | `/data/devices.json` in the image, none (memory only) outside it | File for the known devices, the same JSON as v1 |
| `DSBOT_LINK_TRUST_PROXY` | off | `1`: take the client address from the last `X-Forwarded-For` entry. Set it only behind a proxy that writes this header |
| `DSBOT_LINK_MAX_SOCKETS` | `1024` | Open sockets in total |
| `DSBOT_LINK_MAX_LINKS` | `1024` | Phone-to-computer links in total |
| `DSBOT_LINK_MAX_SOCKETS_PER_ADDRESS` | `256` | Open sockets from one address |
| `DSBOT_LINK_MAX_NEW_DEVICES_PER_HOUR` | `20` | New devices one address may register in an hour |
| `DSBOT_LINK_MAX_MB_PER_HOUR` | `512` | MiB one address may send in an hour |
| `DSBOT_LINK_DEVICE_TTL_DAYS` | none | Forget devices not seen for this many days |
| `DSBOT_LINK_GRACE_SECONDS` | `120` | How long a link waits for a side whose socket dropped |

## TLS proxy

[`Caddyfile.example`](Caddyfile.example) and [`nginx.conf.example`](nginx.conf.example) serve one host name over TLS and route `/v1/link` to the v1 TS relay and `/v2/link` to this one, with WebSocket upgrades, long read timeouts and `X-Forwarded-For`. Run the proxy and both relays on the same Docker network, and do not publish the relays' ports: with `DSBOT_LINK_TRUST_PROXY=1`, a client that reaches a relay directly could forge its address.

Phones only trust certificates from public CAs, so a self-hosted relay needs a publicly trusted certificate (for example from Let's Encrypt, which Caddy gets by itself).

## Moving from v1

v1 and v2 do not talk to each other, and a phone and its computer must use the same version. Run both relays side by side behind the proxy until every phone and computer is updated, then stop the v1 relay and drop its route.

- Keys and pairings stay the same; nobody pairs again.
- The updated computer moves a `phone.json` that names the default relay's `/v1/link` to `/v2/link` by itself. A self-hosted relay address that ends in `/v1/link` must be changed by hand.
- The v2 relay keeps its own device table, and each device registers on its first v2 hello. Never point both relays at the same file: each one rewrites it.
- The table has the same format as v1's, so v1's `devices.json` can seed the v2 volume once, before the v2 relay first starts. This keeps the registrations, which matters when many devices share an address and would otherwise hit `DSBOT_LINK_MAX_NEW_DEVICES_PER_HOUR`. The updated phone and computer keep their v1 identity keys and access tokens, so the copied entries stay valid.

```sh
# v1's table in ./data/devices.json, the v2 relay not started yet
docker run --rm -v dsbot-link-data:/data -v "$PWD/data:/v1:ro" busybox sh -c \
  'cp /v1/devices.json /data/devices.json && chmod 600 /data/devices.json && chown -R 65532:65532 /data'
```
