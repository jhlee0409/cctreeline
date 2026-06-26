# Contributing

Thanks for your interest! cctreeline is a small, focused tool — pure `bash` + `jq`, no build step.

## Scope

The goal is a fast, dependency-light statusline whose distinguishing feature is the **session-scoped worktree + PR line**. Contributions that fit:

- portability fixes (other shells, Linux/BSD differences, credential stores);
- correctness/robustness in the render and refresh paths;
- accuracy in docs.

Out of scope (by design): cost/$ display, theme engines, a config TUI. Those are well served by [ccstatusline](https://github.com/sirmalloc/ccstatusline) and [claude-powerline](https://github.com/Owloops/claude-powerline).

## Before you open a PR

```bash
shellcheck cctreeline.sh install.sh     # must pass clean
bash -n cctreeline.sh install.sh        # syntax
```

- The **render path must never error out** — a failure blanks the user's statusline. Guard every external read; degrade gracefully.
- Keep it **bash 3.2 compatible** (macOS system bash). No `mapfile`, no `declare -n`, no associative arrays.
- Test on a real transcript + sandboxed `XDG_*` dirs so you don't touch your own setup. See the patterns in the test notes.

## Reporting bugs

Open an issue with your OS, `bash --version`, and the `cctreeline.sh` output (run it with a sample stdin JSON).
