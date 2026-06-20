# Claude Code + Windscribe VPN — Isolated Dev Container

Isolated Docker environment for Claude Code where **all internet traffic is
routed through Windscribe VPN** running inside the container.
Your host machine never sees Claude Code's outbound traffic.
Your Java project is bind-mounted so IntelliJ sees every change instantly, and
the container can still reach databases/brokers you run in Docker **on the host**.

```
Host OS  (IntelliJ watches your project; Postgres/Kafka run in Docker)
  │
  ├── Postgres / Kafka / …  (host Docker, ports published to the host)
  │        ▲  reached via host.docker.internal (local-only, never leaves host)
  │        │
  └── Docker container "claude-vpn"
        ├── OpenVPN → Windscribe exit node   (all Claude Code API traffic)
        ├── iptables kill switch (IPv4+IPv6)  (blocks any non-VPN outbound,
        │                                       except the local Docker subnet)
        ├── Claude Code                       (runs as non-root user "dev")
        └── /workspace  ←→  your project       (bind mount, zero delay)
```

The kill switch blocks all outbound except the VPN tunnel **and** the local
Docker subnet / host gateway. That host-local exception lets the app talk to
your host-run Postgres/Kafka; it stays on the Docker host and never reaches the
public internet, so it does not leak your real IP.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Docker Engine ≥ 24 | or Docker Desktop |
| Linux / macOS / Windows (WSL2) host | all supported; see platform notes below |
| Windscribe account | free tier is enough |
| Claude subscription (Pro or Max) | auth uses a subscription token, **not** an API key |

---

## One-time setup

### Step 1 — Download the Windscribe OpenVPN config

1. Log in to **windscribe.com**
2. Go to **My Account → OpenVPN Config Generator**
3. Select a server close to you (e.g. `DE-Frankfurt` or any EU server)
4. Choose protocol **UDP** (faster) or **TCP** (more firewall-friendly)
5. Download the `.ovpn` file
6. Copy it into this repo's `vpn/` folder:

```bash
cp ~/Downloads/Windscribe-DE-Frankfurt.ovpn ./vpn/windscribe.ovpn
```

### Step 2 — Create the VPN credentials file

```bash
cp vpn/credentials.txt.example vpn/credentials.txt
nano vpn/credentials.txt
# Line 1: your Windscribe username
# Line 2: your Windscribe password
```

> Windscribe's OpenVPN configs contain `auth-user-pass`; the entrypoint passes
> `credentials.txt` automatically.

### Step 3 — Create your `.env` file

```bash
cp .env.example .env
nano .env
```

Fill in:

- `CLAUDE_CODE_OAUTH_TOKEN` — long-lived subscription token (see Step 4)
- `PROJECT_PATH` — absolute path to your Java project on the host
- `M2_REPO_PATH` — absolute path to your Maven `.m2` repo on the host
- *(optional)* Spring overrides for host services — see
  [Connecting to host services](#connecting-to-host-services-postgres--kafka)

### Step 4 — Generate the auth token

Authentication uses a **long-lived OAuth token** from `claude setup-token`
(valid ~1 year, tied to your subscription). This is what stops Claude from
asking you to log in on every connect — an interactive `/login` only mints a
short-lived token that expires within hours.

If you have Claude Code installed on your **host**, just run:

```bash
claude setup-token
```

Otherwise generate it **inside the container** after the first `up` (Step 5):

```bash
docker exec -it -u dev claude-vpn claude setup-token
```

Either way, copy the printed `sk-ant-oat01-...` token into `.env`:

```
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
```

> Do **not** also set `ANTHROPIC_API_KEY` — if present it takes precedence over
> the subscription token and can cause auth failures.

### Step 5 — Build and start

```bash
docker compose build
docker compose up -d
```

The build takes 2–3 minutes the first time (Node.js, Claude Code, JDK, Maven).

> **Pin the Claude Code version** for reproducible builds:
> `docker compose build --build-arg CLAUDE_CODE_VERSION=2.1.170`
> (Default is `latest`. The image disables the background auto-updater, so you
> update deliberately by rebuilding — no mid-session drift.)

If you generated the token inside the container (Step 4), recreate it now so it
picks up the value you saved in `.env`:

```bash
docker compose up -d --force-recreate
```

---

## Daily workflow

### Start the container (once per workday)

```bash
docker compose up -d
```

The container will:

1. Resolve the Windscribe server hostname (all resolved IPs are allowed)
2. Install the IPv4 **and** IPv6 kill switch (all outbound blocked except VPN)
3. Start OpenVPN and wait for `tun0`
4. Allow `tun0` traffic
5. Open the local Docker subnet + host gateway (for host services)
6. Verify the external IP
7. Stay alive (sleeping) — ready for you to exec in

Watch startup:

```bash
docker logs -f claude-vpn
```

Expected output:

```
[VPN] VPN server: fra-xxx.windscribe.com → [185.x.x.x] :443/udp
[VPN] Installing iptables kill switch (IPv4)...
[VPN] Allowed VPN endpoint 185.x.x.x:443/udp
[VPN] Installing kill switch (IPv6 — full block)...
[VPN] Kill switch active — all other outbound is blocked
[VPN] Launching OpenVPN...
[VPN] Waiting for tunnel interface tun0 (timeout: 90s)...
[VPN] tun0 is up after 12s ✓
[VPN] tun0 outbound traffic allowed
[VPN] Allowed local Docker subnet 172.x.x.x/16 (host services)
[VPN] Allowed host gateway 192.168.65.254 (host.docker.internal)
[VPN] External IP: 185.x.x.x  ← should be a Windscribe exit node
[VPN] VPN is active.  Workspace: /workspace
```

Check health at a glance (the image flips to `unhealthy` if `tun0` drops):

```bash
docker ps   # STATUS column shows (healthy) / (unhealthy) / (health: starting)
```

### Open a Claude Code session

```bash
# Helper script (easiest)
#   Linux/macOS/Git Bash:
chmod +x cc.sh
./cc.sh
#   Windows PowerShell:
./cc.ps1

# Or directly:
docker exec -it -u dev -w /workspace claude-vpn claude
```

Claude Code opens in `/workspace`, which is your host project.
**IntelliJ sees all file changes immediately** — same filesystem path, no sync layer.

The helper scripts also warn you if the container is up but `unhealthy`
(VPN down), since Claude Code would otherwise just fail to reach the API.

### IntelliJ tip — enable auto-refresh

`Settings → Appearance & Behavior → System Settings`
☑ **Synchronize external changes on frame or editor tab activation**
(or press `Ctrl+Alt+Y` to refresh manually)

### Stop the container

```bash
docker compose down
```

---

## Authentication & session persistence

- **No repeated logins.** The `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`
  is long-lived, so Claude authenticates non-interactively every connect.
- **Sessions persist.** All Claude Code state (config, credentials, history,
  and `projects/` sessions) lives in `CLAUDE_CONFIG_DIR=/home/dev/.claude-state`,
  backed by the named volume `claude-state`. It survives restarts, so `/resume`
  keeps working across container recreations.
- On first interactive launch Claude may still show the login picker / a
  "trust this directory" prompt once — that's expected; the token is used after.

---

## Connecting to host services (Postgres / Kafka)

Your `application.yml` keeps its `localhost:*` URLs so **IntelliJ on the host
keeps working unchanged**. Inside the container, `localhost` is the container
itself, so the compose file overrides the relevant Spring properties via
environment variables (Spring's relaxed binding) to point at
`host.docker.internal` instead:

```yaml
environment:
  - SPRING_DATASOURCE_URL=jdbc:postgresql://host.docker.internal:5432/subo
  - SPRING_DATASOURCE_USERNAME=postgres
  - SPRING_DATASOURCE_PASSWORD=postgres
  - SPRING_KAFKA_BOOTSTRAP_SERVERS=host.docker.internal:9092
```

These apply only inside the container; the host keeps using `localhost`.

Requirements:

- The host services must publish their ports (e.g. `-p 5432:5432`) so they're
  reachable on the host gateway.
- Postgres must listen on `0.0.0.0` and allow the Docker subnet in `pg_hba.conf`.
- **Kafka caveat:** Kafka hands clients its `advertised.listeners`. If host Kafka
  advertises `localhost:9092`, the container connects, then gets bounced to
  `localhost:9092` and fails. Configure host Kafka to advertise an address the
  container can reach (e.g. `host.docker.internal:9092`).

Quick reachability check (uses bash's built-in `/dev/tcp`, no `nc` needed):

```bash
docker exec -u dev claude-vpn bash -c '
for p in 5432 9092; do
  timeout 3 bash -c "exec 3<>/dev/tcp/host.docker.internal/$p" 2>/dev/null \
    && echo "port $p OPEN" || echo "port $p CLOSED/blocked"
done'
```

---

## Verifying isolation

```bash
# 1. Container traffic exits via the VPN
docker exec claude-vpn curl -s https://ifconfig.me
# → a Windscribe IP, not your home IP

# 2. Kill switch is active
docker exec claude-vpn iptables -S OUTPUT
# → policy DROP, with rules for lo, ESTABLISHED/RELATED, the VPN endpoint,
#   tun0, the local Docker subnet, and the host gateway

# 3. Host outbound is unaffected
curl https://ifconfig.me   # on your host — shows your real IP
```

---

## Troubleshooting

### `tun0 did not appear within 90s`

- Check `docker logs claude-vpn` for OpenVPN errors.
- Try TCP in the `.ovpn`: change `proto udp` → `proto tcp`.
- Ensure `/dev/net/tun` exists on the host: `ls -la /dev/net/tun`.

### `AUTH_FAILED` in the OpenVPN log

- Wrong Windscribe credentials in `vpn/credentials.txt`.
- If the `.ovpn` already embeds credentials, remove its `auth-user-pass` line.

### Claude Code asks me to log in every time

- Make sure `CLAUDE_CODE_OAUTH_TOKEN` in `.env` is set to a `claude setup-token`
  value (not blank), then `docker compose up -d --force-recreate`.
- Confirm it's present: `docker exec claude-vpn env | grep CLAUDE_CODE_OAUTH_TOKEN`.
- Ensure `ANTHROPIC_API_KEY` is **not** set anywhere (it overrides the token).

### App can't reach Postgres/Kafka

- Verify the firewall rule landed: `docker exec claude-vpn iptables -S OUTPUT | grep -E 'eth0|host'`.
- Run the `/dev/tcp` reachability check above.
- If Postgres connects but Kafka errors *after* connecting, it's the
  advertised-listeners issue — fix on the host Kafka side.

### Changes not appearing in IntelliJ

- Shouldn't happen with bind mounts. On WSL2/Windows, confirm `PROJECT_PATH`
  is correct (see platform notes) and try `Ctrl+Alt+Y`.

### Container shows `unhealthy`

- The `tun0` interface is gone — the VPN dropped. Check `docker logs claude-vpn`;
  the kill switch means Claude Code has no internet until the tunnel is back.

---

## Updating Claude Code

The in-container background auto-updater is disabled (the global npm install is
root-owned but Claude runs as `dev`, so self-update can't write and would nag).
Update by rebuilding:

```bash
docker compose build --build-arg CLAUDE_CODE_VERSION=latest   # or a pinned version
docker compose up -d --force-recreate
```

Check the running version: `docker exec -u dev claude-vpn claude --version`.

---

## Platform notes

**Linux:** bind mounts are native; nothing special needed.

**macOS (Docker Desktop):** uses a VM; bind mounts via `virtiofs` are fast
enough. Use a macOS absolute path: `PROJECT_PATH=/Users/yourname/projects/...`.
`host.docker.internal` resolves automatically.

**Windows (Docker Desktop + WSL2):** Windows paths with forward slashes work in
`.env` (e.g. `PROJECT_PATH=C:/Users/you/IdeaProjects/subo`). For best Maven
performance, keeping the repo inside the WSL2 filesystem and opening it in
IntelliJ via the WSL target is significantly faster than a path on `C:`.
`host.docker.internal` resolves automatically (to a gateway like
`192.168.65.254`, which is why the entrypoint allows it explicitly).

---

## Security notes

- `vpn/credentials.txt`, `vpn/*.ovpn`, and `.env` are in `.gitignore`.
- Auth uses a subscription **token** in `.env`, never baked into the image.
- Claude Code runs as the non-root user `dev`.
- The kill switch covers **IPv4 and IPv6**: if the VPN drops, Claude Code loses
  internet entirely rather than falling back to your host IP. The only
  exception is local Docker-host traffic (your DB/Kafka), which never leaves
  the host.
