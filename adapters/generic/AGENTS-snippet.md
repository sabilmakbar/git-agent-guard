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
- Never add an agent-attribution footer to PR bodies.
- Whether commits carry a `Co-Authored-By` trailer is the project's decision, not
  yours: ask once per repository and follow the answer. Do not add one by default,
  and do not remove one where the project has chosen to have it.

## Judgment rules

No hook can enforce these; they need an understanding of what a change means.
They hold whether or not the enforcement layer is installed.

- One logical change per commit. Split a mixed working tree into one commit per
  logical arc, staging at the hunk level when a file holds unrelated edits
  (`git apply --cached <patch>` where interactive staging is unavailable).
  Propose the split before committing; never present "lump it all together" as
  an equal option.
- Commit messages are concise and factually grounded in that exact diff. State
  what the change does; no essays, no incidental file names, no references to
  internal trackers a reviewer cannot see. When the user dictates wording, use
  it verbatim.
- A release or version-bump PR contains only the bump and what is tightly
  coupled to it (that version's changelog entry). Unrelated changes that
  accumulated on the branch go in their own PR.
- When the working tree is already dirty and a new task is about to start,
  surface the pending changes first instead of building on top of them, so old
  and new edits do not tangle into unsplittable commits.
