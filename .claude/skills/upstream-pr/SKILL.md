---
name: upstream-pr
description: Writing rules for any PR body, PR comment or issue on an upstream repository (okd-operator-pipeline, okderators-catalog-index, Rook, cert-manager, OVN-Kubernetes, loki-operator, etc.) — draft-first, plain declarative style, length matched to the change. Use before drafting, editing or posting any upstream PR, issue or comment, including follow-ups, backports and cherry-picks.
---

# Upstream PRs and comments — always draft first, always plain

Applies to every PR body, PR comment, and issue I write on an upstream repo.

**Draft first, no exceptions.** Open every PR with `--draft`, show the user the title and body, and leave it
draft until they say otherwise. Marking a PR ready for review is the user's call, never mine — the same way
merging is. This applies even when the user says "open a PR": open it as a draft and tell them it is waiting.

**Write the change, not the story of finding it.** A PR body states what changed, why, and how it was checked.
It is not a narrative of my debugging session. Concretely, cut all of this:

- Self-reference and process confession — "I missed it myself at first", "I thought this was a one-line bump",
  "I expected X". The reviewer does not care what I expected.
- Meta-commentary about the writing — "worth saying explicitly", "worth a look", "the interesting part",
  "no point repeating it here".
- Editorialising adjectives — "scary", "nasty", "tricky", "surprisingly". Say what the output is; the reader
  judges it.
- Conversational headings — "The stuff I didn't expect", "Built it to make sure it compiles". Use flat labels:
  "Build", "Verification", "Why 1.20".
- Rhetorical framing — "Two disconnected heads, and 1.18 stays the head." State it once, plainly.

**Shape:** short declarative sentences. One fact per sentence. Prefer a command and its real output over prose
describing the output. Tables and lists over paragraphs. No em-dash asides stacked mid-sentence. If a sentence
survives having its adjectives removed, remove them.

**Keep:** exact versions, hashes, branch names, error strings, and the commands that produced them. Precision is
the thing that makes the PR useful; the prose around it is not.

**Test before posting:** would this read the same if a stranger wrote it about someone else's work? If it only
makes sense as *my* account of *my* afternoon, rewrite it.

**Match the length to the change.** A PR body is sized by what a reviewer has to decide, not by how much work
went into it. A cherry-pick, backport or follow-up says what it is, why that branch needs it, and links the
original — three or four lines. It does NOT restate the original's rationale or repeat its verification; that is
what the link is for. Reserve the full treatment for the PR that actually carries the argument. Likewise a
one-line version bump does not need headings.
