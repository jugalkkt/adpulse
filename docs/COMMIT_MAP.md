# Commit map (history rewrite, 2026-10-07)

Before the repo went public, the history was rewritten to remove co-author trailers from commit messages and to redact an IP address. Content, authors and dates are unchanged, but every commit SHA changed. PROGRESS.md, DECISIONS.md, the RCAs and image tags (`adpulse-api:<sha>`) still cite the **old** short SHAs; this table maps them to the new ones.

| Old | New | Subject |
|---|---|---|
| `a3c9d33` | `6e57606` | chore: bootstrap repo, machine setup scripts and Makefile skeleton |
| `b033731` | `e5fdf17` | docs(progress): phase 0 and 1 complete |
| `0e1eb19` | `16bd27f` | feat(base): puppet (openvox) hardened base image with idempotency check |
| `f5beefa` | `b73d241` | feat(app): ad-serving api with redis cache, fallback ads, chaos modes and tests |
| `b971114` | `a8b8c8f` | feat(db): chef (cinc) configured postgres image with backup agent and metrics |
| `1e72d11` | `07f4c73` | fix(env): remove duplicate PROD_DB_MONITOR_PASSWORD in .env.example |
| `f5bded1` | `ec6237d` | feat(infra): terraform docker stacks for staging, prod and monitoring |
| `da5499b` | `0588a73` | feat(deploy): ansible rolling deploy, rollback, migrations and smoke tests |
| `1d25438` | `ceb39e8` | fix(build): reproducible image ids; faster nginx failover on dead replicas |
| `f5a095f` | `e25f8e4` | fix(deploy): skip replicas already on the release; always remove migration container |
| `0b5f3a9` | `446c4af` | fix(deploy): wait out nginx dns ttl after each replica swap |
| `c72df75` | `3a51407` | feat(make): make up end-to-end; docs for phase 6 |
| `d5a1e4a` | `db573cd` | feat(monitoring): prometheus scrape config, recording rules, alerts, slo burn rates, alertmanager routing |
| `7a6904c` | `3fd29be` | fix(monitoring): exporter connect timeouts, faster db pool recovery, grafana dashboards, runbooks, rule tests |
| `d4ee10d` | `546fdc3` | docs(monitoring): phase 7 decisions and progress |
| `1ebb837` | `8e64ccb` | feat(healer): alertmanager-driven self-healing with ansible playbooks behind a docker socket proxy |
| `294daa2` | `5ff0560` | fix(healer): keep ansible temp dirs on tmpfs when running as the host uid |
| `f090ec9` | `a4df5e9` | fix(ansible): verbose docker_host_info so labels/state are present; heal playbook test script |
| `3da0f1c` | `162f158` | fix(ansible): read dotted docker labels with get(); evaluate diagnostics dir once |
| `2b9dd96` | `39d7a1a` | feat(healer): escalation alert fix, live-tested heal playbooks; phase 8 docs |
| `e7337dc` | `7420657` | feat(chaos): chaos tool with 10 scenarios, rca generator, capped memory leak |
| `d93d3dd` | `92ea7cc` | fix(alerting): keep_firing_for on outage alerts; faster exporter connect timeouts; chaos/rca tool fixes |
| `e361a59` | `914878e` | fix(infra): fast-fail upstream DNS for exporters and toxiproxy |
| `e6eeba9` | `a3f6625` | fix(healer): restart_api is a success no-op when replicas are already healthy |
| `9583a07` | `1e74952` | fix(chaos): stressor needs a tmpfs temp path; verify cpu-hog injection really loads the cpu |
| `adb2fcf` | `5c756f7` | docs(rca): 13 chaos incidents with RCAs and summary; phase 9 decisions |
| `b4a13d3` | `88f6c2d` | feat(ci): github actions ci, staging cd with auto-rollback, manual promote to prod; scans; gosu removed |
| `aa19717` | `b030e0d` | demo: deliberately broken release (BROKEN_RELEASE=true baked into the API image) |
| `0e7473d` | `00e7c7a` | Merge pull request #1: deliberately broken release (rollback demo) |
| `18a0065` | `eb1ad91` | revert: deliberately broken release (rollback demo done) |
| `020dffb` | `df3f725` | feat(deploy): readiness gate per replica during rolling deploy; deploy-bad-release incident data |
| `0460ffc` | `b2a0f0a` | docs: phase 10 ci/cd decisions, deploy-bad-release rca, screenshot list |
| `cdee903` | `172fd68` | fix(security): non-root USER in every image (Trivy DS-0002); SBOM in CI; SECURITY.md |
| `4cc61f4` | `99bd5bf` | docs(security): scan results, phase 11 progress |
| `f289cbf` | `ec69be0` | docs(progress): phase 12 region choice |
| `b469a85` | `9b4676e` | feat(aws): terraform for vpc, subnet, sg (my ip only), key pair, imdsv2 ec2 |
| `2190f3f` | `14a1ead` | docs(progress): aws instance running; fix sg description |
| `ee9ce8b` | `85848d2` | feat(aws): puppet adpulse::host, chef host recipe, ansible bootstrap; env-agnostic rules and deploy |
| `76a5798` | `860d02b` | fix(aws): create parent dirs before rsync in bootstrap |
| `80f6bc2` | `f689eec` | feat(aws): envs/aws terraform (same modules over docker-over-ssh), image push playbook, aws-prod prometheus config |
| `cd86812` | `1497deb` | feat(aws): aws-prod deployed and chaos-tested (replica-down, db-down) with RCAs; remote-capable chaos tools |
| `43fd7b6` | `cba1ae3` | docs(aws): screenshots, aws heal log, teardown verified |
| `73179f6` | `ab3508f` | docs: aws torn down and verified; security aws section; phase 12 decisions |
| `a5c7a09` | `76cb116` | feat(aws): make aws-down with confirm and verify; phase 12 versions |
| `2f15ab1` | `eb89539` | fix(make): down destroys the applied release; docs: architecture, learning guide, summary columns |
| `4eee8a9` | `3bffff3` | docs: readme, interview prep, final acceptance notes; accept aws trivy findings |
