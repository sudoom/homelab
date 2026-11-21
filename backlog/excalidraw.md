# Self-hosted Excalidraw with server-side storage

Candidate comparison and shape for a persistent Excalidraw on the cluster; not built. The README TODO keeps a short summary of the item and links here.

**The trap to avoid:** the plain `excalidraw/excalidraw` image is *static files only* — every scene sits in browser `localStorage`, so there is no server store, no share links, no collaboration, and clearing site data loses the lot. A real backend is the whole point of the task.

**Leading candidate (revised 2026-08-25): [`ZimengXiong/ExcaliDash`](https://github.com/ZimengXiong/ExcaliDash)** — a dashboard/organizer *on top of* Excalidraw (not a fork), with a real Node backend, Prisma ORM, WebSocket live collaboration, optional **OIDC** sign-in + admin dashboard for multi-user, and — the part that matters most — **drawings stored in plain `.excalidraw` format**, explicitly non-proprietary, so there is a clean exit. ~1.5k stars, 188 commits, actively maintained.

**Why it beats the previous pick for THIS cluster: it wants PostgreSQL in production, and we already run CNPG** (`components/apps/cnpg-clusters/`) with the **barman-cloud plugin shipping offsite backups to Cloudflare R2** and a *passing* restore drill (2026-07-06). So its data protection comes free from an existing, proven path — whereas the previous leader's S3 mode would have pointed at the in-cluster RGW, which is **not offsite** and shares the HDD OSDs. That flips the storage argument entirely.

**Caveat, weigh it honestly:** ExcaliDash self-describes as **BETA** ("Please backup your data regularly") with 45 open issues, and ships docker-compose as its primary deployment — so it needs translating to a chart, and the BETA label is exactly why the CNPG+R2 backing matters rather than being a nice-to-have.

**Previous leading candidate, kept for comparison:** [`PatWie/excalidraw-complete`](https://github.com/PatWie/excalidraw-complete) — single Go binary, `STORAGE_TYPE` = `filesystem`|`sqlite`|`s3`, :3002. Simpler (one binary, no DB) but no auth/multi-user, and **verify maintenance before adopting** — the author may have moved to `drafft-ink` (Rust/WebGPU). `excalidraw/excalidraw` + `kiliandeca/excalidraw-storage-backend` as two deployments; **skip** `Someone0nEarth/excalidraw-self-hosted` (docker-compose + MongoDB — a new stateful dependency for no gain).

**Not a replacement for the Obsidian Excalidraw plugin** (vault already has it + one drawing in `Excalidraw/`) — that stays the authoring path for notes; this covers shareable/persistent boards and anything collaborative.

**Shape:** `components/apps/excalidash/` + a CNPG `Cluster` following the `media-postgres`/`immich-postgres` precedent (including the `plugins:` wiring for R2 and the **`serverName` in `Cluster.spec.plugins[].parameters`**, plus **NO `data.compression`** — see the R2 `InvalidPart` trap in CLAUDE.md), edge-TLS Route at `excalidash.apps.okd.sudops.pl`, restricted-v2 securityContext. OIDC against the cluster's own OAuth is worth evaluating but is not required for v1.

**Validate:** draw something → reload in a private window and confirm it persisted → confirm rows landed in the CNPG DB → confirm a WAL archive reached R2 (`ContinuousArchiving=True` on the new cluster, per the end-of-session sweep) → then a restore drill before it holds anything you care about.
