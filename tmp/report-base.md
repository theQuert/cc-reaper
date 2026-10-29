# session-reaper report-only 2026-10-29 19:12:08 CST

idle threshold 60 min; protected: ops-dispatch anyfast* workflow-audit homepage dashboard-perf enterprise-form-redesign

| tmux | session | status idle | issues | outcome | keeps it | held only by background shells | kept only by new gates | verification target |
|---|---|---|---|---|---|---|---|---|
| sre | `d0466457` | idle 39m | #6546,#6655,#6656,#6657,#6658 | keep | idle:39<60min, waiting, issue-open:#6546,#6655,#6656,#6657,#6658, uncommitted:sre-6655-relay-ip-limit, uncommitted:sre-6656-edge-rules, uncommitted:sre-6657-traffic-oncall, uncommitted:sre-6658-harden-keep | - | - | pid 14900+0 desc; tmux sre; worktrees orphan-pr-4449,orphan-pr-4700,orphan-pr-5976,sre-6546-gce-harden,sre-6655-relay-ip-limit,sre-6656-edge-rules,sre-6657-traffic-oncall,sre-6658-harden-keep |
| ops-dispatch | `f7fd7201` | shell 16m | #4096,#5651,#610 | keep | protected, status:shell, shell-child, waiting-keyword, issue-open:#610, uncommitted:claude-4096-no-op-realter, unpushed:claude-5651-image-size-passthrough | - | - | pid 15593+3 desc; tmux ops-dispatch; worktrees claude-4096-no-op-realter,claude-5651-image-size-passthrough,claude-610-enterprise-entry-20261006 |
| dashboard-hotfix | `e682197c` | idle 40m | #6600 | keep | idle:40<60min, waiting-keyword, uncommitted:fix-6600-overview-freeze | - | - | pid 20187+0 desc; tmux dashboard-hotfix; worktrees ci-setting-tabs-probe,fix-6600-overview-freeze |
| selfhost-6550 | `0b7fc397` | idle 22m | - | keep | idle:22<60min | - | - | pid 22081+0 desc; tmux selfhost-6550; worktrees - |
| security | `d47eb695` | waiting 105m | #6169,#6669 | keep | status:waiting, waiting, issue-open:#6169,#6669, unpushed:deps-6169-web-next-dev-cve | - | - | pid 2589+0 desc; tmux security; worktrees deps-6169-web-next-dev-cve,deps-6669-adopt |
| dispatch | `afc11bb2` | idle 122m | - | keep | claim-unknown | - | - | pid 32533+0 desc; tmux dispatch; worktrees - |
| homepage | `d2cd8ffb` | shell 48m | #6361,#6515,#6580,#6408,#6492 | keep | protected, status:shell, waiting-keyword, issue-open:#6361,#6515,#6580,#6492, uncommitted:feat-6515-retire-api-gateway, uncommitted:feat-6580-compare-cta-faq, uncommitted:feat-api-gateway-redesign, uncommitted:feat-helmway-redesign, unpushed:feat-homepage-capability-bento, uncommitted:fix-6408-homepage-retry-copy, uncommitted:fix-6492-trending-three-cards | - | - | pid 41767+6 desc; tmux homepage; worktrees claude-6361-per-key-limits,feat-6515-retire-api-gateway,feat-6580-compare-cta-faq,feat-api-gateway-redesign,feat-helmway-redesign,feat-homepage-capability-bento,fix-6408-homepage-retry-copy,fix-6492-trending-three-cards,fix-6515-sitemap-drop-api-gateway |
| billing-406 | `3f7b1ce8` | idle 4m | #483,#530,#6625,#6626,#6627,#482 | keep | idle:4<60min, issue-open:#483,#530,#6625,#6626,#6627,#482 | - | - | pid 50346+0 desc; tmux billing-406; worktrees feat-483-subscription-discrepancy-engine,feat-530-recon-taxonomy,fix-6625-subscription-event-order,fix-6626-suspension-email-once,fix-6627-processed-events-retention,test-482-webhook-idempotency-audit |
| release-owner | `404c8e65` | shell 40m | - | keep | status:shell, shell-child, waiting, claim-unknown | - | - | pid 56297+2 desc; tmux release-owner; worktrees - |
| uiux | `0d8c0e9c` | busy 1m | #5646 | keep | status:busy, subagent-active, issue-open:#5646, uncommitted:fix-5943-field-empty-array, unpushed:fix-5943-field-empty-array, uncommitted:uiux-accept-1029, uncommitted:verify-6325-local | - | - | pid 61673+1 desc; tmux uiux; worktrees chore-uiux-sync-1026,feat-5646-feedback-components,feat-5949-access-shared-table,feat-5949-org-shared-layer,feat-5949-org-shared-table,feat-5949-plan-models-shared,feat-6632-state-rules,feat-6633-chart-states,feat-6633-group3-inputs,feat-6633-group4-button-field,feat-6633-radio-breadcrumb-kbd,feat-6634-design-site,fix-5942-toast-p2,fix-5943-field-empty-array,fix-6647-calculator-budget,uiux-accept-1029,verify-6325-local |
| openlux-supply | `addc7631` | idle 40m | #6635 | keep | idle:40<60min, waiting, issue-open:#6635 | - | - | pid 65476+0 desc; tmux openlux-supply; worktrees feat-6635-openlux-groups,feat-6635-supplier-conformance |
| ci-2 | `f4464bc1` | idle 14m | #6674 | keep | idle:14<60min, subagent-active | - | - | pid 66490+0 desc; tmux ci-2; worktrees fix-6674-queue-health-longest-timeout |
| sec-p1 | `e15698e1` | idle 41m | - | keep | idle:41<60min, claim-unknown | - | - | pid 77185+0 desc; tmux sec-p1; worktrees - |
| pr-orphans | `c4024c51` | idle 40m | #3826 | keep | idle:40<60min, waiting-keyword, blocked: #6432 | - | - | pid 7776+0 desc; tmux pr-orphans; worktrees 3826-key-picker-limit-label |
| apertis-ops | `2e31ed1b` | idle 41m | - | keep | idle:41<60min, waiting, claim-unknown | - | - | pid 79190+0 desc; tmux apertis-ops; worktrees - |
| ci | `57866792` | busy 118m | #1746,#6551,#5839,#5874,#6164,#6178,#6666 | keep | status:busy, shell-child, subagent-active, issue-open:#1746,#5839,#6178, unpushed:fix-janitor-removal-budget-starved, uncommitted:fix-reaper-batch-issue-state, unpushed:fix-reaper-batch-issue-state, unpushed:fix-ci-route-held-by-claimant, unpushed:feat-6551-pr-automerge, unpushed:fix-5839-relay-watch-unknown-text-deadline, uncommitted:fix-5874-trivy-helmway-go, unpushed:fix-5874-trivy-root-research, unpushed:fix-6178-rev2-server-check | - | - | pid 83134+17 desc; tmux ci; worktrees feat-account-switch-stall-detect,fix-host-temp-reaper-24h-patterns,fix-janitor-removal-budget-starved,fix-reaper-batch-issue-state,fix-ci-route-held-by-claimant,claude-1746-acceptance-20261027,feat-6551-pr-automerge,fix-5839-relay-watch-unknown-text-deadline,fix-5874-trivy-helmway-go,fix-5874-trivy-root-research,fix-6164-root-default-trivy,fix-6178-rev2-server-check,fix-6666-router-pages-wait-selfheal,fix-t664-gateway-blocked-stall |
| infra-scaleup | `f7e7afbc` | idle 41m | - | keep | idle:41<60min, waiting, claim-unknown | - | - | pid 87637+0 desc; tmux infra-scaleup; worktrees - |

## Skipped live sessions (not judged)
- scale-3936-rig sid=89b4cc00 pid=18806: kind:bg
- auth-audit sid=e1284bef pid=19363: kind:bg
- loop #4159 gate sid=e798d3fc pid=34162: kind:bg
- loop #3599 sid=ffd2b138 pid=42848: kind:bg
- loop #6206 check-by sid=6c0b6a7c pid=49539: kind:bg
- loop #6488 followup sid=8d3836c2 pid=5064: kind:bg
- loop #5839 followup sid=32e46e34 pid=60087: kind:bg
- loop #6446 followup sid=6b2918eb pid=69564: kind:bg
- loop #6432 followup sid=a2fa3a52 pid=8364: kind:bg
- loop #0 followup sid=806d85dd pid=86757: kind:bg
- loop #6666 followup sid=17b7ccc8 pid=98641: kind:bg
(0 session files with no live process not listed)
