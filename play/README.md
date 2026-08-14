# Bot files

Keep exactly these two source files in this folder:

- `your_bot.s` — the fixed bot being demonstrated by the repository owner.
- `challenger.s` — the bot being tested by the person using the fork.

The workflow runs both files through the official evaluator's `--check` mode
before starting either match. It does not execute shell scripts, Makefiles,
Dockerfiles, or other files supplied by the challenger.
