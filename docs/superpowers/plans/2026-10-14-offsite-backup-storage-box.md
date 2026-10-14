# Offsite Backup to a Hetzner Storage Box — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A nightly TrueNAS Cloud Sync task mirrors `tank/immich` to the Hetzner Storage Box sub-account. Both Cloud
Sync tasks get collector metrics and alerts, and a full restore is proven before the C2 task is retired.

**Architecture:**
- The `truenas-tasks` role learns the top-level `transfers` field.
- `group_vars` declares a second SFTP credential and task.
- The textfile collector exports per-task state from `cloudsync.query`.
- A new `truenas-backups` rule group in the truenas-exporter chart alerts on staleness, disabled tasks and the
  800 GB review point.

The code lands in git (Part A). The operator then converges with `playbook.yml`, and the first run, restore test
and snapshot test follow with the operator's go-ahead (Part B).

**Tech Stack:**
- ansible-core 2.21.5 (`ansible.builtin.*` only);
- TrueNAS SCALE 25.10.6 middleware via `midclt`, with rclone inside Cloud Sync;
- Python 3 (3.9 on the Mac, 3.11 on TrueNAS);
- Helm 4.3 locally, ArgoCD 3.1;
- PrometheusRule on user-workload Prometheus;
- `promtool` for rule unit tests.

**Spec:** `docs/superpowers/specs/2026-10-13-offsite-backup-storage-box-design.md`

## Global Constraints

**Git**
- Commit straight to `master` with messages shaped `<scope>: <imperative summary>`.
- No `Co-Authored-By` trailer, no 🤖 footer, no session trailer. The user's rule overrides the harness reminder.

**Ansible**
- `ansible.builtin.*` modules only.
- The operator runs `playbook.yml`, because it needs the vault password. I run `--syntax-check` and `check.yml`.

**Secrets**
- The Storage Box host name, sub-account user and password live only in `ansible/truenas/vars/vault.yml`, as
  `truenas_backup_hetzner_host`, `truenas_backup_hetzner_user` and `truenas_backup_hetzner_password`.
- They never appear in git, chat, logs or the blog. Harnesses use obviously fake values.
- `cloudsync.query` and `cloudsync.credentials.query` return passwords. Every read of them is filtered to `id`,
  `name`, `description`, `enabled`, `transfers`, `.credentials.name`, `job.state` and `job.time_*` before anything is
  printed.
- Job logs are printed only through the redaction filter in Task 7.

**What gets declared**
- Credential `hetzner-storagebox`: SFTP, port 22, secrets host/user/pass.
- Task description, exactly: `offsite: tank/immich -> hetzner storage box /immich (managed by ansible/truenas)`.
  Fields: dataset `immich`, folder `/immich`, `transfer_mode: SYNC`, `snapshot: true`, `transfers: 2`, schedule
  `0 6 * * *`, excludes `/thumbs/**` and `/encoded-video/**`.
- The Synology task stays as it is: `COPY`, 05:00, no `transfers`.

**Monitoring**
- Metrics, each with label `task` = the task description:
  - `truenas_cloudsync_enabled`
  - `truenas_cloudsync_running`
  - `truenas_cloudsync_last_job_success`
  - `truenas_cloudsync_last_job_finished_timestamp_seconds`
  - `truenas_cloudsync_last_success_timestamp_seconds`
- Alerts:
  - `TrueNASCloudSyncStale` × 3: 36 h warning (`for` 15m); 72 h critical (15m); no success in 7 days or ever,
    critical (1h).
  - `TrueNASCloudSyncDisabled`: warning, 1h.
  - `TrueNASOffsiteReviewDue`: `tank/immich` > 800e9, warning, 6h.

**Operations**
- No mutating `oc`, `kubectl` or `helm install`. ArgoCD applies the chart from `master`.
- Anything on TrueNAS beyond a read (`cloudsync.sync`, `cloudsync.sync_onetime`, `mkdir`, `rm`), and anything in
  Hetzner's console, waits for the operator's explicit go-ahead, task by task.
- zsh traps: never a variable named `path`, no `=====` lines, quote globs. The harness scripts run under `bash`.

**Paths**
- `SCR` is the session scratchpad: `/private/tmp/claude-501/-Users-vadzimdziadziulia-laptop-Projects-homelab/9d295bb3-47d4-4b19-acac-3a116a4ccd2b/scratchpad`.
  Another session substitutes its own. Nothing under `$SCR` is committed.
- `REPO` = `/Users/vadzimdziadziulia-laptop/Projects/homelab`.

## Review Focus

1. **A running job hides the previous result.** The collector must export `running 1` and no `last_*` series. The
   alerts must still see the last success through `max_over_time`. Pinned by collector case `t-running` and promtool
   test 1, where the success series disappears.
2. **A live task row without a `transfers` key, or with `transfers: null`.** The drift check must not keep updating
   the Synology task. Pinned by harness case `t1-oldrow`.
3. **A password or the box host name in collector output, Ansible `-v` output or a printed job log.** Pinned by the
   collector's leak assertion, the harness `leak` case and the Task 7 redaction filter.
4. **A disabled task with an old success must not raise Stale, and `on(task)` must not cross-match two tasks.**
   Pinned by promtool tests 1 and 3.
5. **`cloudsync.query` failing or returning garbage must not lose the other collectors' metrics, and must count as
   a collector error.** Pinned by collector modes `fail` and `bad`.

---

# Part A — code, in git

### Task 1: The role learns `transfers`

**Files:**
- Modify: `ansible/truenas/roles/truenas-tasks/tasks/main.yml:371-398` (payload and `_in_sync`)
- Modify: `ansible/truenas/README.md` (one paragraph in "Backup tasks (Cloud Sync)")
- Test (scratch): `$SCR/cs/bin/midclt`, `$SCR/cs/play.yml`, `$SCR/cs/run.sh`, `$SCR/cs/check.py`,
  `$SCR/cs/mutate.py`, `$SCR/cs/extra-t1.yml`, `$SCR/cs/secrets-syn.yml`, `$SCR/cs/secrets-all.yml`

**Interfaces:**
- Consumes: the existing `truenas_cloudsync_tasks` entries.
- Produces:
  - an optional per-task key `transfers` (int > 0) in `truenas_cloudsync_tasks`. It is sent as top-level
    `transfers` in `cloudsync.create`/`update` (`null` when not declared) and compared in `_in_sync`;
  - the harness `$SCR/cs/` (`run.sh <case> [ansible args]`, `check.py <case>`, `mutate.py <action>`), which Task 2
    reuses.

- [ ] **Step 1: Write the harness**

`$SCR/cs/bin/midclt` (then `chmod +x "$SCR/cs/bin/midclt"`):

```python
#!/usr/bin/env python3
# Test double for `midclt call cloudsync.*` on TrueNAS 25.10.6. Keeps state in
# $FAKE_STATE and rejects payloads the way the middleware schema does
# (additionalProperties: false, strict types). Records every mutating call.
import json, os, sys

st_path = os.environ["FAKE_STATE"]
st = json.load(open(st_path)) if os.path.exists(st_path) else {"creds": [], "tasks": [], "calls": []}


def save():
    json.dump(st, open(st_path, "w"), indent=1)


def die(msg):
    sys.stderr.write("[EINVAL] " + msg + "\n")
    sys.exit(1)


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


a = sys.argv[1:]
if not a or a[0] != "call":
    die("fake midclt: expected `call`, got %r" % (a,))
m, args = a[1], [json.loads(x) for x in a[2:]]


def check_cred(p):
    if set(p) - {"name", "provider"}:
        die("extra keys in credential: %s" % sorted(p))
    pr = p["provider"]
    if set(pr) - {"type", "host", "port", "user", "pass", "private_key"}:
        die("extra provider keys %s" % sorted(pr))
    for k in ("type", "host", "user", "pass"):
        if not isinstance(pr.get(k), str) or not pr[k]:
            die("provider.%s must be a non-empty string" % k)
    if not is_int(pr.get("port", 22)):
        die("provider.port must be an integer, got %r" % (pr.get("port"),))


def norm_cred(p, i):
    return {"id": i, "name": p["name"], "provider": dict({"port": 22, "private_key": None}, **p["provider"])}


ALLOWED = {"description", "path", "credentials", "attributes", "schedule", "direction",
           "transfer_mode", "snapshot", "exclude", "enabled", "transfers"}


def check_task(p):
    if set(p) - ALLOWED:
        die("extra task keys %s" % sorted(set(p) - ALLOWED))
    if not is_int(p["credentials"]):
        die("credentials must be an integer, got %r" % (p["credentials"],))
    if p["credentials"] not in [c["id"] for c in st["creds"]]:
        die("credentials id %r does not exist" % p["credentials"])
    for k in ("snapshot", "enabled"):
        if not isinstance(p[k], bool):
            die("%s must be a boolean, got %r" % (k, p[k]))
    tr = p.get("transfers")
    if tr is not None and not (is_int(tr) and tr > 0):
        die("transfers must be an integer > 0 or null, got %r" % (tr,))
    if not (isinstance(p["exclude"], list) and all(isinstance(x, str) for x in p["exclude"])):
        die("exclude must be a list of strings")
    if p["direction"] not in ("PUSH", "PULL") or p["transfer_mode"] not in ("SYNC", "COPY", "MOVE"):
        die("bad enum")
    if not p["path"].startswith("/mnt/"):
        die("path")
    if not isinstance(p["attributes"], dict) or "folder" not in p["attributes"]:
        die("attributes.folder")
    if sorted(p["schedule"]) != ["dom", "dow", "hour", "minute", "month"]:
        die("schedule keys")


def norm_task(p, i):
    c = [c for c in st["creds"] if c["id"] == p["credentials"]][0]
    t = dict(p)
    t["id"] = i
    t["credentials"] = c
    t["job"] = None
    t["locked"] = False
    t.setdefault("transfers", None)                                    # the middleware's default
    t["attributes"] = dict(p["attributes"], fast_list=False)           # a default the caller did not send
    t["schedule"] = {k: str(v) for k, v in p["schedule"].items()}
    return t


if m == "cloudsync.credentials.query":
    print(json.dumps(st["creds"]))
elif m == "cloudsync.query":
    print(json.dumps(st["tasks"]))
elif m == "cloudsync.credentials.create":
    check_cred(args[0])
    c = norm_cred(args[0], len(st["creds"]) + 1)
    st["creds"].append(c)
    st["calls"].append("%s %s" % (m, c["name"]))
    save()
    print(json.dumps(c))
elif m == "cloudsync.credentials.update":
    if not is_int(args[0]):
        die("id must be an integer, got %r" % (args[0],))
    check_cred(args[1])
    st["creds"] = [norm_cred(args[1], c["id"]) if c["id"] == args[0] else c for c in st["creds"]]
    st["calls"].append("%s %d" % (m, args[0]))
    save()
    print("{}")
elif m == "cloudsync.create":
    check_task(args[0])
    t = norm_task(args[0], len(st["tasks"]) + 1)
    st["tasks"].append(t)
    st["calls"].append("%s %s" % (m, t["description"]))
    save()
    print(json.dumps(t))
elif m == "cloudsync.update":
    if not is_int(args[0]):
        die("id must be an integer, got %r" % (args[0],))
    check_task(args[1])
    st["tasks"] = [norm_task(args[1], t["id"]) if t["id"] == args[0] else t for t in st["tasks"]]
    st["calls"].append("%s %d" % (m, args[0]))
    save()
    print("{}")
else:
    die("fake midclt: unsupported method " + m)
```

