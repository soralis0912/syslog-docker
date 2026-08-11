FROM alpine:3.22

# findutils for GNU find semantics, tzdata so the cron schedule follows TZ.
RUN apk add --no-cache zstd findutils tzdata

STOPSIGNAL SIGTERM

ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
