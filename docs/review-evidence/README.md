# Reviewer evidence

Human-visible captures so a GitHub reviewer can see a visual change without
launching the client. **Not behavioural proof.** DEMO+GAMELOG (or Go / headless)
still gate; PNG/video presence is never a pass (ARM-289).

How to capture and attach: `.cursor/skills/verify-marque/SKILL.md`
(*Reviewer-facing evidence*) and `review-evidence.sh` / `review-evidence.ps1`.

Keep one folder per issue or slug. Commit at most 1–3 artifacts. Link them from
the PR body with `blob/<head-branch>/path?raw=true` (relative PR-body image
links resolve against `main`).
