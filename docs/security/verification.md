# Verification pass — are the fork's findings still live in our tree?

Method: for each finding in [`README.md`](./README.md), read the fork's patch hunk,
then read the *current* code, then decide. A finding counts as PRESENT only if the
protection is actually **invoked on the vulnerable path** — a validator that exists
but is never called is MISSING, not PRESENT.

Verified against `main` @ `d85fce1`, which at the time of writing is `0 ahead / 0
behind` `upstream/main`.

## Headline result

**Every one of the fork's 20 findings is already fixed in our tree.** Nothing needs
to be back-ported. The fork's security work *was* upstreamed — by the same author,
`Jan Schmitz` — between 2026-05-11 and 2026-05-12. It only appeared as "24 commits
ahead" because the fork's copies carry different SHAs.

Upstream commits carrying this work, all confirmed ancestors of our `main`:

| Fork commit | Upstream commit | Upstream's message |
|---|---|---|
| `4d5a156` | `abde1e9` | add json_attr template filter and tag-input normalization helper |
| `13999eb` | `4b48bf5` | treat empty string as empty array in json_attr (new-post regression) |
| `4e708ac` | `6a81084` | composer media asset removal improvement |
| `7264d31` | `f483a76` | internal RSS feed handling adjustment |
| `c912805` | `55c3557` | internal cleanup: shared validators, composer, and notifications |
| `dee5ebc` | `6f9e439` | RSS feed: handle relative and scheme-relative redirect Location headers |
| `091f02a` | `e0ce74c` | internal cleanup across multiple apps |
| `af0f434` | `b4652d8` | fix CI: register default FileSystemStorage on local, cast helper return to str |
| `1f2bca2` | `928791d` | fix: workspace role assignment edit and delete paths |
| `af89c2f` | `c783ab1` | fix: scope new org-role check to admin/owner tier only |

## Per-finding verdicts

All PRESENT. Evidence is `file:line` in the current tree.

### XSS
- **SEC-01** stored XSS in Alpine `x-data` — `apps/common/templatetags/common_extras.py:10-26` (`mark_safe(escape(json.dumps(...)))`), app registered at `config/settings/base.py:52`. All three call sites off `|safe`: `templates/composer/compose.html:1173`, `templates/composer/partials/csv_mapping.html:41`, `templates/media_library/_tag_input.html:4`. Repo-wide sweep: the **only** remaining `|safe` in any template is `templates/onboarding/partials/_checklist.html:99`, which renders `icon_svg` — verified safe: all four values are hardcoded literal `<path>` strings (`apps/onboarding/checklist.py:36,48,60,72`), nothing populates the key from a model field or request, and the SECURITY docstring warning is at `:15-17`. There is no `{% autoescape off %}` outside plaintext email templates. Two call sites upstream added *after* the fork are independently safe — `templates/components/ui_select.html:13` uses `|json_attr`, `templates/composer/partials/idea_card.html:3` uses `|escape` read back via `dataset`.
- **SEC-02** `</script>` breakout — `templates/composer/compose.html:1975-1978` emit all four payloads via `|json_script`, consumed by `JSON.parse` at `:1985-2000`. Remaining interpolations in that block are `|escapejs` literals, UUIDs, and `|yesno`.
- **SEC-03** tag normalization — `apps/common/validators.py:11-12` (`MAX_TAGS=25`, `MAX_TAG_LENGTH=100`), `:78-101` `normalize_tags`, `:104-124` `parse_and_truncate_tag_string`, `:174-197` YouTube variant. Applied at `apps/media_library/views.py:401`, `:1063`, `apps/composer/views.py:162`, `:1144`, `:2520`, `:2603`, and `apps/composer/forms.py:82-86`. See SEC-23 for two write paths it does *not* cover.
- **SEC-04** `json_attr` empty-string → `[]` at `apps/common/templatetags/common_extras.py:24`.
- **SEC-12** SVG dropped from allow-list — `apps/media_library/validators.py:5-11`, `:33`. Confirmed still relevant: `config/settings/base.py:12` defaults `STORAGE_BACKEND=local` and `:204-211` serves `MEDIA_URL=/media/` **same-origin**, so this was a live default-deploy issue, now closed. Belt-and-braces: `sniff_mime` returns `None` for `<svg`/`<?xml` bytes (`validators.py:104`), so a `.png`-named SVG is rejected too.
- **SEC-17** hex-colour validation — validators at `apps/common/validators.py:22,127,139`; attached to all four colour model fields (`apps/calendar/models.py:192`, `apps/composer/models.py:43`, `apps/workspaces/models.py:26-27`) with migrations that no later `AlterField` supersedes.

### RBAC
- **SEC-05 / SEC-06 / SEC-07** — `apps/members/services.py:20-39` (`ORG_ROLE_LEVEL`), `:42-55` (`_inviter_workspace_level`, org-owner short-circuit to level 6), `:90-92`, `:97-109`, `:121-127`, `:272-279`, `:311-319`, and the existing-role guard at `:328-345` covering **both** the demote and delete paths. Wired at `apps/members/views.py:136-143`, `:280`, `:370`.
- **SEC-05 regression** — current code has the *corrected* admin/owner-tier-scoped form, so the client-portal path (`apps/client_portal/views_admin.py:81-109`, `@require_workspace_role("manager")` → `create_invitation(org_role=MEMBER)`) still works.
- **SEC-18** calendar event gating — `@require_permission("create_posts")` at `apps/calendar/views.py:1722`, `:1764`, `:1797`; gate is real (`viewer` has `create_posts: False` at `apps/members/models.py:245-246`).