`$SCR/cs/play.yml`:

```yaml
# Runs the Cloud Sync section of roles/truenas-tasks on localhost against bin/midclt,
# then the convergence expressions copied from playbook.yml.
- hosts: localhost
  gather_facts: false
  vars_files:
    - /Users/vadzimdziadziulia-laptop/Projects/homelab/ansible/truenas/group_vars/all.yml
  environment:
    PATH: "{{ playbook_dir }}/bin:/usr/bin:/bin:/opt/homebrew/bin"
    FAKE_STATE: "{{ playbook_dir }}/state.json"
  tasks:
    - name: The role's Cloud Sync section, extracted by run.sh
      ansible.builtin.include_tasks: section.yml

    - name: Re-read Cloud Sync tasks for the convergence check
      ansible.builtin.command:
        argv: [midclt, call, cloudsync.query]
      register: _post_cs
      changed_when: false
      check_mode: false
      no_log: true

    - name: Write the convergence result
      ansible.builtin.copy:
        dest: "{{ playbook_dir }}/convergence.json"
        content: "{{ {'missing': _cs_expected | difference(_cs_live), 'without_secrets': _cs_declared | difference(_cs_expected)} | to_json }}"
      changed_when: false
      check_mode: false
      vars:
        _cs_ready: "{{ truenas_cs_status | default([]) | selectattr('missing', 'equalto', []) | map(attribute='name') | list }}"
        _cs_declared: "{{ truenas_cloudsync_tasks | default([]) | map(attribute='description') | list }}"
        _cs_expected: "{{ truenas_cloudsync_tasks | default([]) | selectattr('credentials', 'in', _cs_ready) | map(attribute='description') | list }}"
        _cs_live: "{{ _post_cs.stdout | from_json | map(attribute='description') | list }}"
```

`$SCR/cs/run.sh`:

```bash
#!/bin/bash
# usage: run.sh <case> [ansible-playbook args...]   -> logs/<case>.log, prints the recap line
set -u
REPO=/Users/vadzimdziadziulia-laptop/Projects/homelab
CS="$(cd "$(dirname "$0")" && pwd)"
c="$1"; shift
mkdir -p "$CS/logs"
# Always test the role as it is in the working tree.
sed -n '/^# Cloud Sync backup tasks/,$p' "$REPO/ansible/truenas/roles/truenas-tasks/tasks/main.yml" > "$CS/section.yml"
ANSIBLE_HOME="$TMPDIR/ansible-home" ANSIBLE_LOCAL_TEMP="$TMPDIR/ansible-tmp" \
ANSIBLE_REMOTE_TMP="$TMPDIR/ansible-remote" ANSIBLE_NOCOLOR=1 \
  ansible-playbook -i localhost, -c local -e ansible_python_interpreter=auto_silent \
  "$CS/play.yml" "$@" > "$CS/logs/$c.log" 2>&1
rc=$?
grep -E '^localhost ' "$CS/logs/$c.log" | tail -1
echo "rc=$rc"
```

`$SCR/cs/mutate.py`:

```python
#!/usr/bin/env python3
"""Edit the fake box between harness runs.  usage: mutate.py reset|drift-transfers|drop-transfers-key"""
import json, os, sys

CS = os.path.dirname(os.path.abspath(__file__))
ST = os.path.join(CS, "state.json")
TT = "test: transfers (harness only)"
SYN = "backup: tank/immich -> synology photo/backups/immich (managed by ansible/truenas)"

act = sys.argv[1]
if act == "reset":
    for f in ("state.json", "convergence.json"):
        if os.path.exists(os.path.join(CS, f)):
            os.unlink(os.path.join(CS, f))
    sys.exit(0)
st = json.load(open(ST))
for t in st["tasks"]:
    if act == "drift-transfers" and t["description"] == TT:
        t["transfers"] = 4
    if act == "drop-transfers-key" and t["description"] == SYN:
        t.pop("transfers", None)
json.dump(st, open(ST, "w"), indent=1)
print("mutated: " + act)
```

`$SCR/cs/check.py`:

```python
#!/usr/bin/env python3
"""Assertions for the Cloud Sync role harness.  usage: check.py <case>   (exit 0 = all pass)"""
import json, os, re, sys

CS = os.path.dirname(os.path.abspath(__file__))
SYN = "backup: tank/immich -> synology photo/backups/immich (managed by ansible/truenas)"
HZ = "offsite: tank/immich -> hetzner storage box /immich (managed by ansible/truenas)"
TT = "test: transfers (harness only)"
SECRETS = ["TESTPW-syn-7f3a", "TESTPW-hz-2c9e", "hz-test.example.invalid", "u000000-sub1"]


def load(name, default):
    p = os.path.join(CS, name)
    return json.load(open(p)) if os.path.exists(p) else default


st = load("state.json", {"creds": [], "tasks": [], "calls": []})
conv = load("convergence.json", None)
fails = []


def ok(cond, what):
    print(("PASS " if cond else "FAIL ") + what)
    if not cond:
        fails.append(what)


def task(desc):
    return next((t for t in st["tasks"] if t["description"] == desc), None)


def cred(name):
    return next((c for c in st["creds"] if c["name"] == name), None)


def recap(case):
    lines = [l for l in open(os.path.join(CS, "logs", case + ".log")) if l.startswith("localhost ")]
    return {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", lines[-1])} if lines else {}


def calls(prefix):
    return [c for c in st["calls"] if c.startswith(prefix + " ")]


case = sys.argv[1]

if case == "t1-create":
    t, s = task(TT), task(SYN)
    ok(t is not None and s is not None, "both tasks created")
    ok(t is not None and t.get("transfers") == 2, "test task has transfers 2")
    ok(s is not None and s.get("transfers") is None, "synology task has transfers null")
    ok(st["calls"] == ["cloudsync.credentials.create synology-sftp",
                       "cloudsync.create " + SYN, "cloudsync.create " + TT], "calls: one credential, two tasks")
    ok(recap(case).get("failed") == 0, "no failed tasks")

elif case == "t1-rerun":
    ok(recap(case).get("changed") == 0, "second run changed=0")
    ok(len(st["calls"]) == 3, "no new middleware calls")

elif case == "t1-drift":
    t = task(TT)
    ok(t["transfers"] == 2, "drifted transfers back to 2")
    ok(calls("cloudsync.update") == ["cloudsync.update %d" % t["id"]], "exactly one update, for the test task")

elif case == "t1-oldrow":
    ok(len(calls("cloudsync.update")) == 1, "no update for a synology row without a transfers key")
    ok(recap(case).get("changed") == 0, "changed=0")

elif case == "t1-check":
    ok(st["calls"] == [] and st["tasks"] == [], "--check on an empty box makes no calls")

elif case == "t2-create":
    h, s, hc = task(HZ), task(SYN), cred("hetzner-storagebox")
    ok([c["name"] for c in st["creds"]] == ["synology-sftp", "hetzner-storagebox"], "two credentials, in declared order")
    ok(hc is not None and {k: hc["provider"].get(k) for k in ("type", "port", "host", "user", "pass")}
       == {"type": "SFTP", "port": 22, "host": "hz-test.example.invalid", "user": "u000000-sub1", "pass": "TESTPW-hz-2c9e"},
       "hetzner credential: SFTP, port 22, host/user/pass from the vault")
    want = {"path": "/mnt/tank/immich", "direction": "PUSH", "transfer_mode": "SYNC", "snapshot": True,
            "transfers": 2, "enabled": True, "exclude": ["/thumbs/**", "/encoded-video/**"],
            "schedule": {"minute": "0", "hour": "6", "dom": "*", "month": "*", "dow": "*"}}
    ok(h is not None and {k: h.get(k) for k in want} == want, "offsite task fields as declared")
    ok(h is not None and h["attributes"].get("folder") == "/immich", "offsite folder /immich")
    ok(h is not None and h["credentials"]["name"] == "hetzner-storagebox", "offsite task uses the hetzner credential")
    ok(s is not None and s["transfer_mode"] == "COPY" and s.get("transfers") is None and s["schedule"]["hour"] == "5",
       "synology task unchanged: COPY, 05:00, transfers null")
    ok(conv == {"missing": [], "without_secrets": []}, "convergence: nothing missing, nothing without secrets")
    ok(recap(case).get("failed") == 0, "no failed tasks")

elif case == "t2-rerun":
    ok(recap(case).get("changed") == 0, "second run changed=0")
    ok(len(st["calls"]) == 4, "no new middleware calls")

elif case == "t2-nosecret":
    log = open(os.path.join(CS, "logs", case + ".log")).read()
    ok([c["name"] for c in st["creds"]] == ["synology-sftp"], "only the synology credential")
    ok([t["description"] for t in st["tasks"]] == [SYN], "only the synology task")
    ok(conv == {"missing": [], "without_secrets": [HZ]}, "offsite task reported without secrets, not missing")
    ok("Cloud Sync credential 'hetzner-storagebox' was NOT converged" in log
       and all(v in log for v in ("truenas_backup_hetzner_host", "truenas_backup_hetzner_user",
                                  "truenas_backup_hetzner_password")),
       "the run names the three missing vault variables")
    ok(recap(case).get("failed") == 0, "no failed tasks")

elif case == "t2-addsecret":
    ok(st["calls"][2:] == ["cloudsync.credentials.create hetzner-storagebox", "cloudsync.create " + HZ],
       "adds exactly the hetzner credential and task")
    ok(calls("cloudsync.update") == [] and calls("cloudsync.credentials.update") == [], "nothing updated")

elif case == "leak":
    hits = {s: 0 for s in SECRETS}
    for f in sorted(os.listdir(os.path.join(CS, "logs"))):
        body = open(os.path.join(CS, "logs", f)).read()
        for s in SECRETS:
            hits[s] += body.count(s)
    ok(all(v == 0 for v in hits.values()), "no secret in any log: %s" % hits)

else:
    sys.exit("unknown case " + case)

print("%d failed" % len(fails))
sys.exit(1 if fails else 0)
```

