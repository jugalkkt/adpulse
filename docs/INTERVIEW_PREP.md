# Interview prep: AdPulse

For Jugal, preparing for an SRE internship interview (Media.net, AdTech). Every number here is real and comes from `docs/rca/SUMMARY.md` or `PROGRESS.md`. If you're asked about something not in this repo, say so. Honesty about limits scores better than bluffing.

---

## 1. The 2-minute pitch

> "I built AdPulse to learn SRE by doing it, not just reading about it. The product is deliberately small: an ad-serving API. Given a page category and a user segment, it picks an ad weighted by bid, from Redis or Postgres, behind nginx with two replicas.
>
> The interesting part is everything around it. **Terraform** creates the infrastructure, the same module for staging, prod and an AWS environment. **Puppet** hardens the base image and the cloud VM. **Chef** configures the Postgres node and its backups. **Ansible** does zero-downtime rolling deploys with a readiness gate; I measured 0 failed requests out of several thousand during deploys and rollbacks.
>
> **Prometheus** has 14 alerts, each with a runbook, plus SLO burn-rate alerts and a `predict_linear` forecast for disk. When an alert fires, Alertmanager calls a **healer** service I wrote. It runs an allow-listed Ansible playbook, with cooldowns and escalation so it can't loop forever.
>
> To prove it works, I broke it on purpose: **16 chaos experiments** across hardware, software, database and network. 15 were detected and 13 recovered with no human. A database outage is typically detected in about 20 seconds and recovered in about 40, with zero failed user requests, because the API degrades to house ads instead of erroring. Every run has a written RCA, including the two that went wrong. The first database test was never healed because the alert flapped; I found the cause, a slow DNS failure making the exporter time out, and fixed it.
>
> Finally, I deployed prod to AWS EC2 with the same modules, ran the chaos tests there too, and destroyed everything the same day."

## 2. The 5-minute architecture walkthrough

Use `docs/ARCHITECTURE.md` (diagram) on screen. Each step takes about 40 seconds.

