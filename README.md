# syslog-docker

Syslog sink for network devices. Receives UDP/514, writes one file per device
per day, ships to Loki, and prunes itself.

Built for an appliance that keeps **memory logs only** - the kind where a
reboot erases the event history, so a fault that ends in a power cycle takes
its own evidence with it. The whole point is that the log survives the device.

```
device --UDP/514--> [ rsyslog ] --files--> [ Alloy ] --push--> [ Loki ] --> Grafana
                         |                                       ^
                         +--> data/logs/<device>/<YYYY-MM-DD>.log |
                                    |                             |
                               [ retention ] zstd + delete        |
                               (14d local)          long tail (90d)
```

Addresses in this README use the RFC 5737 documentation range
(`192.0.2.0/24`). Real ones live in `.env`, which is not tracked.

## Why `network_mode: host`

Not a preference - a correctness requirement, and it is verifiable:

| | source address recorded | device resolved |
|---|---|---|
| `ports: -p 514:514/udp` | `172.17.0.1` (bridge gateway) | `_unknown` |
| `network_mode: host` | `192.0.2.1` (the real sender) | `edge-firewall` |

docker-proxy/NAT rewrites the sender, so per-device routing and any source ACL
stop working. Re-check after touching the network config:

```
sudo grep -h . data/logs/*/*.log | tail -1 | python3 -m json.tool
```

`src_ip` must be the device's real address. If it starts with `172.`, the
network mode regressed.

## Host firewall

If the host runs `ufw` (or any default-deny INPUT policy), packets will reach
`tcpdump` and never reach rsyslog - which looks exactly like the device not
sending. Scope the rule to the sender:

```
sudo ufw allow from <DEVICE_IP> to any port 514 proto udp comment 'syslog from edge firewall'
```

## Rotation, in four layers

**Layer 1 - naming, not scheduling.** rsyslog writes
`/var/log/network/<device>/%$year%-%$month%-%$day%.log`. The date comes from
the *receiver's* clock, so a new file appears at midnight with no logrotate, no
`HUP`, and no cron inside a container that has no init. `dynaFileCacheSize=20`
and `closeTimeout=5` release yesterday's handle.

Verified with `libfaketime`: one rsyslog process (never restarted) wrote to
`2026-08-11.log` through `23:59:58` and to `2026-08-12.log` from `00:00:00`.

**Layer 2 - compress then delete (sidecar).** `config/retention/retention.sh`
runs daily under `crond`. It compresses `*.log` older than
`COMPRESS_AFTER_DAYS` with zstd and deletes `*.log.zst` older than
`LOCAL_RETENTION_DAYS`.

The interaction that bites: **compressing a file Alloy is still tailing loses
the rest of it.** Alloy only ever holds the current and previous day open, so
the floor is 2 days and the script clamps anything lower:

```
retention: COMPRESS_AFTER_DAYS=0 is below the safe floor; forcing 2
```

Alloy also excludes `*.zst` explicitly.

**Layer 3 - bounded queue.** The ruleset queue may spill to disk when the
writer stalls, but `queue.maxDiskSpace="512m"` caps it. An unbounded
disk-assisted queue is how a syslog box fills its own filesystem.

**Layer 4 - Loki retention.** The compactor enforces
`LOKI_RETENTION_PERIOD` (90d). Local text is a replay buffer, not the archive.

**Layer 5 - the container's own logs.** Every service here sets
`json-file` with `max-size: 10m` / `max-file: 3`.

## Measured volume

From a running deployment - a firewall sending event logs only, traffic logs
filtered out at the source:

| | measured |
|---|---|
| record size on disk | **739 bytes** (JSON envelope + device JSON payload) |
| zstd -3 / -10 / -19 | **19.4x / 23.7x / 25.6x** on real log data |
| steady-state rate | **0-1 records/min**; most minutes produce nothing at all |
| device-side drop counter | `count:0, failed:0, dropped:0` |

`ZSTD_LEVEL=10` is the default because -19 buys 8% for several times the CPU.

Sizing at 739 B/record and 23.7x, with 2 days uncompressed + the rest
compressed:

| sustained rate | raw/day | 14 days local | 90 days in Loki (est. 10x) |
|---|---|---|---|
| 1/min (observed) | 1.1 MB | ~2.7 MB | ~10 MB |
| 10/min | 10.6 MB | ~27 MB | ~96 MB |
| 60/min | 64 MB | ~160 MB | ~570 MB |
| traffic logs on, 8 sessions/s | **511 MB** | **~1.3 GB** | **~4.6 GB** |