`$SCR/cs/extra-t1.yml` (Task 1 only):

```yaml
# The Synology task as declared in group_vars, plus a harness-only task that declares transfers.
truenas_cloudsync_tasks:
  - description: "backup: tank/immich -> synology photo/backups/immich (managed by ansible/truenas)"
    dataset: immich
    credentials: synology-sftp
    attributes: { folder: /photo/backups/immich }
    transfer_mode: COPY
    snapshot: true
    schedule: { minute: "0", hour: "5", dom: "*", month: "*", dow: "*" }
    exclude: ["/thumbs/**", "/encoded-video/**"]
  - description: "test: transfers (harness only)"
    dataset: immich
    credentials: synology-sftp
    attributes: { folder: /test }
    transfer_mode: SYNC
    snapshot: false
    transfers: 2
    schedule: { minute: "0", hour: "7", dom: "*", month: "*", dow: "*" }
```

`$SCR/cs/secrets-syn.yml`:

```yaml
truenas_backup_synology_user: syn-test-user
truenas_backup_synology_password: TESTPW-syn-7f3a
```

`$SCR/cs/secrets-all.yml`:

```yaml
truenas_backup_synology_user: syn-test-user
truenas_backup_synology_password: TESTPW-syn-7f3a
truenas_backup_hetzner_host: hz-test.example.invalid
truenas_backup_hetzner_user: u000000-sub1
truenas_backup_hetzner_password: TESTPW-hz-2c9e
```

- [ ] **Step 2: Run the create case against the unchanged role, and watch it fail**

```bash
SCR=/private/tmp/claude-501/-Users-vadzimdziadziulia-laptop-Projects-homelab/9d295bb3-47d4-4b19-acac-3a116a4ccd2b/scratchpad
python3 "$SCR/cs/mutate.py" reset
bash "$SCR/cs/run.sh" t1-create -v -e @"$SCR/cs/secrets-syn.yml" -e @"$SCR/cs/extra-t1.yml"
python3 "$SCR/cs/check.py" t1-create
```

Expected:
- the recap line shows `failed=0`, then `rc=0`;
- `FAIL test task has transfers 2`, because the role does not send it and the fake stores `null`;
- every other line `PASS`;
- `1 failed`.

If instead the fake rejects a payload (`[EINVAL]` in `logs/t1-create.log`), the harness is wrong. Fix the harness,
not the role.

- [ ] **Step 3: Implement**

In `ansible/truenas/roles/truenas-tasks/tasks/main.yml`, replace

```yaml
    # One expression, so the types survive templating: `credentials` has to
    # reach the middleware as an integer and the two flags as booleans.
    _payload: >-
```

with

```yaml
    # One expression, so the types survive templating: `credentials` has to
    # reach the middleware as an integer and the two flags as booleans.
    # `transfers` is a top-level field, not an attribute: the middleware turns
    # it into rclone's `--transfers N`, and null leaves rclone's default (4).
    _payload: >-
```

and replace

```yaml
           'exclude': item.exclude | default([]),
           'enabled': item.enabled | default(true) | bool
         } }}
```

with

```yaml
           'exclude': item.exclude | default([]),
           'enabled': item.enabled | default(true) | bool,
           'transfers': item.transfers | default(none)
         } }}
```

and replace

```yaml
         and (_cur.enabled | bool) == (item.enabled | default(true) | bool) }}
```

with

```yaml
         and (_cur.enabled | bool) == (item.enabled | default(true) | bool)
         and (_cur.transfers | default(none)) == (item.transfers | default(none)) }}
```

The live side gets `| default(none)` too, which goes one step beyond the spec's line. On ansible-core 2.21 an
undefined attribute fails a comparison, so a row without the key would break the run. Ledger this as a ruling.

- [ ] **Step 4: Run the create case again**

```bash
SCR=/private/tmp/claude-501/-Users-vadzimdziadziulia-laptop-Projects-homelab/9d295bb3-47d4-4b19-acac-3a116a4ccd2b/scratchpad
python3 "$SCR/cs/mutate.py" reset
bash "$SCR/cs/run.sh" t1-create -v -e @"$SCR/cs/secrets-syn.yml" -e @"$SCR/cs/extra-t1.yml"
python3 "$SCR/cs/check.py" t1-create
```

Expected: five `PASS` lines, `0 failed`.

- [ ] **Step 5: Re-run, drift, an old row, check mode, and the leak check**

```bash
SCR=/private/tmp/claude-501/-Users-vadzimdziadziulia-laptop-Projects-homelab/9d295bb3-47d4-4b19-acac-3a116a4ccd2b/scratchpad
E=(-e @"$SCR/cs/secrets-syn.yml" -e @"$SCR/cs/extra-t1.yml")
bash "$SCR/cs/run.sh" t1-rerun "${E[@]}" && python3 "$SCR/cs/check.py" t1-rerun
python3 "$SCR/cs/mutate.py" drift-transfers
bash "$SCR/cs/run.sh" t1-drift "${E[@]}" && python3 "$SCR/cs/check.py" t1-drift
python3 "$SCR/cs/mutate.py" drop-transfers-key
bash "$SCR/cs/run.sh" t1-oldrow "${E[@]}" && python3 "$SCR/cs/check.py" t1-oldrow
python3 "$SCR/cs/mutate.py" reset
bash "$SCR/cs/run.sh" t1-check --check "${E[@]}" && python3 "$SCR/cs/check.py" t1-check
python3 "$SCR/cs/check.py" leak
```

zsh and bash both accept this array syntax.

Expected: every check prints only `PASS` lines and `0 failed`. In particular:
- `t1-rerun` shows `changed=0`;
- `t1-drift` makes exactly one `cloudsync.update`;
- `t1-oldrow` makes no further update;
- the leak counts are all zero.

- [ ] **Step 6: Syntax check**

```bash
cd /Users/vadzimdziadziulia-laptop/Projects/homelab/ansible/truenas
ANSIBLE_HOME="$TMPDIR/ansible-home" ANSIBLE_LOCAL_TEMP="$TMPDIR/ansible-tmp" ansible-playbook -i inventory.yml playbook.yml --syntax-check
```

Expected: `playbook: playbook.yml`.

- [ ] **Step 7: README paragraph**

In `ansible/truenas/README.md`, section "Backup tasks (Cloud Sync)", after the bullet list that ends with the
`owner_uid` sentence, add:

```markdown
`transfers` (optional, per task) is rclone's number of parallel file transfers. It is a top-level
task field, not an attribute, and the role reconciles it like the others. Left out, it is `null`,
which is rclone's default of 4.
```

- [ ] **Step 8: Commit**

```bash
cd /Users/vadzimdziadziulia-laptop/Projects/homelab
git add ansible/truenas/roles/truenas-tasks/tasks/main.yml ansible/truenas/README.md
git commit -m "truenas: let Cloud Sync tasks declare rclone transfers"
```

---

### Task 2: Declare the offsite leg

**Files:**
- Modify: `ansible/truenas/group_vars/all.yml:726-787` (Cloud Sync section: header comment, one credential, one task)
- Modify: `ansible/truenas/vars/vault.yml.example` (append after line 69)
- Modify: `ansible/truenas/README.md`: the row "Cloud Sync backup tasks" in "What this manages"; the section "Backup
  tasks (Cloud Sync)"; the `vars/vault.yml` row in "Files"
- Modify: `ansible/CLAUDE.md` (the sentence listing what needs the vault)
- Test: the `$SCR/cs/` harness from Task 1, cases `t2-*`

**Interfaces:**
- Consumes: the `transfers` key from Task 1; the harness.
- Produces: credential `hetzner-storagebox` and the task with the exact `HZ` description, which Tasks 6–9 look up on
  the box.

- [ ] **Step 1: Run the create case against the unchanged group_vars, and watch it fail**

```bash
SCR=/private/tmp/claude-501/-Users-vadzimdziadziulia-laptop-Projects-homelab/9d295bb3-47d4-4b19-acac-3a116a4ccd2b/scratchpad
python3 "$SCR/cs/mutate.py" reset
bash "$SCR/cs/run.sh" t2-create -v -e @"$SCR/cs/secrets-all.yml"
python3 "$SCR/cs/check.py" t2-create
```

Expected: `FAIL` on these five, then `5 failed`:
- `two credentials, in declared order`
- `hetzner credential: …`
- `offsite task fields as declared`
- `offsite folder /immich`
- `offsite task uses the hetzner credential`

`PASS` on the Synology line, the convergence line and `no failed tasks`.

- [ ] **Step 2: Rewrite the Cloud Sync section of `group_vars/all.yml`**

Replace lines 726 to the end of the file (the section header through the last `exclude` of the Synology task) with:

