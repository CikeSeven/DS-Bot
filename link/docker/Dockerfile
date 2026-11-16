# The DS Bot link Relay Server, protocol v2. Build from the link/ directory:
#   docker build -f docker/Dockerfile -t dsbot-link-relay .

# Rust on Alpine targets musl and links statically, so the binary needs no libc at run time.
FROM rust:1-alpine AS build
RUN apk add --no-cache musl-dev
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
RUN cargo build --release --locked -p dsbot-link-relay --bin dsbot-link-relay \
    && install -D -m 0755 target/release/dsbot-link-relay /out/dsbot-link-relay \
    && mkdir -p /out/data

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/dsbot-link-relay /usr/local/bin/dsbot-link-relay
# A new named volume copies this directory, so the non-root user owns it.
COPY --from=build --chown=65532:65532 /out/data /data
ENV HOST=0.0.0.0 \
    PORT=8787 \
    DSBOT_LINK_DATA=/data/devices.json \
    RUST_LOG=info
VOLUME ["/data"]
EXPOSE 8787
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/dsbot-link-relay"]