Even the last row is small against a terabyte-class volume, which is the point:
**disk is usually not the binding constraint - signal is.** 14 days local / 90
days in Loki is chosen so a slow-burn fault that takes weeks to trip is still
fully visible when it finally does.

Ground truth beats the table above: the retention job prints real usage daily.

```
docker logs syslog-retention | tail -20
```

## Filtering at the source, and when to stop

Traffic logging is disabled on the sender. On a firewall averaging a few
sessions per second, forwarding traffic logs produces something like 700k
records/day against the event logs' 0-1/min - three orders of magnitude more
data, none of which helps with "why did it reboot".

Turn traffic logging on only when the question needs it - "which host talked to
what, when" during an incident - and turn it off again afterwards. Before you
do:

1. Check a week of real numbers first (`docker logs syslog-retention`).
2. Shorten `LOKI_RETENTION_PERIOD`, don't lengthen it, if you keep it on.
3. Look for a rate ceiling on the sender itself. FortiOS, for example, has
   `set max-log-rate <MBps>` in `config log syslogd setting` (0 = unlimited).

## Disk pressure

In order of effect:

1. `docker logs syslog-retention` - find which device is producing.
2. Lower `LOCAL_RETENTION_DAYS` (14 -> 7) and `docker compose restart retention`.
   Loki still holds the history; this only shortens the replay buffer.
3. Lower `LOKI_RETENTION_PERIOD` and restart Loki. The compactor reclaims within
   `compaction_interval` + `retention_delete_delay`.
4. Turn a log category off at the device. Filtering at the source beats every
   downstream knob.
5. Emergency only: `docker compose exec retention sh /retention.sh` after
   lowering the values - it runs immediately instead of waiting for cron.

## Timestamps

Devices lie about time. A sender left on a foreign timezone will place its
events hours away from everything else in the dashboard, and syslog gives you
no way to tell that apart from a genuine clock skew.

So everything here indexes on **receive time**: rsyslog stamps `recv_time` in
RFC3339 and Alloy uses that for the Loki timestamp. The device's own fields are
preserved untouched inside `message`, so you can still see what it thought the
time was.

A record received at 13:37 JST from a device running on UTC-7:

```json
{"recv_time":"2026-08-11T13:37:13.487594+09:00","device":"edge-firewall",
 "src_ip":"192.0.2.1","severity":"info","facility":"local7",
 "message":"{\"date\":\"2026-08-10\",\"time\":\"21:37:13\",\"tz\":\"-0700\",...}"}
```

Fixing the device's own timezone is worth proposing separately - it makes the
inner fields line up - but it introduces a discontinuity in existing logs, so
it is a change to make deliberately rather than as a side effect of adding
syslog.

## Adding a device

1. Append to `SYSLOG_DEVICES` in `.env`: `<addr>|<name>` (space separated).
2. Allow the sender through the host firewall.
3. `docker compose up -d rsyslog`

Unlisted senders are filed under `_unknown` rather than dropped, so a typo
shows up as data in the wrong directory instead of silence. To drop them
instead, replace the default in `config/rsyslog/entrypoint.sh` with `stop`.

## Operations

```
docker compose up -d --build          # build and start
docker compose logs -f rsyslog        # receiver
docker logs syslog-retention          # daily volume report
docker exec syslog-retention sh /retention.sh   # run retention now
```

Troubleshooting a silent pipeline, in the order that finds it fastest:

```
sudo ss -lunp | grep 514                        # is rsyslog listening
sudo ufw status | grep 514                      # is the host firewall allowing it
sudo tcpdump -i any -n udp port 514 -c 5        # are packets arriving
docker logs rsyslog                             # config errors, device map
ls -la data/logs/*/                             # are files being written
docker logs syslog-alloy                        # is shipping working
curl -s http://127.0.0.1:3100/loki/api/v1/label/device/values   # did it land
```

On a FortiOS sender, the equivalents are:

```
diagnose test application syslogd 1                       # server state, drop counters
diagnose sniffer packet any 'udp and port 514' 4 8 a      # is it actually sending
diagnose log test                                         # generate test events
```

## Dashboard

The panel that matters is ingest rate. This pipeline's dangerous failure is
silence, not noise - a stat that reads 0 and turns red is the only thing
separating "the device is quiet" from "we stopped receiving three days ago and
nobody noticed". Alert on that one.

Syslog answers *what happened*. Pair it with metrics (SNMP, or whatever the
device exposes) for *how it got there* - a resource leak shows up as a slope in
metrics long before it shows up as an event.