```yaml
# ---------------------------------------------------------------------------
# Cloud Sync backup tasks (rclone underneath; converged by truenas-tasks).
#
# TWO LEGS FOR THE IMMICH LIBRARY. Immich moved here from the DS418 on
# 2026-10-11, and the Hyper Backup -> C2 job on the DS418 backs up a path on
# the Synology, so from the cutover on nothing left this box until these
# existed:
#   * 05:00 -> the Synology share folder photo/backups/immich (since
#     2026-10-11). In the house; the DS418's temporary leg until it is sold.
#   * 06:00 -> a Hetzner Storage Box sub-account, folder /immich (in code since
#     2026-10-14; provider chosen 2026-10-13 after OVH fell through). The
#     offsite copy. Spec:
#     docs/superpowers/specs/2026-10-13-offsite-backup-storage-box-design.md
#
# WHY CLOUD SYNC AND NOT AN RSYNC TASK. Both exist on 25.10. Cloud Sync serves
# both legs with one code path (SFTP to each), and SFTP takes a plain account
# and password, where rsync over SSH for a non-admin DSM account needs key
# material planted in its home directory. What it does NOT carry is Unix
# ownership and mode -- contents and modification times only. Fine for a
# backup that is restored by copying files back; the restore then has to chown
# to the immich namespace UID (see the immich dataset above).
#
# COPY TO THE SYNOLOGY, SYNC TO THE BOX -- different on purpose:
#   * Synology, COPY: a file deleted in Immich stays there. It only grows, and
#     it is what survives an accidental delete at the source.
#   * Storage Box, SYNC: a mirror, so a delete reaches the box at the next run.
#     History there comes from the box's own snapshots (weekly, 10 kept, set
#     in Hetzner's console), which the sub-account login cannot touch.
#
# SECRETS never live here. `secrets` maps a provider field to the NAME of a
# vault variable (vars/vault.yml). When one is not loaded the role creates
# neither the credential nor its tasks, and says so per credential, rather
# than reporting a converged run with no backup behind it.
# ---------------------------------------------------------------------------
truenas_cloudsync_credentials:
  - name: synology-sftp
    provider:
      type: SFTP
      host: 192.168.1.2        # DS418, frontnet. Needs SFTP enabled in DSM File Services.
      port: 22
    secrets:
      user: truenas_backup_synology_user
      pass: truenas_backup_synology_password
  - name: hetzner-storagebox
    provider:
      type: SFTP
      port: 22                 # SFTP is always on at 22; 23 is the box's interactive SSH
    # The SUB-ACCOUNT (base directory `truenas`), never the main account. Its
    # server name carries the account number, so the host is a vault variable too.
    secrets:
      host: truenas_backup_hetzner_host
      user: truenas_backup_hetzner_user
      pass: truenas_backup_hetzner_password

truenas_cloudsync_tasks:
  # `description` is the identity the role matches on -- rename it and the role
  # creates a second task instead of updating this one (roles never prune).
  - description: "backup: tank/immich -> synology photo/backups/immich (managed by ansible/truenas)"
    dataset: immich
    credentials: synology-sftp
    # DSM's SFTP root is the list of shared folders, so this is the `photo`
    # share, folder backups/immich. A subfolder per dataset leaves room for more.
    attributes:
      folder: /photo/backups/immich
    transfer_mode: COPY
    # Copy from a temporary snapshot, so a photo written mid-run is either
    # wholly in or wholly out.
    snapshot: true
    # 05:00 Europe/Warsaw: after the 02:00 periodic snapshot and after Immich's
    # own database dump, which runs at 02:00 UTC (04:00 local in summer, 03:00
    # in winter) and has to ride along -- photos without it are anonymous files.
    schedule: { minute: "0", hour: "5", dom: "*", month: "*", dow: "*" }
    # Regenerable, and most of the small files. rclone filter syntax; a leading
    # slash anchors at the dataset root.
    exclude:
      - "/thumbs/**"
      - "/encoded-video/**"
  - description: "offsite: tank/immich -> hetzner storage box /immich (managed by ansible/truenas)"
    dataset: immich
    credentials: hetzner-storagebox
    # Relative to the sub-account's base directory, which is all it can see of
    # the box. Checked with cloudsync.list_directory on "/" before the first run.
    attributes:
      folder: /immich
    transfer_mode: SYNC
    snapshot: true
    # The box allows 10 connections per account. rclone opens up to 8 checkers
    # on top of its transfers, and TrueNAS does not expose the checker count.
    transfers: 2
    # 06:00 Europe/Warsaw: an hour after the Synology leg, from its own
    # temporary snapshot. The box's weekly snapshot (Sunday 03:00 UTC) falls
    # before this run in summer and in winter time.
    schedule: { minute: "0", hour: "6", dom: "*", month: "*", dow: "*" }
    exclude:
      - "/thumbs/**"
      - "/encoded-video/**"
```

Before saving, compare with the current text. The Synology credential and task must be byte-identical to lines
755–787 of the old file apart from their position. Check it with `git diff` after saving: only the header comment
and the added entries may change.

- [ ] **Step 3: Vault example**

Append to `ansible/truenas/vars/vault.yml.example`:

```yaml

# ---- Offsite backup to a Hetzner Storage Box (Cloud Sync over SFTP) -------
# The Storage Box SUB-ACCOUNT TrueNAS logs in with (Hetzner console ->
# Storage Box -> Subaccounts): base directory `truenas`, SSH on, external
# reachability on, not read-only, SMB and WebDAV off. Never the main account.
# The server name carries the account number, so it is a secret here too.
# Named by `secrets` in truenas_cloudsync_credentials (group_vars/all.yml).
#
# Without these three the role creates neither the credential nor the
# offsite task and says so on every run.
truenas_backup_hetzner_host: CHANGEME
truenas_backup_hetzner_user: CHANGEME
truenas_backup_hetzner_password: CHANGEME
```

- [ ] **Step 4: Run the create case again**

```bash
SCR=/private/tmp/claude-501/-Users-vadzimdziadziulia-laptop-Projects-homelab/9d295bb3-47d4-4b19-acac-3a116a4ccd2b/scratchpad
python3 "$SCR/cs/mutate.py" reset
bash "$SCR/cs/run.sh" t2-create -v -e @"$SCR/cs/secrets-all.yml"
python3 "$SCR/cs/check.py" t2-create
```

Expected: eight `PASS` lines, `0 failed`.

- [ ] **Step 5: Re-run, a missing vault, adding the vault later, and the leak check**

```bash
SCR=/private/tmp/claude-501/-Users-vadzimdziadziulia-laptop-Projects-homelab/9d295bb3-47d4-4b19-acac-3a116a4ccd2b/scratchpad
bash "$SCR/cs/run.sh" t2-rerun -e @"$SCR/cs/secrets-all.yml" && python3 "$SCR/cs/check.py" t2-rerun
python3 "$SCR/cs/mutate.py" reset
bash "$SCR/cs/run.sh" t2-nosecret -e @"$SCR/cs/secrets-syn.yml" && python3 "$SCR/cs/check.py" t2-nosecret
bash "$SCR/cs/run.sh" t2-addsecret -e @"$SCR/cs/secrets-all.yml" && python3 "$SCR/cs/check.py" t2-addsecret
python3 "$SCR/cs/check.py" leak
```

Expected: only `PASS` lines and `0 failed` from each. In particular:
- `t2-nosecret` reports the offsite task under `without_secrets` and names the three variables;
- `t2-addsecret` adds exactly the hetzner credential and task, and updates nothing;
- the leak counts are all zero.

- [ ] **Step 6: Syntax check and the read-only check play**

```bash
cd /Users/vadzimdziadziulia-laptop/Projects/homelab/ansible/truenas
ANSIBLE_HOME="$TMPDIR/ansible-home" ANSIBLE_LOCAL_TEMP="$TMPDIR/ansible-tmp" ansible-playbook -i inventory.yml playbook.yml --syntax-check
ANSIBLE_HOME="$TMPDIR/ansible-home" ANSIBLE_LOCAL_TEMP="$TMPDIR/ansible-tmp" ansible-playbook -i inventory.yml check.yml 2>&1 | tail -3
```

`check.yml` connects over SSH, so it runs unsandboxed. Expected: `playbook: playbook.yml`, then a recap with
`failed=0 unreachable=0`.

- [ ] **Step 7: Docs**

**`ansible/truenas/README.md`, "What this manages" table.** Change the row label from `Cloud Sync backup tasks (first
one: Immich → Synology over SFTP)` to `Cloud Sync backup tasks (Immich → Synology and → Hetzner Storage Box, both over
SFTP)`.

**`ansible/truenas/README.md`, section "Backup tasks (Cloud Sync)".** Replace the opening paragraph and the first two
bullets with the text below. Keep the `thumbs/`, `owner_uid` and Task 1 `transfers` paragraphs.

```markdown
`truenas_cloudsync_credentials` and `truenas_cloudsync_tasks` in `group_vars/all.yml` declare
rclone-based Cloud Sync tasks; the design notes are next to them. Two legs copy `tank/immich`
every night, both over SFTP:

| Time | Target | Mode | Why |
|---|---|---|---|
| 05:00 | the Synology, `photo` share, `backups/immich` | `COPY` | In the house. A photo deleted in Immich stays there, so it only grows |
| 06:00 | a Hetzner Storage Box sub-account, folder `/immich` | `SYNC` | Offsite mirror. History comes from the box's weekly snapshots (10 kept), which the TrueNAS login cannot touch |

Both legs run **from a snapshot**, so a file written mid-run is either wholly in or wholly out.
```

After the existing "What the Synology needs …" paragraph, add:

```markdown
What the Storage Box needs, by hand in Hetzner's console (not managed from this repo; set up
2026-10-14 and recorded in `blog/blog-offsite-backup-draft.md`):
- a sub-account with base directory `truenas`, SSH and external reachability on, not read-only,
  SMB and WebDAV off;
- the automatic snapshot plan (weekly, Sunday 03:00, keep 10) and "Display snapshot directory" on.

The sub-account's server name, user and password go into `vars/vault.yml` as
`truenas_backup_hetzner_host`, `truenas_backup_hetzner_user` and
`truenas_backup_hetzner_password`. The server name carries the account number, so it is a
secret too. The offsite task sets `transfers: 2`, because the box allows 10 connections per
account and rclone opens up to 8 checkers on top of its transfers.
```

In the following paragraph, change "Until those two variables are in the vault the role creates neither the
credential nor the task" to "Until a leg's variables are in the vault the role creates neither its credential nor
its task".

**`ansible/truenas/README.md`, "Files" table.** In the `vars/vault.yml` row, change "and the Synology account for the
Cloud Sync backup" to "the Synology account for the Cloud Sync backup, and the Hetzner Storage Box sub-account for the
offsite one".

**`ansible/CLAUDE.md`.** After "since 2026-10-11 the Synology account for the Cloud Sync backup
(`truenas_backup_synology_{user,password}` — without it the role creates neither the credential nor its task and
says so on every run)", add: ", and since 2026-10-14 the Hetzner Storage Box sub-account for the offsite leg
(`truenas_backup_hetzner_{host,user,password}`, same behaviour)". Count the list as four things where it says three.

- [ ] **Step 8: Commit**

```bash
cd /Users/vadzimdziadziulia-laptop/Projects/homelab
git add ansible/truenas/group_vars/all.yml ansible/truenas/vars/vault.yml.example ansible/truenas/README.md ansible/CLAUDE.md
git commit -m "truenas: declare the offsite Cloud Sync leg to the Hetzner Storage Box"
```

---

### Task 3: The collector exports Cloud Sync state

**Files:**
- Modify: `ansible/truenas/roles/truenas-tasks/files/node-exporter-textfile.py`. Add `collect_cloudsync` after
  `collect_snapshots` (which ends at line 239) and add it to the loop in `main()` (line 326).
- Test (scratch): `$SCR/col/bin/{midclt,zpool,zfs,smartctl}`, `$SCR/col/test_collector.py`

**Interfaces:**
- Consumes: `cloudsync.query` rows: `description`, `enabled`, `job.state`, and `job.time_finished` as
  `{"$date": <epoch ms>}`, read on the box 2026-10-14. Also the existing `Out.metric`, `run` and `errors`.
- Produces: the five metric names in Global Constraints, label `task`. Task 4's rules consume them.

- [ ] **Step 1: Write the test**

`$SCR/col/bin/midclt` (then `chmod +x`):

```python
#!/usr/bin/env python3
# Test double for the two midclt calls the textfile collector makes.
import os, sys

m = sys.argv[2] if len(sys.argv) > 2 else ""
if m == "pool.query":
    print("[]")
elif m == "cloudsync.query":
    mode = os.environ.get("CS_MODE", "ok")
    if mode == "fail":
        sys.stderr.write("[ENOMETHOD] simulated failure\n")
        sys.exit(1)
    if mode == "bad":
        print("this is not json")
        sys.exit(0)
    if mode == "empty":
        print("[]")
        sys.exit(0)
    sys.stdout.write(open(os.environ["CS_FIXTURE"]).read())
else:
    sys.stderr.write("unexpected method %s\n" % m)
    sys.exit(1)
```

