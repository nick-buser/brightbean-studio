# Security audit findings — imported from a downstream fork

## Provenance

These findings were **not** produced by us. They come from
[`kgroyalty/Social-Media-Studio`](https://github.com/kgroyalty/Social-Media-Studio)
(rebranded "Promura Social"), a fork of `brightbeanxyz/brightbean-studio` that ran
a real security audit and fixed what it found. Patch authorship on the commits is
`Jan Schmitz <jan.schmitz@whu.edu>`, with `Co-Authored-By: Claude Opus 4.7`.

Raw patches are preserved verbatim in [`patches/`](./patches/).

**The trigger was a live, externally reported stored XSS** in the composer /
media-library tag inputs that pivoted to `/members/invite/`. Everything else in
this catalog is the follow-on audit: closing the escalation surface so that an
attacker who ever regains a similar foothold has nowhere to go.

### Why this needs verification, not blind cherry-picking

At the time of import that fork was **24 commits ahead / 196 commits behind**
upstream. Two consequences:

1. **Many of these fixes already landed upstream** under different SHAs — which is
   precisely *why* they still show as "ahead" in a `git compare` (compare counts
   SHAs, not content). Files created by these patches — `apps/common/validators.py`,
   `apps/common/templatetags/common_extras.py`, `apps/composer/tests/test_rss_url_validation.py`,
   `apps/common/tests/test_validators.py` — **already exist in our tree**.
2. Anything **not** upstreamed is still live in our fork, because our `main` is a
   clean mirror of `brightbeanxyz/main`.

So the job is: verify each finding against *current* code, then fix only the gaps.
A finding is only PRESENT if the protection is actually **invoked on the vulnerable
path** — a validator that exists but is never called on the periodic-fetch path is
MISSING, not PRESENT.

## Finding catalog

Severity is our own assessment. Status column is filled in by the verification pass
(see [`verification.md`](./verification.md)).

### Cross-site scripting

| ID | Severity | Finding | Fork's fix |
|---|---|---|---|
| SEC-01 | **Critical** | Stored XSS: user-supplied tag JSON rendered into Alpine `x-data` attributes with `\|safe`. Any authenticated user could break out of the attribute and execute script against any viewer of the asset / composer / CSV-mapping pages. Externally reported; pivoted to `/members/invite/`. | `json_attr` filter that HTML-escapes serialized JSON, applied at all three attribute-context call sites (`4d5a156`) |
| SEC-02 | High | `</script>` breakout inside Alpine's `composerApp`: four `\|safe` JSON interpolations in the `compose.html` script block. | Replaced with Django `\|json_script` + `JSON.parse` (`c912805`) |
| SEC-03 | Medium | Tag write endpoints accepted arbitrary input — no count, length, or type validation. | `_normalize_tags` → promoted to `parse_and_truncate_tag_string` in `apps/common/validators.py`; max 25 tags × 100 chars, 400 on bad input. Applied across `save_post`, `autosave`, `idea_create`, `idea_update`, YouTube `yt_tags` (`4d5a156`, `c912805`) |
| SEC-04 | Low (correctness) | `json_attr` serialized a missing post's empty string as JS `""`, so Alpine initialized `tags` as a string and `.push`/`.includes`/`.join` broke in the create-post flow. | Empty string → `[]` fallback (`13999eb`) |
| SEC-12 | High | `image/svg+xml` in the upload allow-list. A script-bearing SVG executes same-origin when served from local storage. | Dropped from the allow-list (`091f02a`) |
| SEC-17 | Medium | CSS injection via unvalidated hex-colour fields: `CustomCalendarEvent.color`, `ContentCategory.color`, `Workspace.primary_color`. | Hex validation at both view and model layers, with validator-only migrations (`091f02a`) |

### Privilege escalation (RBAC)

| ID | Severity | Finding | Fork's fix |
|---|---|---|---|
| SEC-05 | High | No role-hierarchy enforcement on invite — lateral and upward org-role grants possible. | Strict `org_role` check: only owners grant admin (`091f02a`), later scoped to the admin/owner tier so member-tier client-portal invites still work (`af89c2f`) |
| SEC-06 | High | Workspace-role assignment not bounded by the inviter's own role in that workspace. | Non-strict `workspace_role` bound; org owners bypass via implicit ws-owner level (`091f02a`) |
| SEC-07 | High | `update_workspace_assignments` validated only the **new** role, never the **existing** one. A viewer-level org admin could demote a workspace **owner** — or delete their membership entirely by unchecking a box. | Existing-role guard alongside the request-role guard, on both the modify and delete paths (`1f2bca2`) |
| SEC-18 | Medium | Calendar `event_create` / `event_edit` / `event_delete` had no permission gate — **viewers** could create shared, CSS-injectable events. | Gated behind `create_posts` (`091f02a`) |

### Server-side request forgery

| ID | Severity | Finding | Fork's fix |
|---|---|---|---|
| SEC-08 | High | RSS feed URL unvalidated at creation. | `is_safe_url` / `resolve_public_ip` rejecting private, reserved, loopback, link-local, multicast (`7264d31`, `af0f434`) |
| SEC-09 | High | Periodic feed fetch ran `follow_redirects=True` with **no per-hop check** — DNS-rebind and `302 → internal` both open. Creation-time validation alone does not close this. | Re-validate every periodic fetch; manual redirect handling with per-hop re-validation (`091f02a`, `c912805`) |
| SEC-10 | Medium | The redirect loop rejected common relative forms (`Location: /feed.xml`, `Location: //example.com/…`) because `is_safe_url` requires an absolute URL — a correctness bug in the SEC-09 fix. | `urljoin` against the current request URL before re-validating (`dee5ebc`) |
| SEC-11 | High | Notification webhook URL validated at save time only, and 3xx responses were followed — `302 → 127.0.0.1` reachable at dispatch. | Re-validate at dispatch; refuse 3xx outright (`c912805`, `091f02a`) |

### Cross-workspace data access (IDOR)

| ID | Severity | Finding | Fork's fix |
|---|---|---|---|
| SEC-16 | High | Approvals `edit_comment` did not scope its Post lookup or comment query to the request workspace — a viewer in workspace A could edit or leak comments on a post in workspace B by guessing UUIDs. | Both queries scoped to the request workspace (`091f02a`) |
| SEC-19 | Medium | `queue_create` did not scope `category_id` to the request workspace. | Scoped (`091f02a`) |
| SEC-20 | Medium | Calendar slot delete/update leaked existence via timing/ordering: the 404 came from a post-lookup ownership check rather than the DB query. | `get_object_or_404` scoped to the workspace (`c912805`) |

### Denial of service

| ID | Severity | Finding | Fork's fix |
|---|---|---|---|
| SEC-15 | High | Billion-laughs XML expansion on the inbox webhook and composer feed parse paths. | `safe_xml_fromstring`: 5 MB cap + DOCTYPE/ENTITY prefix-scan rejection. Deliberately **no** `defusedxml` dependency (`091f02a`) |
| SEC-14 | Medium | CSV upload read into memory with no size cap. | 5 MB cap enforced before read (`c912805`) |
| SEC-13 | Medium | Upload validation trusted the client-supplied `Content-Type`, so a spoofed MIME masquerade reached storage. | Hand-rolled magic-byte sniffer, rejecting before storage. Deliberately **no** `python-magic` dependency (`091f02a`) |

## Explicitly NOT to adopt

`f370b1b` — `FORCE_HTTPS` env toggle defaulting to **False**, gating
`SECURE_SSL_REDIRECT`, HSTS, `SESSION_COOKIE_SECURE`, and `CSRF_COOKIE_SECURE`;
plus removing Caddy from the prod compose file. This is a deliberate security
**loosening** so the fork could run on a bare-IP VPS without TLS. It is the
opposite of what we want on Railway, which terminates TLS for us. Do not port it.

`147c2d0` (Cursor agent config), `aa1a9f1` / brand commits — cosmetic rebrand to
"2post"/"Promura", irrelevant to us.

## Dependency note

The fork solved both the XML and MIME problems **without adding dependencies**
(no `defusedxml`, no `python-magic`), on the stated grounds of keeping the
buildpack lean. Worth preserving that constraint if we port these — it keeps the
diff additive and avoids a `requirements.txt` conflict on every upstream sync.
