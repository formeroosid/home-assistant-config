# Home Assistant Runbook — Swamp Castle

Last updated: 2026-08-30 Maintainer: Jamie Gordon Primary node: **whitey** (192.168.86.101)

---

## 1\. Architecture

### Install method

Home Assistant **Container** (not HAOS, not Supervised), running as a Portainer stack named `homeassistant` on whitey.

| Item | Value |
| :---- | :---- |
| Image | `ghcr.io/home-assistant/home-assistant:${HA_VERSION}` |
| `HA_VERSION` | `2026.8` (floating patch tag — deliberate) |
| Network mode | `host` |
| Privileged | `true` |
| Timezone | `America/Los_Angeles` |
| Stack directory | `/srv/docker/homeassistant` |
| Config directory | `/srv/whitey-r6/VarData/Docker-data/HomeAssistant/config` |
| External URL | `https://ha.jamiegordon.net` |

**Why Container over HAOS:** fits the existing Portainer workflow on whitey, needs no KVM/virtualisation layer, and the primary goal (an infrastructure dashboard) only requires network-reachable integrations.

**Known trade-offs of Container mode:**

- No add-on store. Anything an add-on would provide must run as its own container.  
- Updates are manual (`docker compose pull` / Portainer stack re-pull).  
- No out-of-the-box Thread or Z-Wave support. Zigbee via ZHA works normally.

### Config file layout

```
config/
├── configuration.yaml          # includes: homeassistant.packages
├── secrets.yaml                # NOT in git
├── packages/
│   └── homelab_nodes.yaml      # command_line + template sensors, recorder excludes
├── scripts/
│   └── node-metrics.sh         # SSH wrapper used by command_line sensors
└── .ssh/
    ├── id_ed25519_hamon        # monitoring private key (NOT in git)
    ├── id_ed25519_hamon.pub
    └── known_hosts
```

Keys must live under `/config` so they survive container recreation.

> **Ownership note:** the HA container runs as root, so everything under `config/` is root-owned. Always edit with `sudo vim`. Do **not** use `sudo -u jgordon vim` — it produces `E45: 'readonly' option is set`.

---

## 2\. Reverse proxy and DNS

| Item | Value |
| :---- | :---- |
| Proxy | Nginx Proxy Manager on whitey |
| Forward target | `192.168.86.101:8123` |
| Certificate | JGDN wildcard |
| Websockets | **ON** (required — HA will not load without it) |
| Force SSL | ON |
| HTTP/2 | ON |
| DNS | Pi-hole local DNS record `ha.jamiegordon.net` → 192.168.86.101 |

### Trusted proxies

Set in the UI at **Settings → System → Network → HTTP server**:

```
127.0.0.1
::1
172.16.0.0/12
```

Trust X-Forwarded-For: **ON**

As of 2026.8 these settings live in the UI, not YAML. Remove any `http:` block from `configuration.yaml`.

> **CRITICAL GOTCHA:** the trusted-proxies list is silently discarded on save unless the **Trust X-Forwarded-For** toggle is enabled *in the same save*. Symptom is `400 Bad Request` through NPM with an apparently empty proxy list after restart. Also: the field takes **one entry per row** — comma-separated values are rejected.

---

## 3\. Backups

### Native HA backups

Configured in **Settings → System → Backups**.

| Setting | Value |
| :---- | :---- |
| Schedule | Daily 03:30 |
| Retention | 7 backups |
| Contents | Config \+ SSL, database **included** |
| Encryption | Enabled |

**The encryption key is stored in 1Password** alongside the HA login credentials. Without it a backup cannot be restored. Verify it is still there whenever the key is rotated.

### Off-node mirror

`/usr/local/sbin/ha-backup-sync` (mode 750, root) does the following:

1. Verifies the newest backup is less than 26 hours old.  
2. Runs `tar -tf` as an integrity check.  
3. `rsync`s `config/backups/` → `/srv/whitey-r6/Backups/HomeAssistant/`.  
4. Enforces 30-day retention at the destination.  
5. Writes the `.last_backup` sentinel (ISO timestamp \+ byte count).  
6. Alerts through `/usr/local/sbin/bkup-alert` on failure.

rsync return codes 23 and 24 are treated as warnings, not failures (vanished files during transfer are normal).

Scheduling: `ha-backup-sync.timer`, daily 04:15, `RandomizedDelaySec=300`, `Persistent=true`. Logs in `/var/log/ha_bkup/`, rotated by `/etc/logrotate.d/ha_bkup`.

### Restore procedure

1. Recreate the container from the Portainer stack.  
2. Complete onboarding far enough to reach the restore prompt, or use **Settings → System → Backups → Upload backup**.  
3. Supply the encryption key from 1Password.  
4. After restore, re-verify trusted proxies (see the gotcha above).

### Still outstanding

**No offsite copy exists.** Both the live config and the mirror are on whitey. A whitey loss is currently a total loss for HA. Deferred deliberately — it is part of a broader household offsite-backup decision, not an HA-specific one.

---

## 4\. Infrastructure monitoring

### Design

One unprivileged SSH account per host, locked to a single forced command that emits one JSON blob. HA opens **one connection per host per interval** rather than one per metric.

```
HA container ──ssh(hamon)──▶ whitey  192.168.86.101
                          ├─▶ larry   192.168.86.102
                          ├─▶ lumpy   192.168.86.100
                          └─▶ uther   192.168.86.103
```

### The hamon account

Present on whitey, larry, lumpy, uther. In the `docker` group on **whitey and lumpy only** (the two hosts running containers).

`~hamon/.ssh/authorized_keys` on every host contains exactly one line:

```
restrict,command="/usr/local/sbin/ha-metrics" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOzyN4QlCXC0VU2vsoNI3YnjBHyQX5bn//6BPsAN6uSl homeassistant@whitey
```

`restrict` disables port forwarding, agent forwarding, X11, and PTY allocation. The forced command means the key cannot obtain a shell even if stolen.

### The collector

`/usr/local/sbin/ha-metrics`, mode 755, root-owned, **identical on all four hosts**. Host-specific behaviour is selected by `hostname -s`.

Emits: uptime, load, cores, memory percent, kernel, OS, pending apt updates, reboot-required flag, filesystems, Docker containers with image tags, systemd unit states, mdadm array status, and backup sentinel ages.

Design constraints, all deliberate:

- **Always emits valid JSON**, even on partial failure. Every section degrades to an empty array. A collector that dies on an edge case turns the dashboard into a wall of `unavailable`, which is worse than useless because you stop trusting it.  
- **No `set -e`.** Opposite of normal practice, and correct here: a failing subcommand must not abort before output is emitted.  
- **No `jq`, no `sudo`.** Pure coreutils and awk, running with ordinary `hamon` privileges. No new privilege surface, no dependency to install on four hosts.  
- Docker access comes from group membership; the block is skipped where absent.

Units monitored per host:

| Host | Units |
| :---- | :---- |
| whitey | docker, ssh, rsyslog, ha-backup-sync.timer |
| lumpy | docker, ssh |
| uther | sonarr, radarr, prowlarr, qbittorrent-nox, wg-quick@pia, vpn-netns, pia-refresh-wireguard.timer, postfix |
| larry | ssh |

### Deploying a collector change

Edit on whitey, then push:

```shell
for h in 192.168.86.102 192.168.86.100 192.168.86.103; do
  scp /usr/local/sbin/ha-metrics jgordon@$h:/tmp/ha-metrics
  ssh -t jgordon@$h 'sudo install -m 755 -o root -g root /tmp/ha-metrics /usr/local/sbin/ha-metrics \
    && rm /tmp/ha-metrics \
    && sudo -u hamon /usr/local/sbin/ha-metrics | head -c 200; echo'
done
```

Always validate as `hamon`, not root — that is how HA invokes it, and it is the only test that exposes permission gaps:

```shell
sudo -u hamon /usr/local/sbin/ha-metrics | python3 -m json.tool
```

### Backup sentinel ACLs (whitey)

The collector reads five `.last_backup` sentinels. `MyStash` is `drwxrws--- root:users`, so `hamon` needs explicit access. POSIX ACLs are used rather than group membership, because `MyStash` is group-writable and adding `hamon` to `users` would give the monitoring account write access to every workstation backup.