`$SCR/col/bin/zpool`, `$SCR/col/bin/zfs` and `$SCR/col/bin/smartctl`, each with the content below, then `chmod +x`.
They print nothing, so those collectors export nothing and count no error:

```sh
#!/bin/sh
exit 0
```

`$SCR/col/test_collector.py`:

```python
#!/usr/bin/env python3
"""Runs the repo's textfile collector against bin/ fakes and checks truenas.prom.  exit 0 = all pass"""
import json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
COLLECTOR = "/Users/vadzimdziadziulia-laptop/Projects/homelab/ansible/truenas/roles/truenas-tasks/files/node-exporter-textfile.py"
LEAK = ["LEAK-PASSWORD-91c2", "LEAK-host.invalid", "LEAK-user"]
CRED = {"id": 1, "name": "c", "provider": {"type": "SFTP", "host": "LEAK-host.invalid", "port": 22,
                                           "user": "LEAK-user", "pass": "LEAK-PASSWORD-91c2"}}
QUOTED = 't-"quoted" \\ back'


def d(ms):
    return {"$date": ms}


FIXTURE = [
    {"id": 1, "description": "t-never", "enabled": True, "job": None},
    {"id": 2, "description": "t-running", "enabled": True,
     "job": {"state": "RUNNING", "time_started": d(1791946801000), "time_finished": None, "logs_excerpt": "LEAK-PASSWORD-91c2"}},
    {"id": 3, "description": "t-waiting", "enabled": True,
     "job": {"state": "WAITING", "time_started": None, "time_finished": None}},
    {"id": 4, "description": "t-success", "enabled": True,
     "job": {"state": "SUCCESS", "time_started": d(1791946801000), "time_finished": d(1791946806000),
             "arguments": [4], "logs_excerpt": "LEAK-PASSWORD-91c2"}},
    {"id": 5, "description": "t-failed", "enabled": True,
     "job": {"state": "FAILED", "time_started": d(1791949990000), "time_finished": d(1791950000000),
             "error": "LEAK-PASSWORD-91c2"}},
    {"id": 6, "description": "t-aborted", "enabled": False,
     "job": {"state": "ABORTED", "time_started": d(1791950400000), "time_finished": d(1791950500000)}},
    # SUCCESS without an end time: the success flag, no timestamps. Also exercises label escaping.
    {"id": 7, "description": QUOTED, "enabled": True,
     "job": {"state": "SUCCESS", "time_started": None, "time_finished": None}},
]
for t in FIXTURE:
    t.update({"credentials": CRED, "transfers": None, "path": "/mnt/tank/immich", "attributes": {"folder": "/x"}})

EXPECTED = {}
for t, en, runn in [("t-never", 1, 0), ("t-running", 1, 1), ("t-waiting", 1, 1), ("t-success", 1, 0),
                    ("t-failed", 1, 0), ("t-aborted", 0, 0), (QUOTED, 1, 0)]:
    EXPECTED[("truenas_cloudsync_enabled", t)] = en
    EXPECTED[("truenas_cloudsync_running", t)] = runn
for t, v in [("t-success", 1), ("t-failed", 0), ("t-aborted", 0), (QUOTED, 1)]:
    EXPECTED[("truenas_cloudsync_last_job_success", t)] = v
for t, v in [("t-success", 1791946806), ("t-failed", 1791950000), ("t-aborted", 1791950500)]:
    EXPECTED[("truenas_cloudsync_last_job_finished_timestamp_seconds", t)] = v
EXPECTED[("truenas_cloudsync_last_success_timestamp_seconds", "t-success")] = 1791946806
EXPECTED = {k: float(v) for k, v in EXPECTED.items()}

SAMPLE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{(.*)\})? (\S+)$')
LABEL = re.compile(r'(\w+)="((?:[^"\\]|\\.)*)"')


def parse(body):
    samples, types, bad = {}, {}, []
    for line in body.splitlines():
        if line.startswith("# TYPE "):
            n = line.split()[2]
            types[n] = types.get(n, 0) + 1
            continue
        if not line or line.startswith("#"):
            continue
        mm = SAMPLE.match(line)
        if not mm:
            bad.append(line)
            continue
        lbl = {k: v.replace('\\"', '"').replace("\\\\", "\\") for k, v in LABEL.findall(mm.group(3) or "")}
        samples[(mm.group(1), lbl.get("task"))] = float(mm.group(4))
    return samples, types, bad


def run_collector(mode):
    out = tempfile.mkdtemp(prefix="col-")
    fx = os.path.join(out, "fixture.json")
    json.dump(FIXTURE, open(fx, "w"))
    env = {"PATH": os.path.join(HERE, "bin") + ":/usr/bin:/bin", "CS_MODE": mode, "CS_FIXTURE": fx}
    p = subprocess.run([sys.executable, COLLECTOR, out], env=env, capture_output=True, text=True)
    prom = os.path.join(out, "truenas.prom")
    return p, (open(prom).read() if os.path.exists(prom) else "")


fails = []


def ok(cond, what):
    print(("PASS " if cond else "FAIL ") + what)
    if not cond:
        fails.append(what)


def cs(samples):
    return {k: v for k, v in samples.items() if k[0].startswith("truenas_cloudsync_")}


# 1. Every job state.
p, body = run_collector("ok")
s, types, bad = parse(body)
got = cs(s)
ok(p.returncode == 0, "ok: collector exits 0 (stderr: %s)" % p.stderr.strip()[:200])
ok(got == EXPECTED, "ok: cloudsync series exactly as expected; missing %s; extra %s; wrong %s" % (
    sorted(set(EXPECTED) - set(got)), sorted(set(got) - set(EXPECTED)),
    sorted(k for k in set(got) & set(EXPECTED) if got[k] != EXPECTED[k])))
ok(not bad, "ok: every sample line parses %s" % bad[:3])
ok(all(v == 1 for v in types.values()), "ok: one TYPE line per metric")
ok(s.get(("truenas_textfile_collector_errors", None)) == 0, "ok: collector errors 0")
ok(not any(x in body for x in LEAK), "ok: no credential or job-log field reaches the output")

# 2. cloudsync.query fails, 3. returns garbage: the rest of the file survives, one error counted.
for mode in ("fail", "bad"):
    p, body = run_collector(mode)
    s, _, _ = parse(body)
    ok(not cs(s), "%s: no cloudsync series" % mode)
    ok(s.get(("truenas_textfile_collector_errors", None)) == 1, "%s: counted as one collector error" % mode)
    ok(("truenas_textfile_collector_last_run_timestamp_seconds", None) in s, "%s: the file is still written" % mode)

# 4. No tasks at all.
p, body = run_collector("empty")
s, _, _ = parse(body)
ok(not cs(s) and s.get(("truenas_textfile_collector_errors", None)) == 0, "empty: no series, no error")

print("%d failed" % len(fails))
sys.exit(1 if fails else 0)
```

- [ ] **Step 2: Run it against the unchanged collector, and watch it fail**

```bash
python3 /private/tmp/claude-501/-Users-vadzimdziadziulia-laptop-Projects-homelab/9d295bb3-47d4-4b19-acac-3a116a4ccd2b/scratchpad/col/test_collector.py
```

Expected:
- `FAIL ok: cloudsync series exactly as expected; missing [...22 entries...]`;
- `FAIL fail: counted as one collector error` and `FAIL bad: counted as one collector error`, because nothing calls
  `cloudsync.query` yet;
- the other lines `PASS`;
- `3 failed`.

- [ ] **Step 3: Implement**

Insert after `collect_snapshots` (after the line `"Seconds since the newest snapshot for this dataset.", dataset=ds)`
and its blank lines):

```python
def collect_cloudsync(out):
    """
    Cloud Sync (rclone) backup tasks, one set of series per task, labelled by
    its description -- the identity the Ansible role matches on.

    SECRETS: cloudsync.query nests each task's full credential, PASSWORD
    INCLUDED, and the job carries its log excerpt and error text. Only
    `description` and `enabled` are read from a row, and only `state` and
    `time_finished` from its job. Export nothing else from these rows.

    The job is the task's LAST job, and it survives a reboot: the middleware
    writes it to the task's database row when the job completes
    (persist_task_state_on_job_complete, read on 25.10.6 on 2026-10-14). While
    a job runs, the in-memory job replaces it, so the previous result is
    invisible until the run ends. That is why the alerts take the last success
    from Prometheus history (max_over_time) -- and why a failed run does not
    erase when the last good one was.
    """
    raw = run(["midclt", "call", "cloudsync.query"])
    if not raw:
        return
    try:
        tasks = json.loads(raw)
    except ValueError:
        global errors
        errors += 1
        return
    for t in tasks:
        task = t.get("description") or "id-%s" % t.get("id")
        job = t.get("job") or {}
        state = job.get("state")
        end = job.get("time_finished")
        # midclt renders timestamps as {"$date": <epoch_ms>}.
        if isinstance(end, dict):
            end = end.get("$date")
        out.metric("cloudsync_enabled", 1 if t.get("enabled") else 0,
                   "1 if the Cloud Sync task is enabled.", task=task)
        out.metric("cloudsync_running", 1 if state in ("RUNNING", "WAITING") else 0,
                   "1 while the task's job is running or waiting.", task=task)
        if state not in ("SUCCESS", "FAILED", "ABORTED"):
            continue
        out.metric("cloudsync_last_job_success", 1 if state == "SUCCESS" else 0,
                   "1 if the last finished job succeeded, 0 if it failed or was aborted. "
                   "Absent while a job runs and if the task never ran.", task=task)
        if not end:
            continue
        ts = float(end) / 1000.0
        out.metric("cloudsync_last_job_finished_timestamp_seconds", ts,
                   "Unix time the last finished job ended.", task=task)
        if state == "SUCCESS":
            out.metric("cloudsync_last_success_timestamp_seconds", ts,
                       "Unix time the last job ended, exported only when that job succeeded.", task=task)
```

In `main()`, change

```python
    for fn in (collect_pools, collect_scrub, collect_datasets, collect_snapshots, collect_smart):
```

to

```python
    for fn in (collect_pools, collect_scrub, collect_datasets, collect_snapshots, collect_cloudsync, collect_smart):
```

- [ ] **Step 4: Run the test again**

```bash
python3 /private/tmp/claude-501/-Users-vadzimdziadziulia-laptop-Projects-homelab/9d295bb3-47d4-4b19-acac-3a116a4ccd2b/scratchpad/col/test_collector.py
```

Expected: 13 `PASS` lines, `0 failed`.

