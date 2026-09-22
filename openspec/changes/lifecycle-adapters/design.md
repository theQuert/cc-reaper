# Design

The lifecycle hook is a thin adapter boundary. It accepts a fixed stage vocabulary and
delegates to the existing worktree and disk janitors. The janitors remain the only code
that decides whether a path or cache is safe to remove.

Builder cache cleanup requires a line-oriented proof with schema, scope, host, Docker
context, issue/expiry timestamps and `drained=1`. The proof lifetime is bounded to 900
seconds by a hard cap; a local adapter may choose a shorter value. Before pruning, the janitor rechecks Docker reachability, context and
every configured protected-container filter. A failed check is a logged skip.

The default protected filter is a neutral label (`label=cc.reaper.protect=true`). A local
adapter may add a name or label filter for its own runner fleet without changing CC Reaper
code. This keeps the shared project portable while allowing the stima-api machine to protect
its `ci-runner-*` containers.