```shell
sudo apt install -y acl

sudo setfacl -m u:hamon:x  /srv/whitey-r6/Workstations
sudo setfacl -m u:hamon:rx /srv/whitey-r6/Workstations/MyStash
sudo setfacl -m u:hamon:rx /srv/whitey-r6/Workstations/MyStash/christy \
                           /srv/whitey-r6/Workstations/MyStash/jgordon

for d in /srv/whitey-r6/Workstations/MyStash/christy/Krizzybkup \
         /srv/whitey-r6/Workstations/MyStash/jgordon/larry \
         /srv/whitey-r6/Workstations/MyStash/jgordon/gussy \
         /srv/whitey-r6/Workstations/MyStash/jgordon/GburgClone; do
  sudo setfacl -m u:hamon:rx "$d"
  sudo setfacl -d -m u:hamon:r "$d"
  sudo setfacl -m u:hamon:r "$d/.last_backup"
done
```

`/srv/whitey-r6/Backups/HomeAssistant` needs nothing — it is already `755` with a `644` sentinel.

**Why `rx` and not `x` on the parent directories:** globbing requires *read* on each intermediate directory, not merely traverse. An explicit path works with `x` alone, which is why `cat` succeeded while the collector's `for s in .../*/*/.last_backup` glob stayed literal.

Verify access and boundary together:

```shell
cd / && sudo -u hamon cat /srv/whitey-r6/Workstations/MyStash/*/*/.last_backup
cd / && sudo -u hamon find /srv/whitey-r6/Workstations/MyStash -maxdepth 3 \
  -type f ! -name '.last_backup' -exec head -c 1 {} \; 2>&1 | head -3
```

The first must print five timestamp/byte pairs. The second **must** produce permission errors — if it prints file content the ACLs are too broad.

> The default ACLs (`-d`) make new sentinel files inherit read access. Whether that holds depends on how each backup script writes its sentinel: a direct `>` rewrite inherits, a write-to-temp-then-rename from outside the directory does not. If a source goes unreadable after a backup run, add the ACL to that script's write path.

---

## 4a. rsnapshot backup monitoring (lumpy)

Lumpy's rsnapshot job is the largest backup in the house — roughly 9.1 TB of media — and until 2026-08-21 it was completely invisible to HA. It now reports full state hourly.

### What the job actually is

| Item | Value |
| :---- | :---- |
| Config | `/etc/rsnapshot-lumpy.conf` — **not** the default `/etc/rsnapshot.conf`, which does not exist on lumpy |
| Snapshot root | `/mnt/backup/.snapshots/.sync/lumpy_media/` |
| Backup point | `backup /data/ lumpy_data/` |
| Underlying storage | `whitey:/srv/MediaBkup` over **NFS 4.2, autofs-mounted, `hard`** (see topology below) |
| Retention | `retain daily 7`, `retain weekly 4` |
| Log | `/var/log/rsnapshot-lumpy.log` |
| Lockfile | `/var/run/rsnapshot-lumpy.pid` |
| Schedule | daily at 00:00, 08:00, 16:00; weekly Sunday 04:00 |

A daily run takes 60–70 minutes.

### Storage topology on whitey

```
LV Backup-Workstations/Media, 16.37 TiB, ext4
  └─ mounted at /srv/media                     <- the filesystem (inode 2)
       └─ MediaBkup/    drwxrwsr-x root:users   <- a subdirectory
            └─ bind-mounted to /srv/MediaBkup  <- the only NFS export
                 └─ .snapshots/.sync/lumpy_media/
```

`/etc/fstab` on whitey:

```
UUID=cab91b34-...  /srv/media      ext4  defaults,nofail,noatime,x-systemd.device-timeout=45  0 0
/srv/media/MediaBkup  /srv/MediaBkup  none  bind,nofail,x-systemd.requires-mounts-for=/srv/media  0 0
```

Export (lumpy only):

```
/srv/MediaBkup  192.168.86.100(rw,sync,no_subtree_check,fsid=1,no_root_squash,...)
```

**Why the bind mount exists:** it narrows the NFS export to one subdirectory. Without it, whitey would have to export `/srv/media` and hand lumpy the entire 17 TB filesystem. `fsid=1` is required because NFS needs an explicit fsid to export a bind mount.

**Why that pairs with `no_root_squash`:** lumpy's rsnapshot runs as root and must create root-owned snapshot directories with ownership preserved, so root-squashing would break it. That makes lumpy's root effectively root inside the export — and the bind mount is what confines that authority to one subtree instead of the whole volume. The two settings are a deliberate pair; do not remove one without reconsidering the other.

> **Distinguishing the two mounts:** `mount | grep media` shows the same device twice and looks like a duplicate. It is not. `stat -c '%d %i' /srv/media /srv/MediaBkup` returns the same device with **different inodes** (`2` vs `138936321`), which is the signature of a bind mount of a subdirectory. ext4 has no subvolumes, so a genuine second mount of the whole filesystem would report inode 2 for both.

**Capacity note:** as of 2026-08-21 `/srv/media` holds only `MediaBkup` and `lost+found` — all 9.1 TB of the 17 TB in use is lumpy's rsnapshot data, 7.2 TB free. There is **no quota or reservation**, so the backup can grow into the whole volume. If a media library is later added alongside it, the two compete for the same free space with nothing arbitrating. The dashboard's `disk_pct` measures the whole volume, not the backup's share of it.

### Why a root-run collector was unavoidable

The snapshot tree is `drwx--S--- root:users`. Group `users` has **no** access, so even `jgordon` gets `Permission denied` — `hamon` never had a chance. Granting an ACL was rejected: the whole point of `hamon` is that it holds no privilege worth stealing, and read access to every backup of every machine is exactly the sort of thing worth stealing.

The pattern used instead is the same one already chosen for uther's VPN check (§10): **a privileged writer, an unprivileged reader.**

```
root (systemd timer) ──▶ /var/lib/ha-metrics/rsnapshot.json (644)
                                    │
                       hamon ──▶ ha-metrics inlines it as extra{}
                                    │
                       HA ──▶ sensor.lumpy_metrics attribute "extra"
```

No sudo is added anywhere, and `ha-metrics` stays identical on all four hosts.

### The state collector

`/usr/local/sbin/ha-rsnapshot-state`, mode 755, root-owned, lumpy only. Runs in about 86 ms.

```shell
/usr/local/sbin/ha-rsnapshot-state /etc/rsnapshot-lumpy.conf
```

Writes `/var/lib/ha-metrics/rsnapshot.json` atomically (temp file plus `mv`) at mode 644, so a reader never sees a half-written file. It parses the config rather than hardcoding paths, so editing `rsnapshot-lumpy.conf` does not silently break monitoring.

**Every probe is timeout-bounded** — `timeout 5 findmnt`, `timeout 8 test -d`, `timeout 20 find`, `timeout 8 df`. On a `hard` NFS mount an unbounded call blocks forever, and this script runs as root on a timer where a hung instance would accumulate.

> **Never put `du` in this script.** `du -shx` on the snapshot root takes many minutes on 9.1 TB of hardlinked trees. `df` on the filesystem is the answer.

Fields emitted: `ok`, `error`, `ts`, `config`, `snapshot_root`, `mounted`, `stalled`, `root_local`, `fstype`, `source`, `no_create_root`, `list_ok`, `levels[{level,retain,count,age_hours,short}]`, `lock_present`, `lock_alive`, `lock_age_hours`, `disk_pct`, `disk_free_bytes`, `log_errors`, `log_warnings`, `log_last`, `last_run_level`, `last_run_rc`, `last_run_age_hours`, `last_run_seconds`.

Timer: `ha-rsnapshot-state.timer`, `OnCalendar=hourly`, `RandomizedDelaySec=120`, `Persistent=true`.

### Error counting is relative to the last success

A naive `tail -400 | grep -c ERROR` reads non-zero **forever** once any failure lands in the log, which makes the field useless. The parser instead resets its counters whenever it sees a `completed successfully` line, and separates genuine errors from benign warnings — rsync exit code 24 (`file(s) vanished`) is normal on a live media tree and must not raise an alert.