- [ ] **Step 5: Run the function against the real box, read-only**

This loads the new function on TrueNAS from stdin and calls only `collect_cloudsync`. It writes no file and needs no
root. Run it unsandboxed, because it uses SSH.

```bash
cd /Users/vadzimdziadziulia-laptop/Projects/homelab
ssh -o BatchMode=yes truenas_admin@192.168.1.25 'python3 -c "
import sys, types
m = types.ModuleType(\"c\"); exec(sys.stdin.read(), m.__dict__)
o = m.Out(); m.collect_cloudsync(o)
print(\"\n\".join(l for l in o.lines if not l.startswith(\"#\"))); print(\"errors\", m.errors)
"' < ansible/truenas/roles/truenas-tasks/files/node-exporter-textfile.py
```

Expected:
- five lines for the Synology task: `enabled 1`, `running 0`, `last_job_success 1`, and two timestamps equal to the
  last 05:00 run, about 1791946806.0 or later;
- then `errors 0`;
- no other task, because the offsite one is not converged yet;
- nothing that looks like a host, user or password.

- [ ] **Step 6: Commit**

```bash
cd /Users/vadzimdziadziulia-laptop/Projects/homelab
git add ansible/truenas/roles/truenas-tasks/files/node-exporter-textfile.py
git commit -m "truenas: export Cloud Sync task state from the textfile collector"
```

---

### Task 4: Alert rules

**Files:**
- Modify: `components/cluster-config/truenas-exporter/templates/prometheusrule.yaml` (append a group after line 187)
- Modify: `components/cluster-config/truenas-exporter/README.md:20` (the rules row)
- Modify: `ansible/truenas/README.md` (the closing paragraph of "Backup tasks (Cloud Sync)")
- Test (scratch): `$SCR/rules/render.sh`, `$SCR/rules/test.yml`

**Interfaces:**
- Consumes: the five metric names from Task 3, and the existing `truenas_dataset_used_bytes{dataset=…}`.
- Produces: alert names `TrueNASCloudSyncStale`, `TrueNASCloudSyncDisabled` and `TrueNASOffsiteReviewDue`, all
  labelled `severity`. Part B checks that none of them fires.

- [ ] **Step 0: promtool**

Run `command -v promtool`. If it's missing, install it with `brew install prometheus` (approved by the operator at
plan review). If the operator declined, skip Steps 3 and 5's promtool lines, ledger the ruling, and rely on Task 5's
check of loaded rule health.

- [ ] **Step 1: Write the unit tests and the render script**

`$SCR/rules/render.sh`:

```bash
#!/bin/bash
# Render the chart's PrometheusRule and turn it into promtool rule files.
set -eu
R="$(cd "$(dirname "$0")" && pwd)"
cd /Users/vadzimdziadziulia-laptop/Projects/homelab
helm template truenas-exporter components/cluster-config/truenas-exporter -n truenas-exporter \
  -f components/cluster-config/truenas-exporter/values.yaml --skip-schema-validation \
  --show-only templates/prometheusrule.yaml > "$R/rendered.yaml"
yq '.spec' "$R/rendered.yaml" > "$R/rules-full.yml"
# promtool compares annotations exactly; the unit tests check expressions and labels only.
yq '.spec | del(.groups[].rules[].annotations)' "$R/rendered.yaml" > "$R/rules.yml"
echo "rules: $(yq '[.groups[].rules[]] | length' "$R/rules-full.yml")"
```

`$SCR/rules/test.yml`:

```yaml
# promtool unit tests for the truenas-backups group. Times start at 0 = epoch 0,
# so a success "at t" carries the value t in seconds. Interval 5m everywhere:
# promtool's lookback is 5m, so sparser samples would read as gaps.
rule_files:
  - rules.yml
evaluation_interval: 1m
tests:
  # 1. Two tasks. "syn" succeeds daily. "hz" succeeded once at t=0, and its
  #    success series disappears at 2h (a failed or running job hides it).
  #    Only hz goes stale: warning past 36h, critical past 72h; once its last
  #    success has left the 7-day window, only the "no success in 7 days" rule.
  - interval: 5m
    input_series:
      - series: 'truenas_cloudsync_enabled{instance="truenas",job="truenas-exporter",task="syn"}'
        values: '1x2100'
      - series: 'truenas_cloudsync_enabled{instance="truenas",job="truenas-exporter",task="hz"}'
        values: '1x2100'
      - series: 'truenas_cloudsync_last_success_timestamp_seconds{instance="truenas",job="truenas-exporter",task="syn"}'
        values: '0x287 86400x287 172800x287 259200x287 345600x287 432000x287 518400x287 604800x287'
      - series: 'truenas_cloudsync_last_success_timestamp_seconds{instance="truenas",job="truenas-exporter",task="hz"}'
        values: '0x24'
    alert_rule_test:
      - eval_time: 35h
        alertname: TrueNASCloudSyncStale
        exp_alerts: []
      - eval_time: 36h20m
        alertname: TrueNASCloudSyncStale
        exp_alerts:
          - exp_labels: {severity: warning, instance: truenas, job: truenas-exporter, task: hz}
      - eval_time: 72h20m
        alertname: TrueNASCloudSyncStale
        exp_alerts:
          - exp_labels: {severity: warning, instance: truenas, job: truenas-exporter, task: hz}
          - exp_labels: {severity: critical, instance: truenas, job: truenas-exporter, task: hz}
      - eval_time: 171h30m
        alertname: TrueNASCloudSyncStale
        exp_alerts:
          - exp_labels: {severity: critical, instance: truenas, job: truenas-exporter, task: hz}

  # 2. A task that never succeeded (just created by playbook.yml).
  - interval: 5m
    input_series:
      - series: 'truenas_cloudsync_enabled{instance="truenas",job="truenas-exporter",task="new"}'
        values: '1x30'
    alert_rule_test:
      - eval_time: 50m
        alertname: TrueNASCloudSyncStale
        exp_alerts: []
      - eval_time: 1h5m
        alertname: TrueNASCloudSyncStale
        exp_alerts:
          - exp_labels: {severity: critical, instance: truenas, job: truenas-exporter, task: new}

  # 3. A disabled task with an old success: Disabled fires, Stale does not.
  - interval: 5m
    input_series:
      - series: 'truenas_cloudsync_enabled{instance="truenas",job="truenas-exporter",task="paused"}'
        values: '0x600'
      - series: 'truenas_cloudsync_last_success_timestamp_seconds{instance="truenas",job="truenas-exporter",task="paused"}'
        values: '0x600'
    alert_rule_test:
      - eval_time: 50m
        alertname: TrueNASCloudSyncDisabled
        exp_alerts: []
      - eval_time: 1h5m
        alertname: TrueNASCloudSyncDisabled
        exp_alerts:
          - exp_labels: {severity: warning, instance: truenas, job: truenas-exporter, task: paused}
      - eval_time: 40h
        alertname: TrueNASCloudSyncStale
        exp_alerts: []

  # 4. Review point: tank/immich grows 1 GB per 5m from 700 GB and passes 800 GB
  #    at 8h25m; fires 6h later. A bigger dataset elsewhere never fires it.
  - interval: 5m
    input_series:
      - series: 'truenas_dataset_used_bytes{instance="truenas",job="truenas-exporter",dataset="tank/immich"}'
        values: '700000000000+1000000000x200'
      - series: 'truenas_dataset_used_bytes{instance="truenas",job="truenas-exporter",dataset="tank/media"}'
        values: '5000000000000x200'
    alert_rule_test:
      - eval_time: 14h
        alertname: TrueNASOffsiteReviewDue
        exp_alerts: []
      - eval_time: 14h40m
        alertname: TrueNASOffsiteReviewDue
        exp_alerts:
          - exp_labels: {severity: warning, instance: truenas, job: truenas-exporter, dataset: tank/immich}
```

- [ ] **Step 2: Run the tests against the unchanged chart, and watch them fail**

```bash
SCR=/private/tmp/claude-501/-Users-vadzimdziadziulia-laptop-Projects-homelab/9d295bb3-47d4-4b19-acac-3a116a4ccd2b/scratchpad
bash "$SCR/rules/render.sh" && promtool test rules "$SCR/rules/test.yml"
```

Expected: `rules: 11`, then `FAILED:`, with the firing cases reporting `expected … got: []` for
`TrueNASCloudSyncStale`, `TrueNASCloudSyncDisabled` and `TrueNASOffsiteReviewDue`.

- [ ] **Step 3: Add the rule group**

Append to `components/cluster-config/truenas-exporter/templates/prometheusrule.yaml`, at the same indentation as
`- name: truenas-disks`:

```yaml

    # Cloud Sync backup tasks -- the Synology copy (05:00) and the offsite copy
    # to the Hetzner Storage Box (06:00). TrueNAS mails a FAILED run itself;
    # what nothing else catches is a task that stops running, or goes on
    # failing after that first mail. Metrics: collect_cloudsync in the
    # textfile collector. Spec:
    # docs/superpowers/specs/2026-10-13-offsite-backup-storage-box-design.md
    - name: truenas-backups
      rules:
        # The last success comes from Prometheus history, not from the current
        # series: the collector exports it only while the LAST job succeeded,
        # so one failed or running job would otherwise hide when the last good
        # one was. 7d sits well inside this Prometheus's 15d retention.
        - alert: TrueNASCloudSyncStale
          expr: |
            (time() - max_over_time(truenas_cloudsync_last_success_timestamp_seconds[7d])) > 36 * 3600
              and on(task) truenas_cloudsync_enabled == 1
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Backup task without a successful run for {{ "{{" }} $value | humanizeDuration {{ "}}" }}"
            description: |
              Cloud Sync task "{{ "{{" }} $labels.task {{ "}}" }}" runs daily, and its
              last successful run ended {{ "{{" }} $value | humanizeDuration {{ "}}" }} ago.
              Read the last job (never print the whole reply -- it carries the
              credential's password):
              `ssh truenas_admin@192.168.1.25 "midclt call cloudsync.query" | jq '.[] | {description, state: .job.state, finished: .job.time_finished, error: .job.error}'`

        - alert: TrueNASCloudSyncStale
          expr: |
            (time() - max_over_time(truenas_cloudsync_last_success_timestamp_seconds[7d])) > 72 * 3600
              and on(task) truenas_cloudsync_enabled == 1
          for: 15m
          labels:
            severity: critical
          annotations:
            summary: "Backup task without a successful run for {{ "{{" }} $value | humanizeDuration {{ "}}" }}"
            description: |
              Cloud Sync task "{{ "{{" }} $labels.task {{ "}}" }}" has missed three
              nightly runs in a row. For the offsite task, the only copy outside
              the house is now that old. Read the last job as in the warning.

        # A task that has never succeeded has no success series at all, and one
        # whose last success has left the 7-day window has none either -- the
        # two rules above see nothing in both cases.
        - alert: TrueNASCloudSyncStale
          expr: |
            truenas_cloudsync_enabled == 1
              unless on(task) max_over_time(truenas_cloudsync_last_success_timestamp_seconds[7d])
          for: 1h
          labels:
            severity: critical
          annotations:
            summary: "Backup task has no successful run in 7 days"
            description: |
              Cloud Sync task "{{ "{{" }} $labels.task {{ "}}" }}" is enabled and has
              not succeeded in the last 7 days, or ever. Right after playbook.yml
              creates a task this fires until its first run. Otherwise read the
              last job:
              `ssh truenas_admin@192.168.1.25 "midclt call cloudsync.query" | jq '.[] | {description, state: .job.state, finished: .job.time_finished, error: .job.error}'`

        - alert: TrueNASCloudSyncDisabled
          expr: truenas_cloudsync_enabled == 0
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "Backup task disabled: {{ "{{" }} $labels.task {{ "}}" }}"
            description: |
              A disabled Cloud Sync task makes no backup, and the staleness rules
              skip it. If this was not deliberate: the task is declared in
              ansible/truenas/group_vars/all.yml (`enabled`); re-run playbook.yml.

        # The Storage Box is a BX11 (1 TB), sized for ~350 GB growing ~100 GB a
        # year. This reads the whole dataset -- including the excluded thumbs/
        # and encoded-video/ and local snapshots -- so it fires early, which is
        # the safe side. The box's own usage, snapshots included, is visible
        # only in Hetzner's console.
        - alert: TrueNASOffsiteReviewDue
          expr: truenas_dataset_used_bytes{dataset="tank/immich"} > 800e9
          for: 6h
          labels:
            severity: warning
          annotations:
            summary: "tank/immich passed 800 GB: review the 1 TB Storage Box"
            description: |
              Choose the 5 TB plan (BX21) or a bucket before the box fills. The
              comparison is in blog/blog-offsite-backup-draft.md (2026-10-13).
              Check the box's real usage, snapshots included, in Hetzner's console.
```

