FROM alpine:3.22

# tzdata so the daily filename and recv_time follow TZ rather than UTC.
RUN apk add --no-cache rsyslog tzdata \
 && rm -f /etc/rsyslog.conf

STOPSIGNAL SIGTERM

ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
