# Fork workflow

This repo is a fork of [`brightbeanxyz/brightbean-studio`](https://github.com/brightbeanxyz/brightbean-studio)
that carries our own deployment configuration and runs as a live Railway instance.
Two long-lived branches keep those two jobs from fighting each other.

| Branch  | Role | Rule |
|---------|------|------|
| `main`  | Pristine mirror of `upstream/main` | **Never commit to it.** Only ever fast-forwarded from upstream. |
| `trunk` | Our real branch — upstream plus our changes | Default branch. Railway deploys it. All our work merges here. |

```
upstream/main  (brightbeanxyz)
      │
      │  fast-forward only, never edited
      ▼
 origin/main   ← pure mirror, no local commits
      │
      │  merged in when we choose
      ▼
   trunk       ← our real branch ─── Railway deploys this
      ▲
      │  feature branches → PR → merge
   feat/xyz
```

## Why `main` is not the working branch

Railway deploys on push. If our work lived on `main` and `main` also tracked upstream,
every commit `brightbeanxyz` merged would land in our deploy branch — so an upstream
change could reach production without anyone reviewing it. Keeping `main` inert and
deploying `trunk` means **upstream changes only ship when we merge them.**

It also keeps `main` fast-forwardable forever. A single local commit on `main` breaks
the mirror invariant and turns every future sync into a merge-conflict negotiation.

## Day-to-day: making a change

Branch off `trunk`, PR back into `trunk`. Never branch off `main`.

```bash
git switch trunk && git pull
git switch -c feat/my-change
# ... work, commit ...
git push -u origin feat/my-change
gh pr create --base trunk
```

Merging that PR deploys to Railway.

## Pulling in upstream changes

```bash
bin/sync-upstream.sh            # fast-forward main, merge into trunk, stop before pushing
bin/sync-upstream.sh --check    # just report drift, change nothing
bin/sync-upstream.sh --push     # ...and push trunk (this DEPLOYS)
```

The script deliberately stops before pushing `trunk`, because pushing `trunk` deploys to
production. Review what upstream sent, then push.

If the merge conflicts, it's almost always in a file we've modified — currently
`README.md`, `railway.toml`, and `.gitignore`. Resolve, commit, push.

## First-time setup on a new clone

`gh` resolves a fork's "base repo" to the *parent* by default, which will aim PRs at
`brightbeanxyz` and make `gh repo edit` fail with a 404. Pin it once per clone:

```bash
gh repo set-default nick-buser/brightbean-studio
```

The sync script adds the `upstream` remote itself if it's missing, with pushes disabled
so nothing can be sent to `brightbeanxyz` by accident.

## Contributing back upstream

Some of our changes are generally useful, not fork-specific (the `.gitignore`
secret-file rule, the `railway.toml` documentation fix). To send one up, branch from
`main` — *not* `trunk`, so the PR doesn't drag our deployment config along:

```bash
git switch -c fix/whatever main
git cherry-pick <sha>
git push -u origin fix/whatever
gh pr create --repo brightbeanxyz/brightbean-studio --base main
```

## Related

- `railway.toml` — per-service Railway config and the gotchas behind it
- [`docs/security`](./security) — security notes
