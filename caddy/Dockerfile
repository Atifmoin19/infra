# Caddy running as an unprivileged user. The upstream binary already carries
# cap_net_bind_service, so it can bind 80/443 without root.
FROM caddy:2.8-alpine
RUN addgroup -S -g 10000 caddy && adduser -S -D -H -u 10000 -G caddy caddy \
 && mkdir -p /data/caddy /config/caddy \
 && chown -R caddy:caddy /data /config
USER caddy