### The `extra{}` passthrough

`ha-metrics` gained a generic block that inlines any JSON under `/var/lib/ha-metrics/*.json` as `"extra":{...}` in its output. It is deployed to all four hosts and is empty (`"extra": {}`) everywhere except lumpy. This is the same hook uther's `vpn.json` will use, so no further collector change is needed for that work.

`extra` must also be listed under `json_attributes` in `packages/homelab_nodes.yaml`, or HA discards it silently.

### Verifying the whole chain

On lumpy:

```shell
sudo /usr/local/sbin/ha-rsnapshot-state /etc/rsnapshot-lumpy.conf
sudo python3 -m json.tool /var/lib/ha-metrics/rsnapshot.json
systemctl list-timers ha-rsnapshot-state.timer --all
```

Do **not** try `ssh jgordon@lumpy 'sudo -u hamon ...'` — it fails with `sudo: a terminal is required to read the password` without `-t`. Verify the HA end in **Settings → Tools → States**, on `sensor.lumpy_metrics`, attribute `extra`. That is what HA actually sees, which is the only view that matters.

### Alert thresholds

Split deliberately, because the two levels age differently:

| Condition | Threshold |
| :---- | :---- |
| daily snapshot age | \> 14 h |
| **weekly snapshot age** | **\> 288 h (12 days)** |
| snapshot count below `retain` | `short: true` |
| Volume usage | ≥ 85% |

> **Why weekly gets 12 days:** a weekly snapshot is a *promoted daily*, so its mtime is inherited and legitimately reads 6–9 days old. A 7-day threshold would alert every single week. Currently 158 h (6.6 d) — normal.

Hard alerts, any of which mean something is actually broken: `!mounted || stalled`, `root_local`, `no_create_root != 1`, `lock_present && !lock_alive`, `log_errors > 0`, `last_run_rc > 0`, `!list_ok`.

### The `no_create_root` trap

This is the most important thing in this section.

`/etc/rsnapshot-lumpy.conf` shipped with `no_create_root 0`. With a **remote** snapshot root, that setting is actively dangerous: if whitey or NFS is down, `/mnt/backup` is an empty local directory, and rsnapshot will happily **create the snapshot root on lumpy's local disk** and begin writing 8.5 TB into a 97.9 GB filesystem. The backup does not fail loudly — it fills the root filesystem and takes the host down with it.

This nearly fired on 2026-07-27; the log shows `ERROR: Unable to create /mnt/backup/.snapshots/.sync/lumpy_media/,`.

