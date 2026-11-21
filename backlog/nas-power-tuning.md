# NAS CPU power tuning

Assessment of CPU power tuning on the TrueNAS box, mirroring the OKD node tuning; not built. The README TODO keeps a short summary of the item and links here.

Baseline read off the box: Xeon E-2146G, 12 threads, `governor=powersave`, `driver=intel_pstate` (**active** mode), `EPB=6`, and **no `intel_pstate=passive` / `processor.max_cstate` on the cmdline** — i.e. the same starting position the OKD nodes were in. Per `blog/blog-power-consumption-draft.md`, governor+EPB alone are a **confirmed no-op on `intel_pstate=active`**; the win came from the `[bootloader]` cmdline change.

**Feasible code-only:** `system.advanced.config` exposes **`kernel_extra_options`** (currently empty), settable via `system.advanced.update`, so it goes in the Ansible role — no UI. Needs a reboot to take.

**Expect a smaller win than the rack's −39%:** those nodes idled at a pathological 102 W each, whereas a NAS's floor is dominated by six 7200 rpm spindles (~40-60 W of fixed load the CPU governor cannot touch).

**Measured baseline 2026-08-28 (Shelly, live in Grafana): 69.7 W current / 76.6 W 24h avg / min 65.5 / max 108.4 — PLN 69.67 per month.** The 24h average is inflated by badblocks burn-in, which ended ~03:00; the trace drops ~80 W -> ~68 W there, so **~69 W is the true idle floor** with 6 spindles up and the pool imported. That floor is the point: six 7200 rpm HDDs idle at roughly 8 W each = **~48 W the governor cannot touch**, leaving only ~25-30 W of CPU+board to attack. Expect single-digit-to-low-teens watts, not a repeat of the rack's -39%.

**Do not pair with HDD spindown** on a pool serving live NFS: spin-up latency and head-park wear cost more than the idle watts. Open question: deeper C-states add wakeup latency to NFS/ZFS IO — gate on the benchmark above [the one planned in the README TODO item].
