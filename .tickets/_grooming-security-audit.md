# Grooming — security audit follow-up (imported fork findings)

Source material: [`docs/security/README.md`](../docs/security/README.md) (finding
catalog) and [`docs/security/verification.md`](../docs/security/verification.md)
(verdicts). Raw patches in `docs/security/patches/`.

## What the audit actually concluded

**All 20 findings imported from the `kgroyalty/Social-Media-Studio` fork are already
fixed in our tree.** There is nothing to back-port. The fork's audit was upstreamed
by its own author between 2026-05-11 and 2026-05-12; our `main` is `0 ahead / 0
behind` `upstream/main`, so we have all of it.

The real output of this exercise is three things the audit did *not* cover:

1. **SEC-21** — a live High-severity issue that neither the fork nor upstream fixed.
   Detail held privately; see the disclosure gate below.
2. **SEC-22 / SEC-23** — two Low defence-in-depth gaps, one of them in a surface
   upstream added *after* the fork diverged. Detail held privately.
3. **The sync-discipline problem** — upstream ships security fixes under
   deliberately neutral commit messages ("internal cleanup across multiple apps"
   was a fix for a live, externally-reported stored XSS), with 0 releases, 0 tags,
   and 0 published advisories. There is no channel that tells you a security fix
   shipped. Sync cadence *is* the security control.

## ⚠️ Disclosure gate — read before opening any PR or writing any commit message

SEC-21 is a **live vulnerability in upstream code**, in a public project with 2,150
stars and an unknown number of self-hosters. Upstream `SECURITY.md` asks for private
reporting to `security@brightbean.xyz` and coordinated disclosure, and their own
commit-message practice shows they deliberately avoid publishing exploit detail.

**This fork — `nick-buser/brightbean-studio` — is a PUBLIC repository.** So the
disclosure surface is not just an upstream PR: a commit message, a branch name, a
ticket file, or a PR title in *our own* repo is equally public. A commit named after
the vulnerability class is a working 0-day pointer for every unpatched self-hoster,
because the fix diff shows exactly what was wrong.

Rules for this work:
- Vulnerability detail lives **only** in `docs/security/LIVE-FINDINGS.local.md`,
  which is gitignored. Never commit it.
- Commit messages, branch names, and ticket text stay neutral — describe the
  refactor ("scope a query, reorder two checks"), never the exploit.
- Sequence: patch our own fork → report privately upstream → let them coordinate
  the public fix and disclosure.

This is a **`Decision needed`** item — the human sends the disclosure email and
decides the upstream-contribution path. It must not be auto-merged by a loop.

---

## Proposed tickets

Numbers are provisional; `/branch-new` recomputes at claim time.

### fix-0001 — SEC-21 (High, live) — details held privately

**Priority: 1.** The only real vulnerability found; everything the fork's audit
covered is already fixed in our tree.

**Detail is deliberately not in this file.** This repo is public and SEC-21 is live
and unpatched upstream. Scope, exploit path, file:line analysis, and the suggested
fix are in **`docs/security/LIVE-FINDINGS.local.md`** (gitignored, local disk only).

Sizing, safe to state publicly: roughly a 10-line change plus a regression test.

**Acceptance criteria**
- [ ] The out-of-scope operation is refused.
- [ ] The refusal happens **before** any write — assert unchanged DB state after the request.
- [ ] The legitimate in-scope operation still works on both permitted paths.
- [ ] `make test` / `make lint` / `make typecheck` green.

**Notes.** Keep the diff minimal and the commit message neutral — this is a public
fork, and a commit titled after the vulnerability class discloses it. See the
disclosure gate above.

---

### fix-0002 — SEC-23 (Low) — details held privately

**Priority: 3.** Not a security bug — render-time escaping is the boundary and holds.
Two write paths simply miss the input bound that every sibling path enforces. One of
them is in an endpoint upstream added *after* the fork's audit, which is the concrete
proof that a one-time audit does not cover continuously-arriving upstream surface.

Detail in `docs/security/LIVE-FINDINGS.local.md`.

**Acceptance criteria**
- [ ] Both paths route through the shared normalization helpers.
- [ ] The API path returns 400 with a useful message rather than truncating silently.
- [ ] Tests cover over-count and over-length on both paths.
- [ ] Gates green.

---

### fix-0003 — SEC-22 (Low) — details held privately

**Priority: 3.** Defence-in-depth. Not currently exploitable — a later egress check
already refuses the bad value, so nothing leaves the box. Worth closing so the
stored-data layer doesn't depend solely on the egress layer.

Detail in `docs/security/LIVE-FINDINGS.local.md`.

**Acceptance criteria**
- [ ] Validation runs on the currently-skipped path (decide and record whether the
      full check or only the URL check applies, and why).
- [ ] Test asserts the unsafe value cannot be persisted via that path.
- [ ] Gates green.

---

### chore-0001 — sync discipline: mostly ALREADY DONE, two gaps left

**Status: superseded in large part.** Parallel work on branch
`chore/fork-sync-workflow` (commit `9a70a51`) already built the standing control
this ticket was going to propose: `bin/sync-upstream.sh` (154 lines, with
`--check` / `--push` modes) and `docs/FORK-WORKFLOW.md` (93 lines) establishing the
`main` = pristine mirror / `trunk` = deploy branch split. That design is better than
what this grooming pass would have proposed — in particular it correctly identifies
that deploying `trunk` rather than `main` is what stops an upstream merge from
reaching production unreviewed, and it documents branching from `main` (not `trunk`)
to contribute a fix upstream without dragging our deploy config along.

