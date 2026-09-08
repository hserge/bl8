# Working with the ui/ and redirect/ submodules

`bl8` is a superproject with two submodules, each its own independent git repo:

| Path | Remote |
|---|---|
| `ui/` | `bl8-ui.git` |
| `redirect/` | `bl8-redirect.git` |

The superproject (`bl8`) doesn't store `ui/`'s or `redirect/`'s file contents directly — it
only stores a **pointer** (a commit SHA) to whatever commit each submodule is currently checked
out at. That means a change inside `ui/` or `redirect/` happens in **two layers**, and you
commit/push them in order: submodule first, then superproject.

## 1. Commit and push inside the submodule itself

```bash
cd ui/                      # or redirect/
git status                  # a normal repo from here on
git add <files>
git commit -m "..."
git push origin main        # pushes to bl8-ui.git (or bl8-redirect.git)
cd ..
```

At this point `bl8-ui.git`'s history has the new commit, but the **superproject still points at
the old commit** — `git status` in `bl8/` will show `ui` as "modified (new commits)" until you
do step 2.

## 2. Record the new submodule commit in the superproject

```bash
cd bl8/                     # (or wherever you already are)
git add ui redirect         # stages the *pointer* update, not file contents
git commit -m "Bump ui/redirect submodules for ..."
git push origin main        # pushes to bl8.git
```

`git add ui` here doesn't stage the diff of files inside `ui/` — it stages "the superproject now
points at commit X of the ui submodule instead of commit Y."

## Order matters on push

Always push the submodule *before* the superproject. If you push the superproject's pointer
first and the submodule commit isn't on the remote yet, anyone who clones `bl8` and runs
`git submodule update` gets a "commit not found" error.

## Useful variants

- **See exactly what changed inside a submodule from the superproject**, without `cd`-ing in:
  `git diff --submodule=log` (or `git submodule summary`).
- **Commit+push all dirty submodules in one pass**, without manually `cd`-ing into each:
  `git submodule foreach 'git add -A && git commit -m "..." && git push'` — useful for identical
  throwaway messages, but for anything meaningful `cd`-ing into each one at a time (step 1) is
  usually clearer since each submodule needs its own commit message.
- **Pull latest submodule commits** (e.g. after someone else pushed to `bl8-ui`):
  `git submodule update --remote ui` bumps your local checkout to the submodule's latest `main`;
  you still need step 2 afterward to record that pointer bump in `bl8`.
- **Fresh clone of `bl8`**: submodules start out empty. Either clone with
  `git clone --recurse-submodules <url>`, or after a plain clone run
  `git submodule update --init --recursive`.

## Resolving the rejected-push case (remote has commits you don't)

If `git push origin main` in the superproject is rejected ("fetch first"), someone else pushed
to `bl8` since you last pulled. Don't blindly `git pull` — check what actually changed first:

```bash
git fetch origin main
git log --oneline main..origin/main   # what's on the remote that you don't have
git log --oneline origin/main..main   # what you have that the remote doesn't
```

If the two sets of commits touch unrelated files (e.g. someone else bumped submodule pointers
while you added unrelated top-level files), a rebase is safe and keeps history linear:

```bash
git rebase origin/main
git push origin main
```

If your own commits were already pushed and shared (not just sitting locally unpushed), prefer
`git pull` (a merge) over rebase instead — rewriting already-published history causes problems
for anyone else who has it.
