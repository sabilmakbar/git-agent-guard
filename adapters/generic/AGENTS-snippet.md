# git-agent-guard — guidance for agents without hook support

Add this section to your project or global AGENTS.md. Tools that cannot run
pre-execution hooks get the rules as standing instructions; tools with hook
support should use a real adapter instead (see `adapters/`).

---

## Git workflow rules

- Run `git add` and `git commit` as two separate commands, never chained.
  Staging is reviewed on its own before anything is committed.
- Never merge pull requests (`gh pr merge`, merge API endpoints, or UI).
  Opening PRs is your job; merging is always the human's.
- Before a commit that tracks a file for the first time, list the new files
  and get explicit approval. Editing an untracked file is not approval to
  put it in the repository.
- Before deleting any branch, verify all three: the tip is an ancestor of
  the base branch, nothing is unpushed to its upstream, and no stash entry
  reads `WIP on <branch>`.
- Before pushing, confirm `git config user.email` is the right identity for
  that remote (work vs personal). A wrong identity in public history is
  hard to scrub.
- Never add agent-attribution footers to commit messages or PR bodies.
