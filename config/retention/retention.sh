#!/bin/sh
set -eu

# Layer 2: compress yesterday-but-one, delete what is past the local window.
#
# The window matters more than the compression: local files are only a replay
# buffer for Alloy. Long-term retention is Loki's job (compactor), so there is
# no reason to keep months of text here.

LOG_DIR="${RETENTION_LOG_DIR:-/var/log/network}"
COMPRESS_AFTER_DAYS="${COMPRESS_AFTER_DAYS:-2}"
LOCAL_RETENTION_DAYS="${LOCAL_RETENTION_DAYS:-14}"
ZSTD_LEVEL="${ZSTD_LEVEL:-10}"

ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
say() { echo "$(ts) retention: $*"; }

# Compressing a file Alloy is still tailing loses the rest of it. Alloy only
# ever has the current and previous day open, so anything below 2 is unsafe.
if [ "${COMPRESS_AFTER_DAYS}" -lt 2 ]; then
  say "COMPRESS_AFTER_DAYS=${COMPRESS_AFTER_DAYS} is below the safe floor; forcing 2"
  COMPRESS_AFTER_DAYS=2
fi

if [ "${LOCAL_RETENTION_DAYS}" -le "${COMPRESS_AFTER_DAYS}" ]; then
  say "LOCAL_RETENTION_DAYS must exceed COMPRESS_AFTER_DAYS; nothing to do"
  exit 1
fi

say "start: compress >${COMPRESS_AFTER_DAYS}d, delete >${LOCAL_RETENTION_DAYS}d, dir=${LOG_DIR}"

# -mtime +N is "last modified more than N*24h ago". A daily file stops being
# written at midnight, so +2 puts at least two full days between Alloy and the
# compressor.
find "${LOG_DIR}" -type f -name '*.log' -mtime "+${COMPRESS_AFTER_DAYS}" | sort | while read -r f; do
  if zstd -q -"${ZSTD_LEVEL}" --rm -- "${f}"; then
    say "  compressed ${f}"
  else
    say "  FAILED to compress ${f}"
  fi
done

find "${LOG_DIR}" -type f -name '*.log.zst' -mtime "+${LOCAL_RETENTION_DAYS}" | sort | while read -r f; do
  rm -f -- "${f}" && say "  deleted ${f}"
done

# Volume figures, so the README's sizing numbers can be checked against
# reality instead of guessed at.
say "usage by device:"
du -sh "${LOG_DIR}"/* 2>/dev/null | sed 's/^/    /' || true
say "total: $(du -sh "${LOG_DIR}" 2>/dev/null | cut -f1)"
# busybox df prints whichever bind of the device it finds first, so name the
# directory ourselves rather than trusting its mountpoint column.
say "filesystem backing ${LOG_DIR}: $(df -h "${LOG_DIR}" | tail -1 | awk '{printf "%s used=%s avail=%s (%s)", $1, $3, $4, $5}')"
say "done"
