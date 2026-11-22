# cloud-scripts

Small, self-contained helper scripts for self-hosted infrastructure. Each folder has its own README
with a one-liner that runs the script straight from this repository.

> [!WARNING]
> **You need root SSH access to the host you run these scripts on. They stop, recreate and
> back up Docker containers. Read a script before you run it, and use it at your own risk:
> you are responsible for your systems and your data.**

| Folder | What it does |
|---|---|
| [`arcane-agent-upgrade-v3`](arcane-agent-upgrade-v3/) | Upgrade [Arcane](https://getarcane.app) to v3: back up the Arcane manager, then upgrade each 2.x agent container to a v3 agent |