1. **Request path:** client → nginx → 2 API replicas → Toxiproxy → Postgres/Redis. Toxiproxy exists so chaos can break the *real* network path. "If Redis or Postgres fails, the API returns a house ad with HTTP 200: graceful degradation."
2. **Who owns what:** Terraform owns long-lived things (networks, volumes, databases, monitoring). Ansible owns releases. Puppet and Chef run *inside* the image build and are then removed, so containers ship without an agent. "One tool per job, so there is one source of truth for everything."
3. **A release:** push → CI (lint, tests, image build, Trivy, gitleaks) → CD deploys to staging on a self-hosted runner → smoke test → automatic rollback if it fails → a human clicks *Promote*, which deploys the *exact same* release to prod. Show screenshot 02: a broken release rolled back by itself in 46 s, with prod untouched.
4. **Rolling deploy detail:** start `-next` with the same DNS alias → Docker health → `/readyz` 200 → pause 6 s → stop the old one. "Health means the process is alive; readiness means it can serve. Gating on readiness is what makes it zero-downtime."
5. **Monitoring → healing:** Prometheus scrapes every 5 s; alerts have `for:` (and `keep_firing_for:` so they don't flap); Alertmanager → healer → playbook; every action is a Grafana annotation (screenshot 05). Two layers: Docker restarts crashed processes; the healer handles what Docker can't see.
6. **Proof:** the SUMMARY table, one RCA (the first db-down failure), and the AWS run.

## 3. 25 likely questions, with answers grounded in this repo

**Tools and design**

1. **Why Puppet *and* Chef *and* Ansible?**
   The JD lists all three, so I gave each a distinct job instead of overlapping them. Puppet holds the OS baseline (base image, AWS host), Chef holds the database node, and Ansible holds procedures (deploys, rollbacks, healing, bootstrap). In a real company I'd standardise on one or two. The lesson is the split itself: *desired state* (Puppet/Chef) vs *ordered procedure* (Ansible).

2. **Why does config management run inside `docker build`?**
   Containers should be immutable, so configuration happens once, at build time. Puppet runs twice in the build, and the build fails if the second run changes anything (an idempotency check). Then the agent is purged, so it doesn't ship. On the AWS VM, which is long-lived, Puppet runs for real, and a `--noop` run showed 0 drift.

3. **Terraform vs Ansible: where's the line?**
   Terraform for things whose lifecycle is "exists or not" (networks, volumes, the database container). Ansible for things that need an order of steps (migrate, then replace replica 1, wait, then replica 2). The API containers are the only thing Terraform doesn't create.

4. **How does Terraform know what exists? What's in state?**
   `terraform.tfstate` maps code to real IDs. It can contain secrets, so here it's local and gitignored. In a team I'd use a remote backend with locking (S3 + DynamoDB, or Terraform Cloud).

5. **What's a Terraform module, and how did you use one?**
   Reusable code with inputs. `modules/adpulse_stack` defines a complete environment; it's used for staging, prod and aws-prod, with different subnets, ports and load. On AWS, the same module drove Docker on the VM over SSH, so every local fix applied to the cloud unchanged.

**Reliability and deploys**

6. **How do you get zero-downtime deploys?**
   Rolling replacement with a readiness gate, nginx retrying on the other replica (`proxy_next_upstream`) with a 500 ms connect timeout, and expand-only migrations so old and new code both work during the roll. Measured: 0 failed requests in 6654, 5765 and 4613-request deploys and a 4328-request rollback.

7. **What happens when a bad release goes out?**
   Demonstrated: a release with a broken readiness check was merged. CD deployed it to staging, the smoke test failed on `/readyz` 503, and CD rolled back automatically in 46 s. Prod was never touched, because promotion only deploys what staging runs. 0 ad requests failed. RCA: `docs/rca/2026-10-07-1253-deploy-bad-release-staging.md`.

8. **How do you roll back a database migration?**
   I don't. Migrations are expand-only (add columns or tables, never drop or rename in the same release), so the previous app version still works and a rollback only swaps the app (D030).

9. **What's graceful degradation here?**
   If the DB or cache fails, the API serves a house ad with HTTP 200 instead of a 5xx. During the prod DB outage, 0 probes failed, but 24.4 % of API requests got house ads. That's lost revenue, so it's still an incident: it shows up in `AdPulseServingFallbackAds`, not just in the error rate.

**Monitoring and SLOs**

10. **Which SLOs did you set, and why those?**
    Availability 99.5 % (non-5xx) and latency (95 % of requests under 150 ms). Ad requests are synchronous on a publisher's page, so latency matters as much as errors. Alerts use multi-window burn rates (fast 14.4×, slow 6×) rather than raw thresholds.

11. **What's the difference between `for:` and `keep_firing_for:`?**
    `for:` means it must be bad for this long before firing, which filters out blips. `keep_firing_for:` means it stays firing this long after it looks fine, which stops flapping. My first db-down test was never healed because the alert flapped. The stopped DB's exporter waited on a slow DNS failure, scrapes timed out, the alert switched on and off, and Alertmanager never delivered it. The fix was `keep_firing_for: 30s` plus fast-fail DNS; MTTR then went to 37.5 s.

12. **How do you do trend analysis or forecasting?**
    `predict_linear` on the backup volume: "it will be full within 10 minutes at this rate" fires *before* it's full. The disk-quota chaos run detected it in 137 s, and the healer's `cleanup_backups` cleared it.

13. **Which incident was not detected, and what did you do?**
    Latency injected on Redis alone. The API's 200 ms Redis timeout contained it, and p95 peaked at 0.247 s, just under the alert's threshold, so nothing fired. I recorded it as a detection gap rather than tuning the threshold to make the test pass. The fix is an alert on cache-latency or cache-error SLIs.

**Self-healing**

14. **How does the healer decide what to do?**
    `healer/healing.yml` is an allow-list mapping an alert to a playbook. Only listed playbooks can run. Labels become playbook variables, and each entry has a cooldown and a maximum number of attempts within a window. When the limit is reached it escalates (`HealerEscalated`) instead of retrying.

15. **What happens if the healer itself dies?**
    Layer 1: Docker restarts it (`unless-stopped`). If it's up but broken, Prometheus scrapes it, and `TargetMissing` fires. Alertmanager keeps retrying its webhook, and alerts stay visible in Alertmanager and Grafana. The honest gap: there's no second notification channel. In production I'd add a page to a human (PagerDuty or Slack) for `severity=page`, plus a dead-man's-switch alert, so "the healer is down" can't be silent.

16. **How do you avoid the healer fighting a deploy?**
    Every deploy creates an Alertmanager silence for that env and expires it afterwards, so "replica missing" during a deploy never reaches the healer. The healer also has a per-env lock, so only one action runs at a time in each env.

17. **Is automatic healing dangerous?**
    It can be, so the healer is constrained:
    - an allow-list of actions;
    - cooldowns and maximum attempts;
    - escalation;
    - evidence-only playbooks for things where a restart would hide the cause (latency);
    - no secrets;
    - no raw Docker socket, only a socket proxy that allows the needed API calls.

    Every action is logged and annotated. It also caught one false escalation: on a brand-new env, "replica missing" fired before the first deploy. That's documented, with the fix (silence a new env until its first deploy).

**Incidents and RCA**

18. **Walk me through an RCA.**
    The first db-down in staging (`docs/rca/2026-10-07-1100-db-down-staging.md`):
    - Timeline: injection at T0; the alert fired at T+22 s, then flapped between firing and pending, so it never stayed firing for Alertmanager's 10 s `group_wait`.
    - Impact: 0 failed probes but 94.2 % house ads API-side.
    - Root cause: Docker DNS took about 5.2 s to fail for the stopped container, so exporter scrapes timed out, `pg_up` went missing, the alert flapped, and nothing was delivered. House ads were served for 10 minutes, until the tool's 600 s safety limit.
    - Contributing factor: the alert had no `keep_firing_for`.
    - Actions: `keep_firing_for`, and fast-fail DNS for exporters.
    - Verification: a re-run healed in 37.5 s.

    It's blameless: the question is "why did the system allow this?"

19. **How did you measure MTTD and MTTR?**
    The chaos tool records the injection time, then probes nginx every second. MTTD is when Prometheus shows the alert firing. MTTR is when the scenario's health check passes *and* 3 consecutive probes are good (200, a real ad, under 250 ms). I tightened that definition after api-hang reported "recovered" too early.

**Security**

20. **What did you do for security?**
    - Every container drops all capabilities and sets no-new-privileges; 26/27 have a read-only root filesystem and 25/27 run as non-root.
    - Images are pinned by digest; Python dependencies are hash-locked.
    - Trivy gates on fixable CRITICALs (0 found), gitleaks runs on every commit and over the full history, and an SBOM is built per image.
    - Postgres uses scram-sha-256 and three roles.
    - On AWS: IMDSv2 only, an encrypted disk, a /32 security group, and key-only SSH (password login refused).
    - Each control and how it was verified is listed in `docs/SECURITY.md`.

21. **Why is a self-hosted runner risky?**
    It runs workflow code on my laptop with Docker access, which is effectively root. On a public repo, a fork's pull request could run code there. So the repo is private, deploy workflows never run for pull requests, and the README has the removal command to run before going public.

22. **How did you keep secrets out of git?**
    `.env` is generated, mode 600 and gitignored. Terraform state is gitignored. gitleaks runs as a pre-commit hook and in CI. AWS keys were typed only into `aws configure`, and the access key was deleted after the teardown.

**Scale and production**

23. **How would this scale to 500,000 websites?**
    - The API is stateless, so it scales horizontally behind a real load balancer, with autoscaling on CPU and p95 latency.
    - The candidate set is small (category × segment), so an in-process cache in front of Redis would absorb most reads, and Redis can be clustered.
    - Postgres gets read replicas for ad lookups.
    - Impressions move from a direct insert to a queue (Kafka or Kinesis), so writes never sit on the serving path.
    - Multiple regions with geo-DNS, because ad latency is per user.
    - Monitoring moves to a scalable Prometheus setup (Thanos or Mimir), and the healer's job mostly moves into the orchestrator.

24. **What would you change for real production?**
    - Kubernetes or ECS across several hosts and AZs (today one host is a single point of failure).
    - Postgres HA (RDS Multi-AZ or Patroni).
    - Remote Terraform state with locking.
    - An image registry with signing.
    - A human paging channel.
    - Centralised logs and tracing.
    - Longer, realistic SLO windows (30 days).
    - An SLO on revenue impact (house-ad rate), not just errors.

25. **What was the hardest bug?**
    The db-down alert that never reached the healer. Everything *looked* configured right, but the alert flapped. I found it by reading the Prometheus scrape durations: the exporter for the stopped DB took longer than the scrape timeout, because DNS for a stopped container was slow. Lesson: an alert is only as reliable as the scrape behind it.

## 4. Resume bullets (real numbers only)

- Built **AdPulse**, a self-healing ad-serving platform (FastAPI, PostgreSQL, Redis, nginx), with infrastructure in **Terraform**, configuration in **Puppet** and **Chef**, and releases and remediation in **Ansible**. It runs as staging, prod and an AWS EC2 environment from shared Terraform modules.
- Ran **16 chaos experiments** across hardware, software, database and network layers: **15 detected, 13 auto-recovered**. Database outages were detected in about **20 s** and recovered in about **40 s**, with **0 failed user requests**, thanks to graceful degradation. Wrote a blameless RCA for each, including a flapping-alert bug whose fix enabled automatic DB recovery (from not healed within 600 s to 37.5 s).
- Designed **zero-downtime rolling deploys** with a readiness gate (0 failed requests across 3 deploys and 2 rollbacks under load; 24,109 requests in total), plus a GitHub Actions pipeline: CI, CD to staging, smoke test, manual promotion to prod. A bad release was **rolled back automatically in 46 s** with prod untouched.
- Hardened **27 containers**: all capabilities dropped, read-only and non-root by default, digest-pinned images, hash-locked dependencies, Trivy and gitleaks gates (0 fixable critical CVEs). Deployed to **AWS EC2** with IMDSv2, an encrypted disk and a /32 security group, and verified the teardown with the AWS CLI the same day.

## 5. Known limitations (say these before you're asked)

- **One host per environment.** Two API replicas survive a process failure, but not a host failure. Postgres and Redis are single instances; house ads hide a DB outage from users but not from revenue.
- **No human notification channel.** Alerts go only to the healer and the UIs (chosen at checkpoint Q4). If the healer is down, escalations are visible but not pushed to anyone.
- **Detection gaps:** Redis-only latency went undetected. Burn-rate alerts need about an hour of traffic before they mean anything (the 30-day SLO is notional, D036).
- **Demo-scale settings:** 5 s scrape intervals, short cooldowns, a laptop-sized load (15–25 requests/s).
- **The AWS run was a few hours**, not a long-running service. There is no registry (images were copied with `docker save`) and Terraform state is local.
- **`make down` has an ordering bug** between the monitoring and env stacks (D068), so a full from-scratch rebuild was not demonstrated end to end.
- **Single author, built in a day with an AI pair programmer.** The design decisions and their reasons are in `docs/DECISIONS.md`; be ready to explain any of them yourself (`LEARNING.md` is the study guide for that).
