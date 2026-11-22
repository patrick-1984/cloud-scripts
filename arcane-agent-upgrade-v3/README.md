# Arcane upgrade to v2 to v3: manager backup and agent upgrade

> [!WARNING]
> **You need root SSH access to every host you update: the Arcane manager host and each agent
> host. These scripts stop, recreate and back up Docker containers. Read them before you run
> them, and use them at your own risk: you are responsible for your systems and your data.**
>
> **Keep your backups.** Arcane v3 changes the database and the configuration. Do not count on
> going back to an older version.

An Arcane v3 manager does not accept 2.x agents ("The Manager, every agent, and `arcane-cli`
must all run 3.0": [Migrate to v3](https://getarcane.app/docs/get-started/migrate-v3.html)).
After the manager is upgraded, every agent shows **offline** until it runs v3 too.

Two scripts:

| Script | Run it on | What it does |
|---|---|---|
| `backup-arcane-manager.sh` | the Arcane manager host | Backs up the manager container: its data (database, `/app/data`, projects), its compose files and its `docker inspect` |
| `upgrade-arcane-agent.sh` | each agent host | Recreates a 2.x edge agent container as `ghcr.io/getarcaneapp/agent:v3`, keeping its token and data |

## Upgrade procedure

1. **Back up the manager.** Log in to the manager host over SSH as root and run:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/patrick-1984/cloud-scripts/main/arcane-agent-upgrade-v3/backup-arcane-manager.sh | bash
   ```

   The manager is stopped for the copy and started again afterwards. Copy the backup folder it
   prints (`$HOME/arcane-manager-backup.<time>.XXXXXX`) off the host. **It contains secrets**
   (the container's environment, the database).

2. **Upgrade the manager to v3** by following the official
   [Migrate to v3](https://getarcane.app/docs/get-started/migrate-v3.html) guide. Key points from it:
   - the image becomes `ghcr.io/getarcaneapp/manager:v3`;
   - Arcane's own variables now start with `ARCANE_`, and the manager log names any variable still
     to rename;
   - a database from before 2.17.1 is refused (`upgrade to Arcane v2.17.1 first`): run 2.17.3 once
     before going to v3.

3. **Upgrade each agent.** Log in to each agent host over SSH as root and run:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/patrick-1984/cloud-scripts/main/arcane-agent-upgrade-v3/upgrade-arcane-agent.sh | bash
   ```

4. **Check** that every host shows **Online** in Arcane under **Agents**.

Without `curl`, use `wget -qO- URL | bash`. Options go after `bash -s --`, for example
`... | bash -s -- my-agent-container -y`.

## `backup-arcane-manager.sh`

```
... | bash -s -- [NAME] [-y] [--no-stop]
```

- `NAME`: the manager container. Without it, the script finds the single container whose
  configured image is `getarcaneapp/arcane` or `getarcaneapp/manager`.
- `-y`: skip the confirmation prompt. Without it, the script asks on the terminal before changing anything.
- `--no-stop`: copy while the manager runs. There is no downtime, but the SQLite database may be inconsistent.
- `BACKUP_DIR`: where the backup folder goes (default `$HOME`).

What it saves, in a new private folder (mode 700):
- `inspect.json`: the full container configuration (image, environment, mounts, labels);
- `N.tar.gz` + `N.path`: one archive per data mount (bind mount or volume), made with `docker cp`.
  If `/app/data` has no volume, the archive is taken from inside the container;
- `compose.tar.gz`: the compose file(s) and `.env` the container was started from, if it was
  started with `docker compose`;
- `SHA256SUMS`.

If the database is PostgreSQL (`DATABASE_URL=postgres...`), the script says so. Dump that database
separately with `pg_dump`. If anything fails after the manager was stopped, the script starts it again.

## `upgrade-arcane-agent.sh`

```
... | bash -s -- [NAME] [-y]
```

- `NAME`: the agent container. Without it, the script finds it by its configured image
  (`getarcaneapp/agent` or `arcane-headless`) or its agent variables. `docker ps` can show only an
  image ID once `:latest` has moved to v3, so the script does not rely on it.
- `-y`: skip the confirmation prompt.
- Environment: `IMAGE` (default `ghcr.io/getarcaneapp/agent:v3`), `BRIDGE_IMAGE`
  (default `ghcr.io/getarcaneapp/agent:v2.17.3`), `BACKUP_DIR` (default `$HOME`),
  `DATA_HOST_DIR_OVERRIDE`.

What it does:

1. Reads the old container's token, manager URL, mounts, extra hosts, network and restart policy
   with `docker inspect`. You do not need to know the token.
2. Builds the v3 settings from an explicit allowlist. v3 refuses to start on any legacy variable
   ("legacy environment variables are no longer read"):

   | 2.x | 3.x |
   |---|---|
   | `EDGE_AGENT` | `ARCANE_AGENT=true` (always set) |
   | `MANAGER_API_URL` | `ARCANE_MANAGER_API_URL` |
   | `AGENT_TOKEN` | `ARCANE_AGENT_TOKEN` |
   | `EDGE_*` (reconnect, mTLS) | `ARCANE_AGENT_*` |
   | `EDGE_TRANSPORT=poll` | `ARCANE_AGENT_TRANSPORT=auto` (the poll transport was removed) |
   | `ANALYTICS_DISABLED=true` | `ARCANE_ANALYTICS_ENABLED=false` (inverted) |
   | `DATABASE_URL`, `ENCRYPTION_KEY`, `PROJECTS_DIRECTORY` | `ARCANE_` prefix |
   | `PUID`, `PGID`, `TZ`, `DOCKER_*`, proxy variables, `OTEL_*` | unchanged |
   | `AGENT_MODE`, `ENVIRONMENT`, `PORT`, `GIN_MODE`, `PATH`, other image defaults | dropped |

3. Finds where the agent keeps its data (`/app/data`, or the directory of `DATABASE_URL`) and
   reports where that is on the host: a **host folder** (bind mount), a **named volume** or an
   **anonymous volume**. If the data has **no volume at all**, it copies the data to
   `/opt/arcane-agent/NAME` and mounts that folder into the new container, so the agent does not
   start unpaired.
4. Shows the new `docker run` command (secrets masked) and asks for confirmation.
5. Pulls v3, stops the old container, backs up its data with `docker cp` to
   `BACKUP_DIR/NAME.<time>.XXXXXX/`, and renames the old container to `NAME-old` (kept, not deleted).
6. Starts v3 and watches it for 45 s. It counts as up only with no restarts and no fatal log lines.
   If v3 refuses the agent database (`upgrade to Arcane v2.17.1 first`), it runs v2.17.3 once on
   the same data, then starts v3 again.
7. If v3 does not come up, the script prints the reason from the log (for example
   `replace X with Y`) and the failing command, and starts the original container again.

Running it again is safe. If the new agent is healthy, it changes nothing. If an earlier run left a
failed v3 container next to `NAME-old`, it removes the failed one and retries with the settings of
`NAME-old`.

When the host shows **Online** in Arcane, remove the old container: `docker rm NAME-old`.

If the old container has no `AGENT_TOKEN`, the script stops without changing anything. In Arcane,
open **Agents → the host → Connection & Agent → Generate Enrollment Token** and run the install
command it shows.
