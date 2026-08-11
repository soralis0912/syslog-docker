#!/bin/sh
set -eu

# Runs retention.sh once at start, then daily via crond.
#
# The cron lives here, in a sidecar, rather than inside the rsyslog image:
# rsyslog's own rotation is handled by the date-templated filename, and adding
# a scheduler to a container with no init is how log pipelines break.

RETENTION_SCHEDULE="${RETENTION_SCHEDULE:-17 4 * * *}"

# Run immediately so a fresh deploy reports its disk figures without waiting a
# day; a failure here must not stop the scheduler from coming up.
/bin/sh /retention.sh || echo "retention: initial run failed, continuing"

mkdir -p /etc/crontabs
printf '%s /bin/sh /retention.sh >/proc/1/fd/1 2>&1\n' "${RETENTION_SCHEDULE}" > /etc/crontabs/root
echo "retention: scheduled '${RETENTION_SCHEDULE}'"

exec crond -f -l 8
