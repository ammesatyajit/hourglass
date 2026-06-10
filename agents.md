# Agents

## Shared Memory: `plans.md`

`plans.md` is the shared memory for every agent in this repository. It is the single source of truth for what is happening, what has happened, and what is planned.

### Required behavior

1. **Always read `plans.md` first.** Before doing anything — answering a question, making a change, starting a task — read `plans.md` to understand current state, in-flight work, and prior context. Do not skip this step.

2. **Always update `plans.md` after acting.** Any time you do something (make a change, run a task, make a decision, discover something), append or update the relevant entry in `plans.md` so the next agent can see it. If you didn't write it down, it didn't happen.

These two rules are non-negotiable. Treat `plans.md` like working memory you share with every other agent — if it's not there, no one knows about it.

## Working Guidelines

- **Atomic changes**: Keep each code change self-contained and independently revertible.
- **Avoid clashes**: Check `plans.md` for in-flight work before starting, and record your own work as you go so other agents don't step on it.
