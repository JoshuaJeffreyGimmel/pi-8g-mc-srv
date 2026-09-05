# Minecraft Server — Raspberry Pi 5

Paper (or NeoForge) Minecraft server running in Docker on a Raspberry Pi 5 (8GB,
active cooler, NVMe SSD), reachable over Tailscale instead of port forwarding.

Deliberately minimal: no web panel, no extra containers. Admin is CLI-only over
SSH, which keeps RAM free for the JVM.

---

## Setup

### 1. Prerequisites on the Pi

```bash
# Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"   # log out and back in after this

# Tailscale
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

### 2. Clone and configure

```bash
git clone <your-repo-url> minecraft-pi
cd minecraft-pi

cp .env.example .env
nano .env            # set RCON_PASSWORD at minimum

chmod +x mc scripts/backup.sh
```

### 3. Start

```bash
./mc up
./mc logs            # wait for: Done (XX.XXXs)! For help, type "help"
```

First boot downloads the server jar and generates the world. **Let it finish.**
Interrupting world generation leaves a truncated `level.dat` and the server will
crash-loop on every subsequent start with `No key dimensions in MapLike[{}]`.
If that happens, see Troubleshooting below.

### 4. Whitelist yourself

```bash
./mc whitelist YourMinecraftName
```

---

## Connecting

Find the Pi's Tailscale address:

```bash
tailscale ip -4          # e.g. 100.101.102.103
tailscale status         # shows the MagicDNS name
```

In the Minecraft client, the server address is:

```
raspberrypi.your-tailnet.ts.net:25565     # with MagicDNS
100.101.102.103:25565                     # raw Tailscale IP
```

Players need the Tailscale client installed and your share invite accepted
before this resolves — the address is not routable off your tailnet.

---

## Tailscale access control

Sharing a device grants access to **every port on that machine** by default.
Restrict shared users to the game port only.

Tag the Pi (admin console → Machines → the Pi → Edit ACL tags → `tag:mcserver`),
then in **Access Controls**:

```jsonc
{
  "tagOwners": {
    "tag:mcserver": ["autogroup:admin"],
  },
  "grants": [
    // Shared users: Minecraft port only. No SSH, no other services.
    {
      "src": ["autogroup:shared"],
      "dst": ["tag:mcserver"],
      "ip":  ["25565"],
    },
    // You: full access for administration.
    {
      "src": ["autogroup:member"],
      "dst": ["tag:mcserver"],
      "ip":  ["*"],
    },
  ],
}
```

Verify from a shared account that port 22 is refused and 25565 works.

---

## Administration

All admin runs over SSH to the Pi. There is no SSH server inside the container —
Docker's `exec` is the way in.

```bash
ssh joshua@<pi-tailscale-ip>
cd minecraft-pi
```

| Task | Command |
|---|---|
| Start | `./mc up` |
| Stop (graceful) | `./mc down` |
| Restart | `./mc restart` |
| Follow logs | `./mc logs` |
| Container status | `./mc status` |
| Interactive console | `./mc console` |
| One-off command | `./mc cmd say Hello` |
| Who's online | `./mc players` |
| Add to whitelist | `./mc whitelist <player>` |
| Remove from whitelist | `./mc unwhitelist <player>` |
| Back up the world | `./mc backup` |
| Shell in container | `./mc shell` |

Inside `./mc console`, the usual server commands work: `kick`, `ban`, `ban-ip`,
`pardon`, `op`, `deop`, `list`, `say`, `difficulty`, `save-all`, `stop`.
Exit with `quit`.

### Config changes

Most settings are environment variables — edit `docker-compose.yml` or `.env`,
then `./mc restart`.

Anything not exposed as a variable (specific `server.properties` keys, plugin
configs, datapacks) lives in `./data/` on the host. Edit directly, then restart.

---

## Backups

`./mc backup` flushes the world via RCON before archiving, so the tarball is
consistent rather than a snapshot of a half-written region file.

Automate it:

```bash
crontab -e
# Daily at 04:00
0 4 * * * /home/joshua/minecraft-pi/scripts/backup.sh >> /home/joshua/minecraft-pi/backups/backup.log 2>&1
```

Backups older than 7 days are pruned automatically (`KEEP_DAYS` in the script).
`backups/` is gitignored — copy them off the Pi periodically if the world matters.

---

## Tuning notes

**Memory.** `MEMORY` sets the Java *heap* only. Non-heap usage (metaspace,
thread stacks, Netty off-heap buffers, GC structures) adds roughly 25% on top.
On an 8GB Pi, a 6G heap means ~7.5G of real process memory and leaves nothing
for the OS — start at `4G` and raise only if you see GC pressure.

**Autopause.** `ENABLE_AUTOPAUSE` freezes the JVM when nobody is online.
`MAX_TICK_TIME: "-1"` must be set alongside it, otherwise the server Watchdog
interprets the resume as a hung tick and force-restarts the server.

While paused, RCON is unresponsive too — the whole Java process is suspended.
That is expected, not a fault.

**Version pinning.** `VERSION` is pinned deliberately. Left at `LATEST`, the
image auto-upgrades on restart, which will break plugins and mods.

**CPU limit.** `cpus: "3.5"` of 4 cores leaves headroom for the OS, Docker and
`tailscaled` so the JVM cannot starve them under load. Confirm it applied with
`docker inspect mc | grep -i nanocpus`.

---

## Expected capacity

Rough figures for a Pi 5 (8GB, SSD, active cooling), view/simulation distance 8:

| Setup | Realistic players |
|---|---|
| Paper, vanilla gameplay | 5–10 comfortably |
| Paper, light plugins | 5–8 |
| NeoForge, ~30–50 mod curated pack | 2–4 |
| Large kitchen-sink pack (ATM-scale) | not viable — wants 8–12G heap alone |

CPU saturates before RAM does. Watch with `docker stats` — sustained ~400%
(all four cores) means you are CPU-bound, and lowering simulation distance helps
more than adding heap.

---

## Switching to mods

Mods pin the Minecraft version, so choose the pack first and set `VERSION` to
match — not the other way around.

In `.env`:

```
MC_TYPE=NEOFORGE
MC_VERSION=1.21.1
```

Optionally pin the loader in `docker-compose.yml`:

```yaml
NEOFORGE_VERSION: "21.1.72"
```

Then `./mc down`, move `data/` aside (mods usually need a fresh world), and
`./mc up`. Expect a much longer first boot.

---

## Troubleshooting

**`No such container: mc`** — not running, or a different name. Check with
`docker ps`. Compose names containers `<folder>-<service>-1` unless
`container_name` is set, which it is here.

**`Failed to connect to RCON: connection refused`** — the server has not
finished starting, or it is crash-looping, or autopause has it suspended. Check
`./mc status` and `./mc logs`.

**Crash loop with `No key dimensions in MapLike[{}]`** — corrupted `level.dat`,
usually from interrupting first-time world generation. `restart: unless-stopped`
makes this look like repeated identical failures in the logs. If the world is
expendable:

```bash
./mc down
rm -rf data
./mc up
```

Otherwise restore from `backups/`.

**Server restarts itself after someone joins** — autopause resuming without
`MAX_TICK_TIME: "-1"`. Add it.

**Debugging a failing start** — run `docker compose up` without `-d` so it fails
once in the foreground instead of looping.