Fixed by setting `no_create_root 1`, which makes a missing root a hard refusal. Verified against the [rsnapshot FAQ](http://rsnapshot.org/faq.html) and the [rsnapshot man page](https://linux.die.net/man/1/rsnapshot). Confirm after any config edit:

```shell
grep -n '^no_create_root' /etc/rsnapshot-lumpy.conf   # must be 1
sudo rsnapshot -c /etc/rsnapshot-lumpy.conf configtest
```

A shadowed-local check confirmed nothing ever leaked — unmounting and measuring the underlying directory returned 4.0K.

### The run wrapper

`/usr/local/sbin/ha-rsnapshot-run`, mode 755, root-owned, lumpy only.

```shell
/usr/local/sbin/ha-rsnapshot-run <config> <level>
```

It records `started`, `rc`, and `duration`, then calls `ha-rsnapshot-state` so the dashboard reflects the run within seconds instead of waiting up to an hour for the timer. **It exits with rsnapshot's own return code**, so cron's mail behaviour is unchanged from calling rsnapshot directly — the wrapper only observes.

Without it, `last_run_*` reads `-1` / `unknown` and a *failed* run is indistinguishable from a merely *old* one.

The record is `/var/lib/ha-metrics/rsnapshot-lastrun`, mode 644, written atomically. `ha-rsnapshot-state` parses it with `awk -F=` and reads four keys:

```
level=daily
rc=0
started=1787327305
duration=3900
finished=1787331205
config=/etc/rsnapshot-lumpy.conf
```

`finished` and `config` are for humans; the collector ignores unknown keys.

The wrapper **refuses to write a record** on bad invocation — exit 64 for missing arguments, exit 66 for an unreadable config — because a wrapper that reports a run that never happened is worse than no wrapper at all. Both paths are hand-tested.

Root crontab on lumpy (`MAILTO=jamie@jamiegordon.net` already set):

```
0 0,8,16 * * *   /usr/local/sbin/ha-rsnapshot-run /etc/rsnapshot-lumpy.conf daily
0 4 * * 0        /usr/local/sbin/ha-rsnapshot-run /etc/rsnapshot-lumpy.conf weekly
```

The argument order was chosen to match the existing crontab, so the switch was a single in-place substitution with the schedules untouched.

> **Sequence matters.** Create and hand-test the wrapper **before** repointing cron at it. An earlier attempt edited the crontab to call a script that did not exist yet, 13 minutes before the 08:00 run. Caught and reverted, but that is how a backup silently stops.

### Hand-testing the wrapper safely

Invoking it with a bogus interval name is **not** as harmless as it looks: rsnapshot checks its lockfile *before* validating the interval, so if a real run is in progress the test fails on the lock and writes an `ERROR:` line to the rsnapshot log. That line counts toward `log_errors` until the next successful run resets it.

The test is still worth running — it exercises the timing, the record write, the state refresh, and the exit code — but afterwards clear the synthetic result so a fake failure is not left on the dashboard:

```shell
sudo rm -f /var/lib/ha-metrics/rsnapshot-lastrun
sudo /usr/local/sbin/ha-rsnapshot-state /etc/rsnapshot-lumpy.conf
```

> **Open question: rsnapshot exit code 2\.** rsnapshot returns 2 for *warnings* — including the routine rsync code 24 `file(s) vanished`, which happens on any live media tree. The card currently alerts on `last_run_rc > 0`, which would therefore fire on healthy runs. Once a real run has reported its code, treat 2 as a warning and reserve the hard alert for 1 and anything above 2\. The `log_errors` parser already makes this distinction; the run alert does not yet.

---

## 4b. VPN egress monitoring (uther)

Verifies that qBittorrent traffic on uther actually leaves through the PIA tunnel, not merely that the tunnel is up. Built 2026-08-24.

### Why a separate collector

`pia-refresh-wireguard` already existed and has `tunnel_healthy()` and `exit_ip()` helpers, so extending it looked attractive. It was rejected: that script is a **remediator** — it deletes tokens, re-registers with PIA, and restarts `wg-quick@pia`, `vpn-netns`, `prowlarr`, and `qbittorrent-nox`. Observation must never be able to trigger remediation, and a monitor that can restart the thing it measures cannot be trusted to report on it. `ha-vpn-state` is strictly read-only: `wg show`, routing tables, `/proc`, and two HTTPS calls.

### Architecture being monitored

```
root ns: enp3s0f0 192.168.86.103 -> gilbert -> ISP;  veth-host 10.200.200.1/30
vpn ns:  veth-vpn 10.200.200.2/30;  pia 10.20.0.22/32;  qbittorrent-nox, prowlarr
```

The invariant: inside the `vpn` netns the only default route is `default dev pia scope link`. There is **no** default via the veth, so if the tunnel drops, traffic has nowhere to go and **fails closed structurally** rather than by firewall rule. `192.168.86.0/24 via 10.200.200.1` exists for LAN reachability only. IPv6 has no address on `pia` and only `fe80::/64` in the netns, so v6 is closed.

### Files

| Path | Host | Purpose |
| :---- | :---- | :---- |
| `/usr/local/sbin/ha-vpn-state` | uther | read-only collector, writes JSON |
| `/var/lib/ha-metrics/vpn.json` | uther | output, 644, consumed by `ha-metrics` |
| `/var/lib/ha-metrics/vpn-egress.cache` | uther | cached public IPs |
| `/etc/systemd/system/ha-vpn-state.service` | uther | `Type=oneshot` |
| `/etc/systemd/system/ha-vpn-state.timer` | uther | 5 min cadence |

Mirrored in git at `deploy/uther/` by the uther pull block in `ha-config-commit` (see 6a).

### How it reaches Home Assistant

**No `ha-metrics` change was required.** Its `extra{}` block already globs `/var/lib/ha-metrics/*.json` and keys each file by its basename, so writing `vpn.json` surfaced it as `extra.vpn` automatically. Writing the file *was* the integration.

Two naming details keep that safe, and must be preserved:

- the IP cache is `vpn-egress.cache`, **not** `.json`, so it is not slurped in as a bogus `extra` key;  
- the atomic temp file is `.vpn.json.XXXXXX` — leading dot, and does not end in `.json` — so a half-written file can never be picked up mid-write.

Verified readable by the `hamon` account that HA connects as.

### Leak detection method

Compare the public IP seen from the root namespace against the one seen from inside the `vpn` namespace. The two namespaces *are* the two egress paths, so no interface forcing or source routing is needed.

- different addresses \-\> tunnelled  
- identical addresses \-\> **leak**

Observed healthy values: vpn `173.239.198.63`, WAN `<home-wan-ip>`. Note the vpn address sits in the same `/24` as the tunnel endpoint `173.239.198.103`, which corroborates that the VPN path really is on PIA's network rather than merely being *different* from the WAN address.

### Status precedence

`leak` and `leak_route` outrank everything else. Staleness (\>15 min) overrides the headline entirely — a confident "Tunneled" banner over dead data is worse than no banner, so the card refuses to assert health it cannot substantiate.

`namespace_missing`, `tunnel_missing`, `blocked`, `orphaned`, `tunnel_stale`, `wan_down`, `ok_unconfirmed`, `ok`.

Route and kill-switch checks are local and never gated on internet reachability. The egress comparison degrades to `unknown` when the WAN is down, and a stale handshake is then read as a *consequence* of the outage rather than a fault of its own.

### Orphaned-namespace failure mode

`/etc/vpn-netns/up.sh` begins with an idempotent `ip netns del vpn`, so a manual `systemctl restart vpn-netns` destroys and recreates the namespace and leaves qBittorrent running in a **dead, routeless namespace**. It fails closed, so nothing leaks, but it is silent — torrents simply stall forever.

Detected by comparing `stat -Lc %i /proc/<qbit_pid>/ns/net` against `/var/run/netns/vpn`; reported as `qbit_ns_ok`. Remedy is `systemctl restart qbittorrent-nox`.

### Timer

Deployed unit uses `OnBootSec=2min` \+ `OnUnitActiveSec=5min` \+ `AccuracySec=30s` \+ `RandomizedDelaySec=20`.

`Persistent=true` is deliberately **absent**, unlike the backup timers: this is instantaneous state, so a catch-up run after downtime would only write a reading nobody wants.

`RandomizedDelaySec` keeps samples off exact-minute boundaries, reducing overlap with `pia-refresh-wireguard.timer` (hourly), which restarts the tunnel and the namespace. A sample landing mid-restart reports `namespace_missing` — accurate but not actionable. **The fix for that belongs in the notification layer, not the collector:** require a bad state to persist across two consecutive samples before alerting. Not yet built.

> A relative timer anchors its next run to the last activation, so a manual `systemctl start` shifts the schedule. `OnCalendar=*:0/5` would be deterministic instead. Considered and not applied; the relative form is working. Do not "fix" this without reason.

### DNS asymmetry (open, deliberate)

`/etc/netns/vpn/resolv.conf` lists `192.168.86.101` (whitey) then `1.1.1.1`. Whitey is reached **over the veth, outside the tunnel**; `1.1.1.1` has no LAN route so it resolves **inside** the tunnel. Tracker lookups therefore leak to the ISP's upstream resolver even while the payload traffic is correctly tunnelled. The `up.sh` comment ("keep netns resolvers, not PIA's") shows this was intentional. Flagged as a separate decision, not a defect.

### Verification

```shell
sudo /usr/local/sbin/ha-vpn-state
python3 -c "import json;print(json.load(open('/var/lib/ha-metrics/vpn.json'))['status'])"
systemctl list-timers ha-vpn-state.timer --no-pager
```

Healthy: `status: ok`, `tunneled: 1`, `default_route_dev: pia`, `leak_route_present: false`, `qbit_ns_ok: 1`, `handshake_age_s` \< 180, `egress_age_s` \< 900\.

### Dashboard card

`dashboards/cards/uther-vpn-card.yaml`, in the Uther section of Overview. Rendered against real and synthetic payloads across all ten status branches before deployment.

---

## 4c. MQTT broker (Mosquitto on whitey)

Added 2026-08-30. Container mode has no add-on store, so the broker that most Home Assistant installs get as the Mosquitto add-on runs here as its own container instead.

| Item | Value |
| :---- | :---- |
| Image | `eclipse-mosquitto:2` (2.1.2) |
| Container | `mosquitto`, `restart: unless-stopped` |
| Listener | `1883`, plain TCP, LAN only |
| Config directory | `/srv/whitey-r6/VarData/Docker-data/Mosquitto/config` |
| Data / log | `/srv/whitey-r6/VarData/Docker-data/Mosquitto/{data,log}` |
| Broker users | `hass` (Home Assistant), `frigate` (Frigate on lumpy) |
| Anonymous access | `allow_anonymous false` |
| Reverse proxy | **None.** MQTT is not HTTP, so the NPM/JGDN rule does not apply |

`mosquitto.conf`:

```
listener 1883
allow_anonymous false
password_file /mosquitto/config/passwd
persistence true
persistence_location /mosquitto/data/
```

### Three separate credentials

Easy to conflate, and conflating them wastes an hour:

| Credential | Lives in | Used by |
| :---- | :---- | :---- |
| Broker user `hass` | Mosquitto `passwd` on whitey | HA's MQTT integration |
| Broker user `frigate` | Mosquitto `passwd` on whitey | Frigate's `mqtt:` block on lumpy |
| Frigate UI login | Frigate's own user store on lumpy | The Frigate **integration** in HA, against port 8971 |

Two broker accounts rather than one shared account, so either can be rotated or revoked without taking down the other. The broker password must **not** reuse the Frigate admin password — MQTT sends it in cleartext on 1883\.

### Password file management

The password file is created and edited only through the image's own `mosquitto_passwd`, never by hand:

```shell
cd /srv/whitey-r6/VarData/Docker-data/Mosquitto/config
docker run --rm -v "$PWD":/mosquitto/config eclipse-mosquitto:2 \
  mosquitto_passwd -b /mosquitto/config/passwd hass 'password'
docker kill -s HUP mosquitto
```

Design notes, all deliberate:

- **A throwaway container, not `docker exec`.** On first setup the broker is not running yet — it restart-loops until `passwd` exists — so `docker exec` is unavailable exactly when the file needs creating. A `--rm` container mounting the same config directory has no such dependency. Use `-c` only for the very first user; it truncates the file.  
- **`SIGHUP`, not restart.** `docker kill -s HUP mosquitto` reloads the config and password file without dropping connected clients. The broker log confirms it with `Reloading config`.  
- **Ownership stays `1883:1883`, mode `600`.** The broker reads `mosquitto.conf` as root, then drops to uid 1883 *before* reading `password_file`, so a root-owned `600` file is unreadable. The image entrypoint also runs `chown -R mosquitto:mosquitto /mosquitto` on every start, so ownership reverts regardless. Never bind-mount the config directory read-only for the same reason.  
- **Machine credentials avoid shell-special characters.** Alphanumeric and long. A `!` or `$` in an unquoted `.env` value or a bash command produces an authentication failure that looks identical to a wrong password.

`passwd` is **not** in git and must not be — it is a credential file. It is recreated in two commands from 1Password, which is why it is not worth protecting any other way. The compose file and `mosquitto.conf` are committed under `deploy/mosquitto/`.

### Verification

```shell
# positive — should stream broker stats
docker run --rm --network host eclipse-mosquitto:2 \
  mosquitto_sub -h 192.168.86.101 -u hass -P 'password' -t '$SYS/#' -v -C 5

# negative — must fail with "not authorised"
docker run --rm --network host eclipse-mosquitto:2 \
  mosquitto_sub -h 192.168.86.101 -t '$SYS/#' -C 1
```

The clients are not installed on whitey, and do not need to be — running them from the image avoids installing `mosquitto-clients` and any risk of a second broker appearing on the host.

The broker log is the authoritative place to diagnose a client that will not connect, because it distinguishes the two failure modes cleanly:

| Broker log line | Meaning |
| :---- | :---- |
| `New connection from <ip>` then `disconnected: not authorised` | Reachability is fine; the credential is wrong |
| Nothing at all from that IP | Config not loaded, wrong host, or blocked path — not a credential problem |

---

## 4d. Frigate integration (cameras on lumpy)

Added 2026-08-30. Frigate itself is unchanged and stays on lumpy; only the Home Assistant client side is new.

| Item | Value |
| :---- | :---- |
| Frigate host | lumpy, 192.168.86.100, Frigate 0.17 |
| Integration | `frigate-hass-integration` v5.11.0, installed through HACS |
| API URL configured in HA | `http://192.168.86.100:8971` |
| API auth | Frigate UI username and password |
| Event transport | MQTT to whitey `1883` as broker user `frigate` |
| Cameras surfaced | four |

### Order of operations

MQTT must be working **before** the integration is configured — many of the entities it creates are MQTT-fed, and a broker that is not connected produces a device full of `unavailable` rather than an obvious error.

1. Broker running and authenticating (§4c).  
2. `mqtt:` block in Frigate's `/config/config.yaml` on lumpy, pointing at 192.168.86.101 as user `frigate`; restart Frigate.  
3. HA: **Settings → Devices & Services → Add Integration → MQTT**, broker 192.168.86.101, port 1883, user `hass`.  
4. HACS sidebar panel → search Frigate → Download.  
5. **Restart Home Assistant.** The integration does not appear in the Add Integration list before this.  
6. **Settings → Devices & Services → Add Integration → Frigate**, URL as above.

The password in Frigate's config uses Frigate's own `{FRIGATE_MQTT_PASSWORD}` substitution, with the value supplied from the compose `environment:` or an adjacent mode-600 `.env`, so the credential stays out of the config file. Changing an environment variable requires `docker compose up -d frigate`; a plain `docker restart` will not pick it up.

### Which port, and why TLS matters here

| Port | Purpose | Notes |
| :---- | :---- | :---- |
| `5000` | Internal, unauthenticated | Intended for private networking such as Tailscale |
| `8971` | Authenticated UI and API | The correct choice for a separate host on the LAN |

Port 8971 defaults to **TLS with a self-signed certificate**, which Home Assistant refuses to verify — so either TLS is disabled on Frigate and HA uses `http://`, or Frigate is issued a real JGDN certificate. Unchecking "Validate SSL" is the third option and the worst one.

### Still to wire up

`media_source:` in `configuration.yaml` is what makes Frigate recordings and snapshots appear in Media Browser. Notification thumbnails and clips are served by HA itself at `https://ha.jamiegordon.net/api/frigate/notifications/<event-id>/…`, so the existing NPM proxy already covers external access — no new proxy host is needed.

### Version control

`custom_components/frigate` is tracked in git, consistent with the existing policy: HACS itself is excluded as re-downloadable, while the integrations it installs stay tracked because the list of what is installed is what a recovery needs.

---

## 5\. HA entities

Defined in `config/packages/homelab_nodes.yaml`.

| Entity | Purpose |
| :---- | :---- |
| `sensor.whitey_metrics` | Raw JSON blob as attributes; state is `online`/`error` |
| `sensor.larry_metrics` | same |
| `sensor.lumpy_metrics` | same |
| `sensor.uther_metrics` | same |
| `binary_sensor.<host>_online` | `connectivity` class, derived from the above |
| `sensor.homelab_nodes_online` | Count of reachable nodes (0–4) |
| `sensor.oldest_backup_age` | Hours; `detail` attribute holds the per-source list |
| `sensor.homelab_pending_updates` | Sum of pending apt packages across hosts |
| `sensor.homelab_containers_running` | whitey \+ lumpy running container count |

`scan_interval: 60`, `command_timeout: 20`, SSH `ConnectTimeout=8`. The SSH timeout fires first and cleanly, so HA never holds a sensor hung on a dead host.

**The four raw metrics sensors are excluded from the recorder.** Each carries a large attribute payload every 60 seconds; recording them would add hundreds of megabytes a month of data nobody queries. The small derived sensors *are* recorded, so useful history is retained.

**Node-down detection is free:** when SSH fails the command returns nothing, the sensor goes `unknown`, and the connectivity binary sensor flips off. No separate ping check. It cannot currently distinguish "host down" from "SSH broken".

The SSH wrapper uses `StrictHostKeyChecking=yes`, not `accept-new` — known\_hosts is already seeded, so an unexpected host key should be a hard failure.

`json_attributes` on all four metrics sensors includes `extra`, the passthrough for root-written state described in §4a. Lumpy's `extra.rsnapshot` is populated; the other three carry `{}` until uther's `vpn.json` lands.

---

## 6\. Dashboard

Dashboard **Homelab**, two views, defined via the raw configuration editor.

- **Overview** — Attention card, node/backup gauges, container and update tiles, per-node connectivity tiles, backup sentinel table, **Lumpy rsnapshot card**, uther service table.  
- **Nodes** — per-host card with OS, kernel, uptime, load, memory, filesystems, RAID arrays, containers with image tags, and systemd units.

The **Attention card is the point of the whole dashboard**. It walks every node, filesystem, container, and unit and surfaces only what is wrong; when everything is healthy it says so in one line. This inverts the usual homelab failure mode of forty gauges nobody reads after the first week.

Current alert thresholds, all inside the Attention card template:

| Condition | Threshold |
| :---- | :---- |
| Filesystem usage | \> 85% |
| Backup sentinel age | \> 30 h |
| Container state | anything but `running` |
| systemd unit state | anything but `active` or `unknown` |
| RAID | any `_` in the array status |
| Node | state not `online` |

The **Lumpy rsnapshot card** (§4a) is a separate markdown card reading `state_attr("sensor.lumpy_metrics","extra").rsnapshot`. It shows a health verdict, a per-level snapshot table, mount source, volume usage, error count, and any active alerts. Its thresholds are listed in §4a, not here.

### YAML gotchas for markdown cards

- Use `content: |` (literal block scalar). **Never `content: >-`** — the folded scalar collapses newlines into spaces and flattens every markdown table into one unreadable run of pipes.  
- Put loop row text on the **same line** as the `{% for %}` tag. Splitting them emits an extra blank line per row and breaks the table.  
- Use `{%- ... %}` for all logic lines. Indented output lines become markdown code blocks.  
- Gauge `severity:` values must **ascend**. For a higher-is-better metric, list `red` lowest. Avoid setting `green` equal to `max` — a zero-width band never renders.  
- **Keep templates simple and quote-light.** Building lists of quoted strings inside a card (`ns.alerts + ['**foo**']`) produced `TemplateSyntaxError: unexpected char "'"` after the dashboard editor round-tripped the YAML. A single boolean plus plain `{% if %}` blocks, double quotes, and ASCII-only text is robust. See §9.  
- **Add new cards through Manual card, not the raw editor.** The Manual card renders a live preview and shows the template error text; the raw editor saves silently and the dashboard renders a broken card as an empty box with no message at all.  
- Verify template logic in **Settings → Tools → Template** before it ever goes in a card. Note that `type_debug` does not exist in HA 2026.8.

---

## 6a. Version control

Repo: [**formeroosid/home-assistant-config**](https://github.com/formeroosid/home-assistant-config) (private).

Authentication is a **deploy key**, not a PAT — no expiry, scoped to this one repo.

| Item | Value |
| :---- | :---- |
| Private key | `/root/.ssh/id_ed25519_hagit` |
| SSH alias | `github-ha` (defined in `/root/.ssh/config`) |
| Key title on GitHub | `whitey-ha-config`, write access |
| Remote | `github-ha:formeroosid/home-assistant-config.git` |

Git runs as **root**, because the config tree is root-owned. Test the key path with `sudo ssh -T github-ha`; a reply naming the *repo* rather than the account confirms the deploy key is in use.

### What is deliberately NOT committed

`secrets.yaml`, `.ssh/`, `*.pem`, `*.key`, `*.db*`, logs, `backups/`, `tts/`, `deps/`, `image/`, `.uuid`, `.HA_VERSION`, `.cache/`, `*.lock`, and **`.storage/`**.

`.storage/` holds the entity registry and integration credentials as cleartext JSON, including auth tokens. It is genuinely required for a restore, which is exactly why the encrypted native backup covers it and git does not.

Always read `sudo git status --short` before the first commit after changing `.gitignore`. If `secrets.yaml`, `.storage/`, or anything under `.ssh/` appears, stop.

### Out-of-tree files

The most important scripts live outside `/config`, so `ha-config-commit` snapshots them into `deploy/` on each run:

| Destination | Source |
| :---- | :---- |
| `deploy/sbin/` | `ha-metrics`, `ha-backup-sync`, `ha-config-commit`, `bkup-alert` |
| `deploy/lumpy/` | `ha-rsnapshot-state`, `ha-rsnapshot-run`, `ha-rsnapshot-state.{service,timer}`, `rsnapshot-lumpy.conf` — pulled from lumpy over SSH, see below |
| `deploy/uther/` | `ha-vpn-state`, `ha-vpn-state.{service,timer}` — pulled from uther over one `ssh`\+`tar` connection; non-fatal if uther is unreachable, so a sleeping node never breaks the commit. Root on whitey already had key auth and a known host key for `uther`, so no SSH alias was needed. |
| `deploy/systemd/` | `ha-backup-sync.{service,timer}`, `ha-config-commit.{service,timer}` |
| `deploy/logrotate/` | `ha_bkup` |
| `deploy/dashboards/` | `lovelace*` extracted from `.storage`, as sorted pretty JSON |

Dashboards are exported because `.storage` is gitignored — without this, a whitey rebuild would lose the dashboard entirely. Only the `config` object is written, not the wrapper metadata, so no tokens leak.

### Pulling lumpy's files

The rsnapshot monitoring files (§4a) live on lumpy, outside whitey's filesystem. `ha-config-commit` pulls all five in **one** SSH connection using `tar`, rather than five `scp` calls:

```shell
ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes \
  "$LUMPY_HOST" "tar -cf - -C / $LUMPY_FILES" | tar -xf - -C "$tmpd"
```

`LUMPY_HOST=lumpy` — an alias defined in whitey's `/root/.ssh/config`:

```
Host lumpy
  HostName 192.168.86.100
  User jgordon
  IdentityFile /root/.ssh/id_ed25519
  IdentitiesOnly yes
```

The alias resolves to the **bare IP on purpose**, not to `lumpy.jamiegordon.net`, even though the `larry` entry uses a DNS name. Root's `known_hosts` holds exactly one lumpy entry and it is keyed to `192.168.86.100`; a hostname here would look up a key that is not there and `StrictHostKeyChecking=yes` would refuse the connection, silently breaking the 04:45 pull. Verify with `sudo ssh -G lumpy`, which prints what SSH actually resolves rather than what the file appears to say.

> **Caveat:** because the address now lives in root's SSH config, the script only resolves `lumpy` when run **as root** — which the timer does. Running it as `jgordon` by hand will log the non-fatal pull warning. The earlier hardcoded `jgordon@192.168.86.100` worked from any account.

Design notes:

- **Connects as `jgordon`, not `hamon` and not root.** All five files are 644 or 755, so an ordinary account reads them with no sudo. `hamon` is deliberately unusable here — its key is locked to a forced command precisely so it cannot copy files, and that is not weakened to save a few lines.  
- **`BatchMode=yes`** so it fails immediately instead of hanging on a password prompt. This runs unattended from a timer.  
- **Failure is non-fatal**, matching `git push`. If lumpy is down at 04:45 the commit proceeds and logs `WARN: could not pull rsnapshot files from lumpy`. The previous copies stay in the tree — stale-but-present beats absent. `set -uo pipefail` at the top of the script is what makes the SSH failure propagate correctly through the pipe into the `if`.  
- **The file count is checked.** Fewer than five logs a warning, which catches a file renamed or deleted on lumpy. Without it a stale copy would sit in the repo looking current forever.  
- **`StrictHostKeyChecking=yes` is explicit**, not inherited, so a changed host key fails loudly rather than quietly pulling files from something else.

Root's `known_hosts` was seeded by copying the already-verified entry from the HA container's store, **not** by `ssh-keyscan` (trust-on-first-use) and not with `accept-new`. The fingerprint was confirmed against lumpy itself first:

```shell
# on lumpy — authoritative
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
# on whitey — candidate, must match
sudo grep '192.168.86.100' "$CFG/.ssh/known_hosts" > /tmp/lumpy_hostkey
sudo ssh-keygen -lf /tmp/lumpy_hostkey
```

Lumpy's key is `SHA256:Lkx4ehN8PuHKr/DkjIl24dFQG3YJnimRmNdlhzPKY1s`.

Audited after the first commit — `rsnapshot-lumpy.conf` carries no credentials; `cmd_ssh /usr/bin/ssh` is a binary path and is unused, since these backups are local-to-NFS rather than over SSH.

> **Known defect:** the auto-commit subject line truncates the file list. A commit touching nine files may name only five, so the git log understates what changed. Read `git show --stat` rather than trusting the subject.

### Auto-commit

`ha-config-commit.timer`, daily 04:45, `RandomizedDelaySec=300`, `Persistent=true`. Placed after the 04:15 backup mirror so the day's commit includes anything that run changed.

**`git push` failure is non-fatal by design** — it logs a warning and exits 0\. An internet outage must not become a failed unit and an alert; the commit still landed locally and the next successful run pushes both. Log: `/var/log/ha_bkup/ha-config-commit.log`.

Credential audit before first commit — confirm no secrets in the snapshotted scripts:

```shell
sudo grep -iE 'pass|token|secret|key|@' /usr/local/sbin/ha-backup-sync /usr/local/sbin/bkup-alert
```

As of 2026-08-20 this returns only `MAIL_TO`, `MAIL_FROM`, and `RELAY_HOST=jgordon@uther` — addresses, not credentials. Safe.

---

## 7\. Maintenance schedule

| Cadence | Task |
| :---- | :---- |
| Daily (automatic) | HA backup 03:30; mirror \+ verify 04:15; config auto-commit 04:45 |
| Hourly (automatic) | `ha-rsnapshot-state` on lumpy refreshes rsnapshot state |
| Weekly | Review Attention card; clear reboot-required flags; apt updates on all four nodes |
| Monthly | Pull HA image for the current minor tag; check for a new HA minor release and read its breaking changes; `docker image prune` |
| Monthly | Confirm `.last_backup` sentinels still readable by `hamon` (catches ACL inheritance failures) |
| Monthly | Confirm `no_create_root` is still `1` in `/etc/rsnapshot-lumpy.conf` and `configtest` passes. A package upgrade or a hand edit reverting this is a filesystem-filling event, not an inconvenience. |
| Monthly | Confirm the lumpy pull is still working — \`grep 'lumpy:' /var/log/ha\_bkup/ha-config-commit.log |
| Monthly | Confirm `ha-config-commit` is still pushing — \`grep WARN /var/log/ha\_bkup/ha-config-commit.log |
| Monthly | Confirm MQTT is healthy — `frigate/available` reads `online` and the broker log shows both `hass` and `frigate` connected. A silent broker means no Frigate event entities, even though the camera pictures keep working from the API. |
| Annually | Rotate the two Mosquitto broker passwords (`mosquitto_passwd -b` \+ `SIGHUP`, then update Frigate's `.env` and HA's MQTT entry) and the Frigate UI login; update 1Password |
| Quarterly | Test-restore a backup into a throwaway container |
| Quarterly | Verify JGDN certificate expiry in NPM |
| Annually | Rotate the `hamon` SSH key; rotate the `whitey-ha-config` deploy key; rotate the backup encryption key and update 1Password; refresh the Enphase Envoy token |

### Updating Home Assistant

`HA_VERSION` is a floating minor tag (`2026.8`), so patch releases arrive on a re-pull. Minor upgrades are a deliberate edit.

1. Confirm a fresh backup exists.  
2. Read the release notes for breaking changes.  
3. Edit `HA_VERSION` in the stack environment.  
4. Re-deploy the stack in Portainer with re-pull enabled.  
5. Check **Settings → System → Logs**, then confirm all four metrics sensors still report `online`.

---

## 8\. Integration notes and constraints

| Device | Status | Notes |
| :---- | :---- | :---- |
| MyQ garage | **Dead end** | Integration removed in HA 2023.12. Replacement is ratgdo. |
| ratgdo | Planned | Recommend **ratgdo32** (ESP32, USB-C, case). Use ESPHome firmware, needs an ESPHome container. Security+ 1.0 openers additionally need an 889LM wall panel. Must confirm the opener's learn-button colour before ordering. |
| Rain Bird ESP-ME3 | Local | Works via the LNK WiFi module. **Do NOT upgrade to the Rain Bird 2.0 app or firmware** — it migrates the controller to the IQ4 cloud and permanently breaks the local API. |
| Enphase Envoy | Effectively local | Local REST API; cloud needed only for setup and an annual token refresh. |
| gilbert (XT8) | Use native integration | AsusWRT integration; no SSH monitoring needed. |
| gussy, krizzy | Presence only | DHCP addresses; ping/router-based presence. |
| Frigate (lumpy) | **Local, working** | Cameras, event entities, and Media Browser via the HACS integration over port 8971 plus MQTT. Nothing cloud-side. See §4d. |
| Mosquitto (whitey) | Local | Own container, not an add-on — Container mode has no add-on store. Also the transport any future ESPHome, ratgdo, or BLE-proxy device will use. See §4c. |
| Yale lock | Needs Z-Wave | Only device requiring Z-Wave. Container mode has no built-in support. |
| Tilt, Meater | Needs Bluetooth | Both BLE; require a radio or Bluetooth proxy near the equipment. |
| Zigbee (Hue etc.) | Recommended path | Ethernet coordinator — SMLIGHT SLZB-06 or Sonoff ZBDongle-E — via ZHA. |
| Thread / Matter | Skip | Not supported out of the box in Container mode. |

---

## 9\. Problems encountered and solved

| Symptom | Cause | Fix |
| :---- | :---- | :---- |
| `mkdir: Permission denied` on `/srv/docker/homeassistant` | Path needs root | Use `sudo` |
| `E45: 'readonly' option is set` in vim | Container runs as root, so `/config` is root-owned | `sudo vim`, not `sudo -u jgordon vim` |
| `400 Bad Request` through NPM | Trusted proxies silently discarded unless the X-Forwarded-For toggle is set in the same save | Enable the toggle and re-enter the proxies together |
| Trusted proxy entries rejected | Field takes one entry per row | No commas |
| `tar: backup.json: Not found in archive` | Archive members are `./`\-prefixed | Extract `./backup.json` |
| Backup only 140 KB | Genuinely normal for a one-day-old instance; manifest confirmed `exclude_database: false` | None; size grows with recorder history |
| SSH denied for `hamon` on larry and lumpy | `AllowUsers jgordon` at line 129 of `/etc/ssh/sshd_config` blocked hamon *before* key evaluation. uther was the outlier that lacked this workstation hardening. | Add `hamon` to `AllowUsers` |
| whitey returned `Permission denied` | `ha-metrics` missing mode 755 | `chmod 755` |
| Sentinel glob stayed literal | Globbing needs read, not just traverse, on intermediate directories | `setfacl -m u:hamon:rx` on the parent dirs |
| Card showed two stray lines of literal `type: markdown` / \`content: | \` text | The whole card YAML was pasted into the markdown card's **content textbox** instead of its **code editor**. It still rendered, because the template lines were indented only two spaces and markdown needs four for a code block, so Jinja ran anyway |
| `<ha-icon style="color: ...">` rendered as an uncolored glyph | HA's markdown card sanitizes inline `style` attributes | Colour in a markdown card must come from a Unicode glyph, not CSS. Used a green check and red cross glyph |
| \`grep \-nE '^(REPO | GIT\_DIR | ...)='`found nothing in`ha-config-commit\` and the run was silent |
| Sentinels one level deeper than assumed | Layout is `MyStash/<user>/<host>/`, not `MyStash/<host>/` | Collector glob `*/*/.last_backup` |
| Dashboard tables rendered as one line of pipes | `content: >-` folds newlines | Use `content: |` (literal block scalar) |
| Nodes gauge never green | `green: 4` equals `max: 4`, a zero-width band | `green: 3.5` |
| Developer Tools missing from the UI | Renamed and moved in HA 2026.8 | **Settings → Tools**; also `C` opens a command palette |
| `sudo: cannot execute ...: Permission denied (os error 13)` on a root-owned script | File was mode 644 — **no** execute bit. Root can read and write anything, but it will only execute a file if at least one execute bit is set. | `chmod 755` |
| Unfamiliar sudo error wording on whitey | Ubuntu 26.04 ships the Rust `sudo-rs` implementation, which reports errno differently (`os error 13`) than classic sudo | Cosmetic only; expect message text not to match older habits |
| `.cache/` brand icons and `.ha_run.lock` committed | Not in the initial `.gitignore` | Add `.cache/`, `*.lock`, `.ha_run.lock`; `git rm -r --cached` to untrack without deleting |
| Missing weekly snapshot — gap from Jul 17 to Jul 31 | **Lock collision.** Weekly ran Sunday 23:30 while the 00:00 daily was still going; a daily takes 60–70 min. Log: `ERROR: Lockfile /var/run/rsnapshot-lumpy.pid exists and so does its process` | Moved weekly to **Sunday 04:00**, clear of all three daily runs |
| `no_create_root 0` with an NFS snapshot root | If whitey or NFS is down, rsnapshot **creates** the root on lumpy's local disk and writes \~8.5 TB into 97.9 GB. Nearly fired 2026-07-27. | Set `no_create_root 1`. See §4a |
| Confusion over whether `/mnt/backup` was whitey's `/srv/media` | The `df` sizes matched, and this was **not** a coincidence — `/srv/MediaBkup` is a bind mount of the subdirectory `/srv/media/MediaBkup`, so it sits on the same 17 TB volume. A client's `df` over NFS reports the whole underlying filesystem. An earlier note in this runbook called it a coincidence; that was wrong. | See the storage topology in §4a. Whitey runs no rsnapshot of its own, so the feared `.sync` path collision never existed. **Use `stat -c '%d %i'` to tell a bind mount of a subdirectory from a second mount of the whole filesystem — same device, different inode means bind.** |
| A `hard` NFS mount can hang the collector | `df` on `/mnt/backup` blocks indefinitely when whitey is down → lumpy's sensor hits `command_timeout: 20` → total loss of lumpy visibility precisely when it is needed most | Wrapped `df` in `timeout 8` in `ha-metrics` on **all four** hosts |
| `log_errors` would have read non-zero forever | \`tail \-400 | grep \-c`counted July's failures plus benign rsync code 24`file(s) vanished\` warnings |
| Crontab pointed at `ha-rsnapshot-run`, which did not exist yet — 13 min before the 08:00 run | Config was changed ahead of the script it referenced | Reverted to direct `rsnapshot` calls. **Create and hand-test scripts before repointing cron.** |
| `sudo ls -l /root/.ssh/config*` reported "No such file or directory" while `cat` of the same file worked | The **glob is expanded by the unprivileged shell before `sudo` runs.** `jgordon` cannot read `/root/.ssh`, so the pattern matched nothing, was passed through literally, and root's `ls` looked for a file actually named `config*`. The file was fine and the backup had succeeded. | Let root do the expansion — \`sudo ls \-l /root/.ssh/ |
| Duplicated `Host larry` block in whitey's `/root/.ssh/config` (lines 1-5 and 6-10, identical) | SSH takes the first match and silently ignores the rest. With no `Host lumpy` entry present, the duplicate was almost certainly meant to be lumpy. | Deleted the duplicate, added `Host lumpy`, repointed `ha-config-commit` at the alias. Confirmed with `ssh -G`, which shows SSH's resolved configuration rather than the file's apparent contents. |
| `ssh jgordon@lumpy 'sudo -u hamon ...'` failed | `sudo: a terminal is required to read the password` — no `-t` | Verify in **Settings → Tools → States** instead; HA connects as `hamon` over its own key with no sudo anyway |
| New dashboard card rendered as an empty box, no error shown | Template raised `TemplateSyntaxError: unexpected char "'"` from quoted strings inside `namespace` list building, after the editor round-tripped the YAML. The dashboard swallows template errors. | Rewrote using one boolean plus plain `{% if %}` blocks, double quotes, ASCII only. Diagnose via the **Manual card** preview, which does show the error |
| `TemplateAssertionError: No filter named 'type_debug'` | Filter not present in HA 2026.8 | Use `is none` / \`keys() |
| `E33: No previous substitute regular expression` in vim | Used \` | `as the`:s`separator. Vim reserves` |
| Bogus-interval wrapper test wrote an `ERROR:` line to the rsnapshot log | rsnapshot checks its **lockfile before validating the interval name**, so with a run in progress the test fails on the lock, not on the bad argument | Harmless — `log_errors` resets on the next `completed successfully`. Clear the synthetic `rsnapshot-lastrun` afterwards so no fake failure shows on the dashboard |
| Mosquitto restart-looped, `Error: Unable to open pwfile` | `password_file` pointed at a `passwd` that did not exist yet, so the broker exited on every start — and a looping container cannot be `docker exec`ed, which is how the password file is normally created | Create the password file first with a throwaway `--rm` container mounting the same config directory. See §4c |
| `mosquitto_passwd` warns "owner is not root. Future versions will refuse to load this file" | **The warning is wrong inside Docker.** The broker drops to uid 1883 before reading the password file, so a root-owned `600` file is unreadable, and the image entrypoint chowns `/mosquitto` back to `1883:1883` on every start anyway | Ignore it. Following its advice produces a restart loop. Correct state is `1883:1883` mode `600` |
| Frigate logged `Unable to connect to MQTT server: MQTT Not authorized` in a widening retry loop, while `hass` authenticated fine | Only the `hass` password had been reset to a real value; broker user `frigate` still held the placeholder string from the setup command | Reset the `frigate` hash to the exact value the container holds, then `SIGHUP`. Read the value from the container rather than retyping it: `docker exec frigate printenv FRIGATE_MQTT_PASSWORD` |
| Suspected a mangled password — quotes or `\r` baked into the value | Ruled out with `printenv … | od -c`: the trailing `\n` is `printenv`'s own terminator and `0000014` is od's byte offset, not data. Worth knowing because Compose `env_file` parsing does keep surrounding quotes in some versions | Compare byte-for-byte before assuming the value is bad; the mismatch was on the broker side |
| `mosquitto_sub: command not found` on whitey | The clients are not installed on the host — only inside the container image | Run them from the image with `docker run --rm --network host eclipse-mosquitto:2 mosquitto_sub …`. Avoids installing `mosquitto-clients` and any chance of a second broker on the host |
| Searching "frigate" returned "No integrations found" | The search box on the **HACS entry page** under Settings → Devices & Services filters HACS's own config entries, not the HACS store | Browse from the **HACS panel in the sidebar** (or `/hacs` directly) |
| Frigate absent from the Add Integration list after downloading it | HACS only copies code into `custom_components/`; it configures nothing | Restart Home Assistant, then add the integration |

---

## 10\. Open items

1. **Verify the first auto-commit run** fired at 04:45 and pushed.  
2. **Confirm the first wrapped run** (16:00, 2026-08-21) populates `last_run_rc`, `last_run_seconds`, and `last_run_age_hours` with real values, then decide how the card should treat **rc 2** — see the exit-code note in §4a.  
3. **Verify `rsync_long_args` are actually applied.** The config specifies `--delete --numeric-ids --relative --delete-excluded`, but the log shows only `-a --delete`. Either the log is abbreviating or the directive is being ignored — `--relative` in particular changes the on-disk layout.  
4. **Fix the auto-commit subject-line truncation** so the git log names every changed file.  
5. **Notifications.** The Attention card logic should become automations that push on node-unreachable (10+ min), stale backup, degraded RAID, stopped container, and filesystem over 85%. Local push via the companion app works without internet.  
6. **~~VPN egress verification on uther.~~** **Done 2026-08-24** — see §4b. Implemented as a standalone read-only `ha-vpn-state` collector on its own timer, *not* by extending `pia-refresh-wireguard` as originally planned: that script is a remediator and observation must not be able to trigger remediation. Remaining follow-ups: require a bad state to persist across two samples before alerting (see the PIA-refresh overlap note in §4b), and decide what to do about the deliberate DNS asymmetry.  
7. **Offsite backup strategy.** Broader household decision; see §3.  
8. **Add an HA sentinel to uther's backup freshness checker** so HA backups are watched from outside whitey too.  
9. **AsusWRT integration** for gilbert — WAN state, client list, presence.  
10. **Distinguish host-down from SSH-broken** with a ping check per node.  
11. **ratgdo32 purchase and install** — needs the opener learn-button colour.  
12. **Brewing and cooking telemetry** — Tilt and Meater need a BLE path.  
13. **Internet connectivity block in `ha-metrics` on all four hosts.** Designed but not built. Three layers, each `timeout`\-wrapped: gateway `192.168.86.1`; transit by IP literal (`1.1.1.1`, `9.9.9.9`, plus a TCP 443 fallback because ICMP may be filtered); and name resolution tested *separately*, because whitey **is** the resolver and a naive combined check would blame the internet for an unbound failure. `ha-vpn-state` already implements this pattern for uther and can be lifted from it.  
14. **Finish the Frigate surface.** Add `media_source:` for the Media Browser, install Advanced Camera Card for scrubbable live views, and import the Frigate notification blueprint. Item 5 above now has a working event source for camera alerts.  
15. **Decide on broker transport security.** 1883 is cleartext on the LAN by design — both clients are wired hosts on the same segment and TLS would add certificate lifecycle to a path that currently has none. Revisit if any wireless or off-segment client (a BLE proxy, an ESPHome node) starts publishing.  
16. **Confirm the Mosquitto password file is recoverable, not backed up.** It is deliberately gitignored and lives outside `/config`, so no backup covers it. That is acceptable only while both broker passwords are in 1Password — verify they are, and that §4c's two-command rebuild is accurate.

---

## 11\. Reference

- [HA 2026.8 release notes](https://www.home-assistant.io/blog/2026/08/05/release-20268/)  
- [HA installation methods](https://www.home-assistant.io/installation/)  
- [Tools (formerly Developer Tools)](https://www.home-assistant.io/docs/tools/dev-tools/)  
- [HTTP integration / trusted proxies](https://www.home-assistant.io/integrations/http/)  
- [Backup integration](https://www.home-assistant.io/integrations/backup/)  
- [MyQ removal notice](https://www.home-assistant.io/integrations/myq/)  
- [Rain Bird integration](https://www.home-assistant.io/integrations/rainbird/)  
- [Enphase Envoy integration](https://www.home-assistant.io/integrations/enphase_envoy/)  
- [ratgdo features matrix](https://ratcloud.llc/pages/features)  
- [ratgdo ordering and opener compatibility](https://paulwieland.github.io/ratgdo/)  
- [rsnapshot FAQ](http://rsnapshot.org/faq.html) — `no_create_root` and remote roots  
- [rsnapshot man page](https://linux.die.net/man/1/rsnapshot)  
- [Markdown card](https://www.home-assistant.io/dashboards/markdown/)  
- [Command line integration](https://www.home-assistant.io/integrations/command_line/)  
- [Frigate Home Assistant integration docs](https://docs.frigate.video/integrations/home-assistant/) — MQTT prerequisite, port 5000 vs 8971, self-signed TLS  
- [frigate-hass-integration repo](https://github.com/blakeblackshear/frigate-hass-integration) — install path and entity list  
- [HA MQTT integration](https://www.home-assistant.io/integrations/mqtt/)  
- [eclipse-mosquitto image](https://hub.docker.com/_/eclipse-mosquitto)  
- [mosquitto issue \#3284](https://github.com/eclipse-mosquitto/mosquitto/issues/3284) — the misleading root-ownership warning in Docker  
- [mosquitto issue \#2923](https://github.com/eclipse-mosquitto/mosquitto/issues/2923) — entrypoint chowns `/mosquitto` on every start