- [ ] **Step 4: Run the tests again, and check the full rules**

```bash
SCR=/private/tmp/claude-501/-Users-vadzimdziadziulia-laptop-Projects-homelab/9d295bb3-47d4-4b19-acac-3a116a4ccd2b/scratchpad
bash "$SCR/rules/render.sh" && promtool check rules "$SCR/rules/rules-full.yml" && promtool test rules "$SCR/rules/test.yml"
```

Expected: `rules: 16`, `SUCCESS: 16 rules found`, then `SUCCESS` from the unit tests.

- [ ] **Step 5: Chart validation and the live comparison**

```bash
cd /Users/vadzimdziadziulia-laptop/Projects/homelab
helm lint components/cluster-config/truenas-exporter/ --skip-schema-validation
helm template truenas-exporter components/cluster-config/truenas-exporter -n truenas-exporter \
  -f components/cluster-config/truenas-exporter/values.yaml --skip-schema-validation | \
  kubeconform -strict -ignore-missing-schemas -summary -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Expected: `1 chart(s) linted, 0 chart(s) failed`, and a kubeconform summary with `0 errors` and `0 invalid`.

Then the read-only comparison with the live object. Run it unsandboxed, because it reads `~/.kube`:

```bash
SCR=/private/tmp/claude-501/-Users-vadzimdziadziulia-laptop-Projects-homelab/9d295bb3-47d4-4b19-acac-3a116a4ccd2b/scratchpad
KUBECONFIG=~/.kube/config-readonly oc -n truenas-exporter get prometheusrule truenas -o json | jq -S '.spec' > "$SCR/rules/live.json"
yq -o json '.spec' "$SCR/rules/rendered.yaml" | jq -S . > "$SCR/rules/new.json"
diff "$SCR/rules/live.json" "$SCR/rules/new.json" | grep -c '^>'; diff "$SCR/rules/live.json" "$SCR/rules/new.json" | grep -c '^<'
```

Expected: `0` lines removed (`<`), and added lines (`>`) only inside the new `truenas-backups` group. Read the diff
once to confirm that.

- [ ] **Step 6: Docs**

**`components/cluster-config/truenas-exporter/README.md`, line 20.** Change to:
`| \`templates/prometheusrule.yaml\` | 16 alerts: exporter down, collector stale, SMART unreadable, pool health/capacity/scrub, disk SMART/sectors/temperature, Cloud Sync stale (36 h / 72 h / none in 7 days) and disabled, offsite review at 800 GB |`

**`ansible/truenas/README.md`.** Replace the closing paragraph of "Backup tasks (Cloud Sync)", the one starting "A
failed run raises a TrueNAS alert", with:

```markdown
A failed run raises a TrueNAS alert, which is mailed like every other alert. A task that stops
running is caught in the cluster: the textfile collector exports each task's last job
(`truenas_cloudsync_*`), and `TrueNASCloudSyncStale` fires 36 h (warning) and 72 h (critical)
after the last success, or when an enabled task has none in 7 days.
`TrueNASCloudSyncDisabled` covers a disabled task. Rules:
`components/cluster-config/truenas-exporter/templates/prometheusrule.yaml`.
```

- [ ] **Step 7: Commit**

```bash
cd /Users/vadzimdziadziulia-laptop/Projects/homelab
git add components/cluster-config/truenas-exporter/templates/prometheusrule.yaml components/cluster-config/truenas-exporter/README.md ansible/truenas/README.md
git commit -m "truenas-exporter: alert on stale or disabled Cloud Sync tasks and the offsite review point"
```

---

### Task 5: Docs for the build, then push

**Files:**
- Modify: `CLAUDE.md` (the Immich-on-TrueNAS bullet under "Non-cluster infrastructure")
- Modify: `README.md` (TODO "Immich library: preserve offsite coverage…", the **State 2026-10-14** sentence)
- Modify: `docs/superpowers/specs/2026-10-13-offsite-backup-storage-box-design.md` (status lines 3–5)
- Modify: `blog/blog-offsite-backup-draft.md` (new section)
- Memory: `project_offsite_backup_inflight.md`, the `MEMORY.md` line; vault note
  `_memory/chats/homelab/2026-10-13-offsite-backup-hetzner-storage-box.md`

**Interfaces:** consumes the commit hashes of Tasks 1–4 (`git log --oneline -5`).

- [ ] **Step 1: CLAUDE.md**

Replace this passage:

> "The only copy of the photos off that box is a nightly TrueNAS Cloud Sync task … the old C2 task still reports
> green against a frozen directory."

with:

```markdown
Two nightly TrueNAS Cloud Sync tasks copy the photos off that box: 05:00 into the Synology share folder
  `photo/backups/immich` (`COPY` on purpose, so a deletion in Immich never propagates there) and 06:00 to a Hetzner
  Storage Box sub-account (`SYNC`; history from the box's weekly snapshots × 10). The offsite task is in code since
  2026-10-14 and exists on the box once `playbook.yml` has run; until its restore test passes, the old C2 task keeps
  reporting green against a frozen directory. Both tasks alert in the cluster when stale (`TrueNASCloudSyncStale`).
```

- [ ] **Step 2: README TODO and spec status**

In `README.md`, replace the sentence that starts "**The box was ordered 2026-10-14**" with:
"**The box was ordered and set up 2026-10-14; the spec was approved the same day and the code is in git** (role
`transfers`, the offsite credential and task, collector metrics, alerts — commits `<t1>`…`<t4>`). Next: the operator
runs `playbook.yml`, then the first run and the restore test (plan
`docs/superpowers/plans/2026-10-14-offsite-backup-storage-box.md`, Part B)."

In the spec, set lines 3–5 to:
"Status: approved by the operator 2026-10-14. The box was ordered and set up 2026-10-14. Built in git 2026-10-14
(plan `docs/superpowers/plans/2026-10-14-offsite-backup-storage-box.md`); rollout from step 3 on."

- [ ] **Step 3: Blog section**

Append `### 2026-10-14 — built in git, tested against stand-ins` to `blog/blog-offsite-backup-draft.md`, with:
- the four commits, one line each;
- the role harness: what the fake checks, and the case table (case → result) from `$SCR/cs/logs/` and the
  `check.py` output, including the RED run of `t1-create` and `t2-create`;
- the collector test: the seven fixture states and the RED → GREEN counts. Note that the real-box run in Task 3
  Step 5 returned the Synology task's five lines and no secret;
- the promtool tests: the four scenarios, RED (`rules: 11`, FAILED) → GREEN (`16 rules`, SUCCESS);
- what the stand-ins cannot prove: the box's SFTP path layout, the connection limit, real rclone behaviour. Those
  wait for Part B.

No host names, users or passwords.

- [ ] **Step 4: Commit**

```bash
cd /Users/vadzimdziadziulia-laptop/Projects/homelab
git add CLAUDE.md README.md docs/superpowers/specs/2026-10-13-offsite-backup-storage-box-design.md blog/blog-offsite-backup-draft.md
git commit -m "docs(offsite-backup): the Storage Box leg is built in git"
```

- [ ] **Step 5: Memory and vault note**

Memory, `project_offsite_backup_inflight.md`:
- built in git 2026-10-14, with the commits;
- next is the operator's playbook run, then Part B;
- update the `MEMORY.md` line to match.

Vault note:
- `status_detail`: "Built in git 2026-10-14; waiting for the operator's playbook run."
- Next action: the playbook run, then Part B.

- [ ] **Step 6: Final review, then push**

1. Run the final whole-branch review that the execution skill prescribes, over `28a00cb..HEAD` minus the docs-only
   commits.
2. Fix and ledger any findings.
3. Push, unsandboxed: `git push origin master`.

Then check, read-only. Expected: `Synced Healthy <HEAD sha>`, and the group list ends with `truenas-backups`.

```bash
KUBECONFIG=~/.kube/config-readonly oc -n openshift-gitops get application truenas-exporter -o jsonpath='{.status.sync.status} {.status.health.status} {.status.sync.revision}{"\n"}'
KUBECONFIG=~/.kube/config-readonly oc -n truenas-exporter get prometheusrule truenas -o jsonpath='{.spec.groups[*].name}{"\n"}'
```

Rule health in Prometheus. This is a read through the break-glass kubeconfig, which the operator authorised for
checking alerts:

```bash
KUBECONFIG=~/.kube/config-breakglass oc -n openshift-user-workload-monitoring exec prometheus-user-workload-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/rules?type=alert' | jq -c '.data.groups[] | select(.name=="truenas-backups") | .rules[] | {name, health, state}'
```

Expected: five rules, each `"health":"ok"` and `"state":"inactive"`. No `truenas_cloudsync_*` series exists yet, and
`tank/immich` is far below 800 GB. If the exec is refused, say so and leave this check for Task 7 Step 4. That
step's `ALERTS` query only answers if the rules loaded.

