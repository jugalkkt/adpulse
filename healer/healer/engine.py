"""Healer decision engine (no I/O of its own, so it is unit-testable).

For every alert from Alertmanager it decides one of:
  run       - run the mapped playbook (allow-listed in healing.yml)
  ignore    - resolved, unmapped, already in progress, or in cooldown
  escalate  - attempts exhausted (or the playbook failed): a human must act
"""

import asyncio
import re
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from pathlib import Path

import yaml

PLAYBOOK_NAME = re.compile(r"^[a-z][a-z0-9_]*$")


@dataclass(frozen=True)
class Rule:
    alertname: str
    playbook: str | None
    extra_vars: dict[str, str] = field(default_factory=dict)
    static_vars: dict[str, object] = field(default_factory=dict)
    cooldown_seconds: float = 120
    max_attempts: int = 3
    attempt_window_seconds: float = 900
    on_resolved: str | None = None


def load_rules(path: Path, playbook_dir: Path) -> dict[str, Rule]:
    """Parse healing.yml; refuse playbooks that are badly named or do not exist."""
    doc = yaml.safe_load(path.read_text())
    defaults = doc.get("defaults", {})
    rules: dict[str, Rule] = {}
    for name, spec in (doc.get("alerts") or {}).items():
        spec = spec or {}
        rule = Rule(
            alertname=name,
            playbook=spec.get("playbook"),
            extra_vars=dict(spec.get("extra_vars") or {}),
            static_vars=dict(spec.get("static_vars") or {}),
            cooldown_seconds=float(spec.get("cooldown_seconds", defaults.get("cooldown_seconds", 120))),
            max_attempts=int(spec.get("max_attempts", defaults.get("max_attempts", 3))),
            attempt_window_seconds=float(
                spec.get("attempt_window_seconds", defaults.get("attempt_window_seconds", 900))
            ),
            on_resolved=spec.get("on_resolved"),
        )
        for pb in (rule.playbook, rule.on_resolved):
            if pb is None:
                continue
            if not PLAYBOOK_NAME.match(pb):
                raise ValueError(f"{name}: invalid playbook name {pb!r}")
            if not (playbook_dir / f"{pb}.yml").is_file():
                raise ValueError(f"{name}: playbook {pb}.yml not found in {playbook_dir}")
        rules[name] = rule
    return rules


@dataclass
class Decision:
    alertname: str
    env: str
    fingerprint: str
    kind: str  # run | ignore | escalate
    reason: str
    playbook: str | None = None
    extra_vars: dict[str, object] = field(default_factory=dict)
    attempt: int = 0

    def as_dict(self) -> dict:
        return {
            "alertname": self.alertname,
            "env": self.env,
            "fingerprint": self.fingerprint,
            "kind": self.kind,
            "reason": self.reason,
            "playbook": self.playbook,
            "attempt": self.attempt,
        }


@dataclass
class RunResult:
    ok: bool
    result: str  # success | failed | timeout | dry_run
    duration_s: float
    stdout_tail: str = ""


Runner = Callable[[str, dict], Awaitable[RunResult]]


class Healer:
    def __init__(
        self,
        rules: dict[str, Rule],
        runner: Runner,
        *,
        dry_run: bool = False,
        clock: Callable[[], float] = time.time,
        on_result: Callable[[Decision, RunResult], Awaitable[None]] | None = None,
        on_escalate: Callable[[Decision], Awaitable[None]] | None = None,
    ) -> None:
        self.rules = rules
        self.runner = runner
        self.dry_run = dry_run
        self.clock = clock
        self.on_result = on_result
        self.on_escalate = on_escalate
        self.in_progress: set[str] = set()
        self.last_action: dict[str, float] = {}
        self.attempts: dict[str, list[float]] = {}
        self.escalated_at: dict[str, float] = {}
        self._locks: dict[str, asyncio.Lock] = {}

    # ---------------------------------------------------------------- decide
    def decide(self, alert: dict) -> Decision:
        labels = alert.get("labels", {})
        name = labels.get("alertname", "?")
        env = labels.get("env", "global")
        fp = alert.get("fingerprint") or f"{name}/{sorted(labels.items())}"
        status = alert.get("status", "firing")
        rule = self.rules.get(name)
        now = self.clock()

        def d(kind, reason, playbook=None, attempt=0):
            return Decision(name, env, fp, kind, reason, playbook, self._vars(rule, labels), attempt)

        if status == "resolved":
            if rule and rule.on_resolved:
                return d("run", "on_resolved", rule.on_resolved)
            return d("ignore", "resolved")
        if rule is None:
            return d("ignore", "no_rule")
        if rule.playbook is None:
            return d("ignore", "no_action")
        if fp in self.in_progress:
            return d("ignore", "in_progress")
        last = self.last_action.get(fp)
        if last is not None and now - last < rule.cooldown_seconds:
            return d("ignore", "cooldown")
        recent = [t for t in self.attempts.get(fp, []) if now - t < rule.attempt_window_seconds]
        self.attempts[fp] = recent
        if len(recent) >= rule.max_attempts:
            esc = self.escalated_at.get(fp)
            if esc is not None and now - esc < rule.attempt_window_seconds:
                return d("ignore", "already_escalated")
            self.escalated_at[fp] = now
            return d("escalate", "max_attempts", rule.playbook, len(recent))
        # Reserve the slot now, so a duplicate webhook arriving before the
        # playbook finishes is ignored (de-duplication by fingerprint).
        self.in_progress.add(fp)
        self.last_action[fp] = now
        self.attempts[fp] = [*recent, now]
        return d("run", "firing", rule.playbook, len(recent) + 1)

    @staticmethod
    def _vars(rule: Rule | None, labels: dict) -> dict:
        out: dict[str, object] = {"env": labels.get("env", "global"), "alertname": labels.get("alertname", "")}
        if rule:
            out.update(rule.static_vars)
            for var, label in rule.extra_vars.items():
                if labels.get(label):
                    out[var] = labels[label]
        return out

    # ---------------------------------------------------------------- execute
    async def execute(self, decision: Decision) -> RunResult | None:
        """Run a 'run' decision under the per-env lock; handle escalation."""
        if decision.kind == "escalate":
            if self.on_escalate:
                await self.on_escalate(decision)
            return None
        if decision.kind != "run":
            return None
        lock = self._locks.setdefault(decision.env, asyncio.Lock())
        try:
            async with lock:  # one action at a time per environment
                if self.dry_run:
                    result = RunResult(ok=True, result="dry_run", duration_s=0.0)
                else:
                    result = await self.runner(decision.playbook, decision.extra_vars)
        finally:
            self.in_progress.discard(decision.fingerprint)
        if self.on_result:
            await self.on_result(decision, result)
        if not result.ok and decision.reason != "on_resolved":
            failed = Decision(
                decision.alertname,
                decision.env,
                decision.fingerprint,
                "escalate",
                f"playbook_{result.result}",
                decision.playbook,
                decision.extra_vars,
                decision.attempt,
            )
            if self.on_escalate:
                await self.on_escalate(failed)
        return result
