# Rollback

Adding a syslog destination is additive and reversible on both sides. Nothing
here requires a device restart.

Capture the sender's current state **before** changing anything, and keep that
capture next to the deployment - see `ROLLBACK.local.md` (not tracked; a
per-deployment file, since it contains your addresses and your prior config).

## Sender - capture first

On FortiOS:

```
show full-configuration log syslogd setting
show full-configuration log syslogd filter
```

Save both. Use one syslog slot and leave the others (`syslogd2`..`syslogd4`)
untouched so an existing collector is never disturbed.

## Sender - restore

Setting `status disable` stops forwarding while leaving `server` / `format` /
`source-ip` in place:

```
config log syslogd setting
    set status disable
end
```

To clear the destination as well:

```
config log syslogd setting
    unset server
    unset source-ip
    unset format
    set status disable
end
```

Then restore the filter to whatever the capture showed, for example:

```
config log syslogd filter
    set severity information
    set forward-traffic enable
    set local-traffic enable
    set multicast-traffic enable
    set sniffer-traffic enable
    set ztna-traffic enable
    set http-transaction enable
    set anomaly enable
    set voip enable
    set forti-switch enable
    set debug disable
end
```

Confirm:

```
show full-configuration log syslogd setting
diagnose test application syslogd 1
```

## Stop receiving without touching the sender

```
docker compose down
sudo ufw delete allow from <DEVICE_IP> to any port 514 proto udp
```

UDP is fire-and-forget, so the sender keeps trying and nothing blocks or queues
on the device.

## Remove Loki from the metrics stack

If Loki was added to an existing compose project, back that project up first,
then:

```
docker compose stop loki && docker compose rm -f loki
git checkout -- docker-compose.yml
rm -f config/grafana/provisioning/datasources/loki.yml
docker compose restart grafana
```

`data/loki/` holds the ingested logs; delete it only if you mean to discard
them.

## Remove this stack entirely

```
docker compose down
```

Then remove the service account and data directory if one was created for it.
`data/` holds the received logs - it is the thing this stack exists to keep, so
delete it deliberately.