### SSRF
- **SEC-08** — `apps/common/validators.py:25-49` (`is_safe_url`) / `:52-75` (`resolve_public_ip`): scheme allowlist, hostname required, iterates **all** A/AAAA records, rejects private/reserved/loopback/link-local/multicast.
- **SEC-09** — `apps/composer/views.py:3642-3666`; every periodic fetch routes through `_safe_fetch_feed` (`:3659`). Call path traced to a single egress point; `apps/composer/curated_feeds.py` is a static data module that fetches nothing, and there is no background feed poller.
- **SEC-10** — `apps/composer/views.py:3630` `urljoin(current_url, location)` precedes the `is_safe_url` re-check at `:3631`; `current_url` advances per hop so multi-hop relative chains resolve.
- **SEC-11** — `apps/notifications/engine.py:290` re-validates at dispatch, `:321` `follow_redirects=False`, `:322-323` raises on any 3xx. Reached on first delivery *and* retries.

### IDOR / DoS
- **SEC-15** — `apps/common/validators.py:146-171` `safe_xml_fromstring` (5 MB cap, 4 KB prolog scan rejecting `<!doctype`/`<!entity`). Called at `apps/inbox/webhooks.py:509` and `apps/composer/views.py:3526`. No bypass: the only other `ET.fromstring` in `apps/` is inside the helper itself.
- **SEC-16** — `apps/approvals/views.py:233` scopes the Post lookup **before** mutating; `apps/approvals/comments.py:65-78` `update_comment(..., workspace=)` adds `post__workspace` filter.
- **SEC-19** — `apps/calendar/views.py:1594-1596`.
- **SEC-20** — `apps/calendar/views.py:1436-1439`, `:1514-1517`; upstream used `filter(...).first()` + `_missing_slot_response` (`:65-78`) rather than the fork's `get_object_or_404`, but the security property holds (workspace predicate lives in the DB query).

## Findings NOT fixed by the fork or upstream — held privately

This verification pass turned up **three findings that neither the fork's audit nor
upstream has fixed**, one of them High severity. Their details are deliberately
**not** in this file.

`nick-buser/brightbean-studio` is a public repository, and these are live,
unpatched issues in upstream `brightbeanxyz/brightbean-studio` — a project with
2,150 stars and an unknown number of self-hosted deployments. Writing the exploit
detail here would publish a working 0-day against every one of them. Upstream
`SECURITY.md` asks for private reporting to `security@brightbean.xyz` with
coordinated disclosure, and their own commit-message practice (see below) shows
they withhold exploit detail until users can patch.

The analysis lives in **`docs/security/LIVE-FINDINGS.local.md`**, which is
gitignored and stays on local disk. It carries the file:line detail, the exploit
path, the suggested fixes, and a disclosure checklist.

Summary without detail:

| ID | Severity | Detail |
|---|---|---|
| SEC-21 | **High** | Detail in `LIVE-FINDINGS.local.md` |
| SEC-22 | Low | Detail in `LIVE-FINDINGS.local.md` |
| SEC-23 | Low | Detail in `LIVE-FINDINGS.local.md` |

These move into this file once upstream has shipped a fix and disclosure has been
coordinated, or once they decline to treat them as vulnerabilities.

## The strategic finding: upstream patches security silently

This matters more than any individual bug above.

Upstream's `e0ce74c` is byte-identical to the fork's `091f02a` (22 files,
980 insertions, 75 deletions, same author) — but the commit message was rewritten:

> **Fork:** `fix audit findings: RBAC hierarchy, color CSS injection, SVG XSS, MIME spoof, SSRF, IDOR`
> …body explicitly references *"the externally reported stored XSS that pivoted to /members/invite/"*.
>
> **Upstream:** `internal cleanup across multiple apps`
> …body re-describes the same changes in neutral language: *"add hex-color and field validators"*, *"switch media_library to magic-byte sniffing"*, *"route XML through a shared parser"*.

The same sanitisation was applied across the batch: `f483a76` "internal RSS feed
handling adjustment" (SSRF), `55c3557` "internal cleanup: shared validators…"
(XSS + SSRF + DoS), `abde1e9` "add json_attr template filter…" (the stored XSS).

Combined with the project's disclosure posture:

- **0 git tags, 0 GitHub releases, 0 published security advisories.**
- `SECURITY.md` supports exactly one version: *"Latest on `main`"*.
- Coordinated private disclosure via `security@brightbean.xyz`.

This is defensible practice — it avoids handing a working exploit to attackers
before self-hosters can patch. But for a fork operator it has three hard
consequences:

1. **You cannot identify security fixes from commit messages.** "Internal cleanup"
   is a fix for a live, externally-reported stored XSS.
2. **There is no advisory feed to subscribe to.** No releases, no tags, no GHSA.
3. **"Supported = latest `main`" means falling behind is the same as being
   unpatched**, with no way to tell how far behind you are *in security terms*.

Therefore: **sync cadence is not hygiene here, it is the security control.** The
`kgroyalty` fork is the worked example of the failure mode — it did this audit,
then drifted to 196 commits behind, and is now missing three months of silent
security patches it has no way to enumerate.
