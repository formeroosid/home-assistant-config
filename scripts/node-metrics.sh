#!/usr/bin/env bash
# Fetch the ha-metrics JSON blob from a homelab node. Arg 1 = host IP.
exec ssh -i /config/.ssh/id_ed25519_hamon \
  -o UserKnownHostsFile=/config/.ssh/known_hosts \
  -o StrictHostKeyChecking=yes \
  -o BatchMode=yes \
  -o ConnectTimeout=8 \
  -o LogLevel=ERROR \
  "hamon@$1"