**Do not re-propose a competing scheme.** Read `docs/FORK-WORKFLOW.md` first.

**Why this still matters.** Upstream patches security silently — see
`docs/security/verification.md`, "The strategic finding". No advisories, no
releases, sanitized commit messages, `SECURITY.md` supports only "latest on `main`".
You cannot distinguish a security sync from a cosmetic one, so the only safe posture
is: sync everything, promptly. `kgroyalty` is the worked failure mode — ran this
exact audit, then drifted to 196 commits behind, and is now missing three months of
silent patches it cannot enumerate. The sync script makes this cheap; what's missing
is a *cadence* and a *gate*.

**Remaining scope (the actual gaps).**
- **Cadence.** `bin/sync-upstream.sh --check` reports drift but nothing runs it on a
  schedule. Decide: weekly reminder, cron, or CI job. Must not be a loop that
  idle-waits on a human — it either reports drift or exits quiet.
- **Post-sync gate.** Nothing runs `make test && make lint && make typecheck`
  between the upstream merge and the `--push` that deploys. Wire the gate into the
  script (or into the sync procedure) so an upstream regression can't ride to
  production on a green-looking merge.
- **Shrink the conflict set (optional, do when it first hurts).** `FORK-WORKFLOW.md`
  names `README.md`, `railway.toml`, `.gitignore` as the recurring conflict files.
  `git config rerere.enabled true` makes each one a one-time resolve. For *future*
  custom code, prefer additive surfaces that upstream will never touch —
  `config/settings/custom.py` importing `production` and appending `INSTALLED_APPS`;
  `config/urls_custom.py` importing `config.urls`' `urlpatterns` and appending;
  registering new providers into `PROVIDER_REGISTRY` from our own
  `AppConfig.ready()` rather than editing `providers/__init__.py`.

**Acceptance criteria**
- [ ] `chore/fork-sync-workflow` and `docs/railway-deploy-corrections` merged into `trunk`.
- [ ] A scheduled drift check exists and is documented in `FORK-WORKFLOW.md`.
- [ ] The gate command runs between upstream merge and deploy push.
- [ ] `rerere` enabled locally.

---

### `Decision needed` — report SEC-21 upstream

**Not a code ticket. Human action. Must not be claimed by an autonomous loop.**

Draft and send a private report for SEC-21 to `security@brightbean.xyz` per
upstream `SECURITY.md` (ack within 48h, status within 7 days, coordinated
disclosure). Include the file:line analysis, the check-ordering table, and the
suggested fix from fix-0001.

Open questions for the human:
- Send the report before or after landing fix-0001 in our fork? (Recommend: patch
  ours first — it is a private fork, and we are one of the affected deployments.)
- Do we offer the fix as a PR once they acknowledge, or hand them the analysis and
  let them write it? Their call, coordinated over email.
- Do we want attribution/credit, or report anonymously?

---

## Ordering

1. **fix-0001** (live vuln, ours to patch immediately)
2. **`Decision needed`** disclosure email — human, can run in parallel with 1
3. **chore-0001** remaining gaps (cadence + gate) — small now that the script exists
4. **fix-0002**, **fix-0003** (low, batch them)

## Workflow for these tickets

Per `docs/FORK-WORKFLOW.md`: branch off **`trunk`**, PR back into **`trunk`**.
Never branch off `main` for our own work — `main` is the pristine upstream mirror.

The one exception is the SEC-21 fix *if* we end up contributing it upstream: that
branch comes off `main` and cherry-picks the commit, so the PR to `brightbeanxyz`
doesn't drag our deployment config with it. See FORK-WORKFLOW's "Contributing back
upstream". Gate that on the disclosure decision below.

## Notes / friction log

- **Parallel-session collision.** This grooming pass started from a working tree
  showing `railway.toml` + `README.md` as uncommitted, and part-way through they
  vanished — another session had committed them to `docs/railway-deploy-corrections`
  and created `trunk` + `chore/fork-sync-workflow` underneath us. Nothing was lost,
  but the original `chore-0001` was drafted in ignorance of `FORK-WORKFLOW.md` and
  had to be rewritten to stop competing with it. Worth flagging as real multi-agent
  friction: **re-check `git branch -vv` and the reflog before grooming infra tickets
  in a repo that another session may be touching.**
- **CI is the only way to run the test suite from this machine.** There is no
  Django and no venv here, and the standing disk rule forbids installing runtimes
  or heavy dependencies without explicit per-instance approval. `ruff check` and
  `ruff format --check` do run locally (ruff is installed standalone); `pytest` and
  `mypy` do not. Don't go looking for a cheaper local route — there isn't one.
  Corollary: **CI must actually cover the branch you're working on**, which is why
  `chore/ci-gate-trunk` (PR #4) mattered more than it looked.
- **A regression test that has never been observed failing may be vacuous.** Worth
  proving red-before-green for anything guarding an authorisation path. On a public
  fork that is not always free to do immediately — a public Actions log showing
  security tests red is a reproducible exploitability demonstration against anyone
  still unpatched, so the proof may have to wait for a disclosure window to close.
  Budget for it rather than skipping it.
- `.github/workflows/ci.yml` is now fork-modified (PR #4), so it joins the list below.
- `railway.toml`, `README.md`, `.gitignore` are the known recurring conflict files
  (per FORK-WORKFLOW). No additive escape hatch for `railway.toml`; `rerere` after
  the first resolve is the mitigation.
- Explicitly **not** adopting fork commit `f370b1b` (`FORCE_HTTPS` defaulting to
  False, Caddy removed from prod compose). It is a deliberate security loosening
  for a bare-IP VPS; Railway terminates TLS for us.