---

# Part B — rollout on the box (operator-gated)

Each task starts only on the operator's word. Every printed read of `cloudsync.query` or `cloudsync.credentials.query`
goes through a `jq` filter that names its fields.

### Task 6: Operator converges (spec rollout step 3)

- [ ] **Step 1 — Operator:**

```bash
cd ansible/truenas && ansible-playbook -i inventory.yml playbook.yml --ask-vault-pass
```

Expected:
- "Create missing Cloud Sync credentials" changed for `hetzner-storagebox`;
- "Create missing Cloud Sync tasks" changed for the offsite task;
- "Install the node_exporter textfile collector" changed;
- the convergence report has `cloudsync_tasks_missing: []` and `cloudsync_tasks_without_secrets: []`;
- `failed=0`.

- [ ] **Step 2: Me, read-only.** Run it unsandboxed (SSH).

```bash
ssh truenas_admin@192.168.1.25 "midclt call cloudsync.credentials.query" | jq -c '.[] | {id, name, type: .provider.type, port: .provider.port}'
ssh truenas_admin@192.168.1.25 "midclt call cloudsync.query" | jq -c '.[] | {id, description, enabled, transfers, transfer_mode, snapshot, path, folder: .attributes.folder, schedule, exclude, cred: .credentials.name}'
```

Expected:
- two credentials;
- the offsite task with the fields in Global Constraints, `transfers: 2` and `cred: "hetzner-storagebox"`;
- the Synology task unchanged, with `transfers: null`.

Note the two ids as `HZ_CRED` and `HZ_TASK`. Task 7 should start within the hour; otherwise the third Stale rule
fires for a task that has not run yet. That's harmless but noisy.

- [ ] **Step 3 — Operator: converge a second time** (spec, Verification). Expected: every Cloud Sync task reads `ok`
  or `skipping`, and none reads `changed`.

### Task 7: First run (spec rollout step 4) — go-ahead required

- [ ] **Step 1: The sub-account's view.** Run it unsandboxed.

```bash
ssh truenas_admin@192.168.1.25 "midclt call cloudsync.list_directory '{\"credentials\": HZ_CRED, \"attributes\": {\"folder\": \"/\"}}'" | jq -c '[.[] | {Name, IsDir}]'
```

Expected: `[]`, an empty root with no `.zfs`. Anything else means stop and report. If the layout differs from what
`/immich` assumes, fix `folder` in group_vars, re-run the Task 2 harness and commit. The operator converges again
before any run.

- [ ] **Step 2: Run it by hand.**

```bash
ssh truenas_admin@192.168.1.25 "midclt call --job cloudsync.sync HZ_TASK" | tail -3
ssh truenas_admin@192.168.1.25 "midclt call cloudsync.query" | jq -c '.[] | select(.id==HZ_TASK) | {state: .job.state, started: .job.time_started, finished: .job.time_finished}'
```

Expected: the job ends, and the state reads `SUCCESS`.

- [ ] **Step 3: Read the log, redacted.**

```bash
ssh truenas_admin@192.168.1.25 "midclt call cloudsync.query" | jq -r '.[] | select(.id==HZ_TASK) | .job.logs_excerpt' \
  | sed -E 's/u[0-9]+(-sub[0-9]+)?(\.your-storagebox\.de)?/<box>/g' \
  | grep -i -E 'error|refused|handshake|too many|denied|failed|Transferred:' | tail -10
```

Expected: only `Transferred:` lines, ending at 100 %. No error line at all.

If there are refused connections or SSH handshake errors (the 10-connection limit):
1. set `transfers: 1` in group_vars;
2. re-run the Task 2 harness (`t2-create` expects 2, so change its `want` to 1 first) and commit;
3. the operator converges;
4. repeat Step 2.

- [ ] **Step 4: Metrics, on the next 5-minute collector run.**

```bash
ssh truenas_admin@192.168.1.25 "grep '^truenas_cloudsync' /mnt/tank/monitoring/textfile/truenas.prom"
KUBECONFIG=~/.kube/config-breakglass oc -n openshift-user-workload-monitoring exec prometheus-user-workload-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=ALERTS%7Balertname%3D~%22TrueNASCloudSync.%2A%22%7D' | jq -c '.data.result'
```

Expected: ten lines (two tasks × five metrics), both `last_job_success … 1`, and `[]` alerts.

- [ ] **Step 5:** Append the first-run chronology to the blog draft (commands and redacted output), then commit and
  push.
- [ ] **Step 6 — Optional, the operator's call: see one alert fire and clear.**
  1. Set `enabled: false` on the offsite task in group_vars and commit.
  2. The operator converges between two nightly runs.
  3. `TrueNASCloudSyncDisabled` should fire after 1 h.
  4. Revert, commit, and the operator converges; it should clear.

  This costs two playbook runs and no backup run.

### Task 8: Full pull-back restore (spec rollout step 5) — go-ahead required

`tank/backup` takes a snapshot every 6 hours and keeps it 90 days (`group_vars/all.yml`, snapshot tasks). A restore
directory that exists while a snapshot runs is pinned for 90 days after it is deleted. That is negligible at today's
~2 GB; Task 11 has to decide it at full size.

- [ ] **Step 1: The accepted fields.**

```bash
ssh truenas_admin@192.168.1.25 "midclt call core.get_methods" | jq -c '."cloudsync.sync_onetime".accepts | map(.properties? // {} | keys)'
```

Build the payload from the keys this returns. The expected shape is `path`, `credentials`, `attributes`,
`direction`, `transfer_mode`, `transfers`, and possibly `snapshot` and `exclude`. If a required key is not in that
list, ledger it.

- [ ] **Step 2: Push fresh, then pull back.**

1. Run Task 7 Step 2 again and note `date -u +%s` before it, as `PUSH_START`.
2. Create the directory: `ssh truenas_admin@192.168.1.25 "sudo -n mkdir /mnt/tank/backup/restore-test-$(date +%Y%m%d)"`.
   If sudo asks for a password, the operator runs it as
   `! ssh -t truenas_admin@192.168.1.25 sudo mkdir /mnt/tank/backup/restore-test-<date>`.
3. Pull back:

```bash
ssh truenas_admin@192.168.1.25 "midclt call --job cloudsync.sync_onetime '{\"path\": \"/mnt/tank/backup/restore-test-DATE\", \"credentials\": HZ_CRED, \"attributes\": {\"folder\": \"/immich\"}, \"direction\": \"PULL\", \"transfer_mode\": \"COPY\", \"transfers\": 2}'" | tail -3
```

- [ ] **Step 3: Compare.** Unsandboxed. The checksum lists stay in `$SCR/restore/` and are never pasted, because they
  carry file names.

```bash
SCR=/private/tmp/claude-501/-Users-vadzimdziadziulia-laptop-Projects-homelab/9d295bb3-47d4-4b19-acac-3a116a4ccd2b/scratchpad
mkdir -p "$SCR/restore"
ssh truenas_admin@192.168.1.25 "cd /mnt/tank/immich && find . -type f ! -path './thumbs/*' ! -path './encoded-video/*' -print0 | sort -z | xargs -0 sha256sum" > "$SCR/restore/src.sha"
ssh truenas_admin@192.168.1.25 "cd /mnt/tank/backup/restore-test-DATE && find . -type f -print0 | sort -z | xargs -0 sha256sum" > "$SCR/restore/dst.sha"
wc -l < "$SCR/restore/src.sha"; wc -l < "$SCR/restore/dst.sha"; diff "$SCR/restore/src.sha" "$SCR/restore/dst.sha" | grep -c '^[<>]'
```

If either side says `Permission denied`, use `sudo -n`.

Expected: equal counts and `0` differing lines. Any difference is explained only by a file with ctime after
`PUSH_START` (`find . -newerct @PUSH_START`). Anything else is a failure: stop and report.

- [ ] **Step 4: Delete the test directory.** This is destructive and needs its own go-ahead.

1. `ssh truenas_admin@192.168.1.25 "ls -ld /mnt/tank/backup/restore-test-DATE"`, to see the exact target.
2. `ssh truenas_admin@192.168.1.25 "sudo -n rm -rf /mnt/tank/backup/restore-test-DATE"`.

- [ ] **Step 5:** Append the blog chronology: duration, counts, result. Then commit and push.

### Task 9: One file from a box snapshot (spec rollout step 6) — operator

- [ ] **Step 1 — Operator:** Hetzner console → Storage Box → Snapshots → **Take manual snapshot**. Note its name.
- [ ] **Step 2: Me.** Pick one photo from `$SCR/restore/src.sha`. Give the operator its relative path and keep its
  hash to compare.
- [ ] **Step 3 — Operator, from the Mac:** connect over SFTP with the **main** account. The console shows the server
  and user; the password is in the password manager. Fetch
  `/.zfs/snapshot/<name>/truenas/immich/<relative path>`, then run `! shasum -a 256 <file>` here.

  If `/.zfs` is not at the main account's root, or `truenas/` is not under the snapshot, list the directory and tell
  me what is there. That answers the spec's open path-layout question.
- [ ] **Step 4: Me.** Compare the hash with `src.sha`. Expected: identical.
- [ ] **Step 5 — Operator:** delete the manual snapshot in the console, so it does not hold one of the 10 slots.
- [ ] **Step 6:** Blog section, commit, push.

### Task 10: Retire C2 (spec rollout step 7) — operator, after Tasks 8 and 9 pass

- [ ] **Step 1 — Operator:**
  - In DSM, retire `Synology_C2_immich_photos_task`.
  - Cancel the C2 plan if nothing else uses it. Whether anything does is not recorded in this repo, so check in the
    C2 console first.
- [ ] **Step 2: Me, docs.**
  - Remove the README TODO "Immich library: preserve offsite coverage…".
  - Add one sentence to the existing "Family archive import" TODO: after the import, repeat the offsite pull-back at
    full size and record its duration (Task 11).
  - `CLAUDE.md`: C2 is retired; the offsite task is live and verified.
  - `ansible/truenas/README.md`: drop "until its restore test passes" wording, if any.
  - Spec status: "Rollout steps 1–7 done <date>."
  - Blog section.
  - Memory and vault note.
  - Commit and push.

### Task 11: Full-size drill (spec rollout step 8) — after the archive import

- [ ] **Step 1:** Before starting, the operator decides where the restore lands. At full size (~350–400 GB), a
  `tank/backup` directory is caught by its 6-hourly snapshots and stays pinned for 90 days. The options are:
  accept that, or name a dataset without periodic snapshots.
- [ ] **Step 2:** Run Task 8 at full size, timing the pull-back. Record its duration as the restore time in the blog
  and in the README TODO it closes.
