#!/usr/bin/env python3
"""Evidence check for the temporary PEP Spock v5 negative check (preview). Validation harness only.

Run by the workflow's assert job; also run offline against fixtures. Usage:

    verify_spock_negative.py preview <evidence-dir>

The evidence directory holds this run's downloaded PEP artifacts for the current attempt
(pep-capture-evidence-*, pep-cert-plan-*, pep-invocation-plan-*, pep-certification-*,
pep-summary-*). Run metadata, the attempt's jobs and their logs come from the GitHub API, or, when
VERIFY_FIXTURES names a directory, from run.json, jobs.json and logs/<job id>.log there. The jobs
listing is read page by page until all `total_count` jobs are in. NEEDS_JSON is the assert job's
toJSON(needs). SELF_JOB_ID is the assert job's own id (job.check_run_id): that job is still
running, so it is the one job whose log is not read; every other job must have completed with a
readable log. Exit status 0 only if every case matches.

The five cases (control, N1, N2, N2b, N3) and every expected value are in
spock-negative-fixtures.json beside this script, derived offline from PEP's own modules at the
stable commit. Each case is checked SEPARATELY and gets its own verdict: N3 is meant to make PEP's
enforce job red, and that expected red must never hide a wrong control, N1, N2 or N2b result.

The adapter is called through the branch reference @v1_STABLE. The reference and the commit it
resolved to are checked separately: GitHub records the adapter as `...@v1_STABLE` (ref
refs/heads/v1_STABLE) and each nested PEP workflow as `...@<commit>`; all must be STABLE_SHA, as
must PEP's own provenance records and its checkouts.

What the run is: the packages are the already-published spock50 5.0.13-1 staging packages,
downloaded and checksum-verified, and the receipts are recorded in the run (N3's deliberately
with a wrong digest, N1's not at all). Nothing is built or published, and no original build
provenance is established. The run is simulated; publication is `skipped`.
"""
import http.client
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

STABLE_REF = "v1_STABLE"
STABLE_SHA = "9b3c9e964487568a7b3f3a8f0a3c68000fe0d943"   # v1_STABLE after PEP #38 merged
PEP_WF = "pgEdge/pgedge-pep-test/.github/workflows/"
NESTED = ("pep-capture.yml", "pep-certify.yml", "pep-integration.yml")
RECEIPT_ACTION = "pgEdge/pgedge-pep-test/.github/actions/pep-package-receipt@52cd787341f719191e817d3f1c134fc210fbcc53"
FIXTURES = Path(__file__).resolve().parent / "spock-negative-fixtures.json"
CASES = ("control", "N1", "N2", "N2b", "N3")
CERTIFY = "Certify packages (PEP) / "
SUFFIX = " / preview (no install, no product tests)"
ASSERT_JOB = "assert negative-case evidence (preview)"
ENFORCE = CERTIFY + "certify / enforce"
FIXED_JOBS = ("Detect build matrix", "Select the five negative-case cells",
              "Fixed validation identity (synthetic inputs; nothing is published)",
              CERTIFY + "Release inputs", CERTIFY + "certify / identity", CERTIFY + "certify / capture / capture",
              CERTIFY + "certify / plan", CERTIFY + "certify / aggregate", ENFORCE,
              CERTIFY + "Release certification summary")
# PEP jobs that check out the PEP implementation (identity and enforce check out nothing).
PEP_CHECKOUT_JOBS = (CERTIFY + "Release inputs", CERTIFY + "certify / capture / capture", CERTIFY + "certify / plan",
                     CERTIFY + "certify / aggregate", CERTIFY + "Release certification summary")
OUTPUTS = ("certification_state", "certification_conclusion", "execution_status", "test_verdict",
           "coverage_status", "reason_code")
PREVIEW_IDENTITY = {"l1": "not_attempted", "l2a": "not_attempted", "l2b": "not_attempted"}
ZERO_COUNTS = {"tests": 0, "failures": 0, "errors": 0, "skipped": 0}

HEAD_LINE = re.compile(r"HEAD is now at ([0-9a-f]{7,40}) ")
STAMP = re.compile(r"^﻿?\d{4}-\d\d-\d\dT[0-9:.]+Z ?")
CONTROL = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-_]|[\x00-\x08\x0b-\x1f\x7f-\x9f]")
ENV_LINE = re.compile(r"^\S+\s+(PGEDGE_REPO_CLIENT_(?:CRT|KEY)):(?: (.*))?$")
OK_LINE = re.compile(r"^(\S+): OK$")
UP_DIGEST = re.compile(r"^SHA256 digest of uploaded artifact is ([0-9a-f]{64})$")
UP_DONE = re.compile(r"^Artifact (\S+) successfully finalized\. Artifact ID (\d+)$")
WROTE = re.compile(r"^pep-package-receipt: wrote \S+ \((\d+) member\(s\)\) for cell '([^']+)' -> receipt artifact '([^']+)'$")
WITH_LINE = re.compile(r"^  ([a-z_]+): (.*)$")
TAMPER = re.compile(r"^(upload|receipt) digest: +(\S+)$")


class _HttpsOnlyRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urlsplit(newurl).scheme != "https":
            raise urllib.error.URLError("refused non-HTTPS redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class Live:
    """The GitHub API; job logs over HTTPS with the token as an unredirected header."""

    def __init__(self, env):
        self.repo, self.run_id, self.att = env["GITHUB_REPOSITORY"], env["GITHUB_RUN_ID"], env["GITHUB_RUN_ATTEMPT"]
        self.token = env.get("GH_TOKEN", "")

    def _gh(self, path, tries=3):
        for i in range(tries):
            r = subprocess.run(["gh", "api", path], capture_output=True, text=True)
            if r.returncode == 0:
                return json.loads(r.stdout)
            if i + 1 < tries:
                time.sleep(15)
        raise RuntimeError("gh api %s failed: %s" % (path, r.stderr.strip()[:300]))

    def run(self):
        return self._gh("repos/%s/actions/runs/%s" % (self.repo, self.run_id))

    def jobs_page(self, page):
        return self._gh("repos/%s/actions/runs/%s/attempts/%s/jobs?per_page=100&page=%d" % (self.repo, self.run_id, self.att, page))

    def log(self, jid, tries=4):
        req = urllib.request.Request("https://api.github.com/repos/%s/actions/jobs/%s/logs" % (self.repo, jid))
        req.add_unredirected_header("Authorization", "Bearer " + self.token)
        for i in range(tries):
            try:
                with urllib.request.build_opener(_HttpsOnlyRedirect).open(req, timeout=120) as r:
                    return r.read().decode("utf-8", "replace")
            except (OSError, ValueError, http.client.HTTPException) as e:
                err = e
            if i + 1 < tries:
                time.sleep(15)
        raise RuntimeError("job %s log: %s" % (jid, err))


class Fixtures:
    """run.json, jobs.json ({total_count, jobs, page_size?}, served in pages) and logs/<id>.log."""

    def __init__(self, d):
        self.d = Path(d)

    def run(self):
        return json.loads((self.d / "run.json").read_text())

    def jobs_page(self, page):
        doc = json.loads((self.d / "jobs.json").read_text())
        size = doc.get("page_size", 100)
        return {"total_count": doc.get("total_count", len(doc["jobs"])), "jobs": doc["jobs"][(page - 1) * size:page * size]}

    def log(self, jid):
        return (self.d / "logs" / ("%s.log" % jid)).read_text()


def list_jobs(source, max_pages=50):
    """Every job of this attempt, page by page, until all `total_count` jobs are read."""
    jobs, total, page = [], None, 1
    while page <= max_pages:
        doc = source.jobs_page(page)
        tc, batch = doc.get("total_count"), doc.get("jobs")
        if not isinstance(tc, int) or isinstance(tc, bool) or not isinstance(batch, list):
            raise ValueError("jobs page %d is malformed" % page)
        if total is None:
            total = tc
        elif tc != total:
            raise ValueError("jobs total_count changed between pages (%d, then %d)" % (total, tc))
        jobs.extend(batch)
        if len(jobs) >= total or not batch:
            break
        page += 1
    ids = [j.get("id") for j in jobs]
    if len(jobs) != total or len(set(ids)) != len(ids):
        raise ValueError("jobs listing incomplete: %d job(s) read, %d unique, total_count %r" % (len(jobs), len(set(ids)), total))
    return jobs


def body(line):
    return STAMP.sub("", line, count=1)


def step_groups(lines):
    groups, cur = [], None
    for line in lines:
        if "##[group]Run " in line:
            cur = [line]
            groups.append(cur)
        elif cur is not None:
            cur.append(line)
            if "##[endgroup]" in line:
                cur = None
    return groups


def pair_env(lines):
    out = []
    for line in lines:
        m = ENV_LINE.match(line)
        if m:
            out.append((m.group(1), (m.group(2) or "").strip()))
    return out


def framework_group(lines):
    found = [g for g in step_groups(lines) if any("pep_time_limit.py --limit-seconds" in l for l in g)]
    return found[0] if len(found) == 1 else None


def receipt_steps(lines):
    """The pinned receipt action's invocations: their `with:` inputs as a dict, one per call."""
    out = []
    for g in step_groups(lines):
        if body(g[0]).startswith("##[group]Run pgEdge/pgedge-pep-test/.github/actions/pep-package-receipt"):
            inputs = {}
            for l in g[1:]:
                m = WITH_LINE.match(body(l))
                if m:
                    inputs[m.group(1)] = m.group(2).strip()
            out.append((body(g[0])[len("##[group]Run "):], inputs))
    return out


def uploads(lines):
    """(artifact name, artifact id, digest) for each upload-artifact the job finished."""
    out, digest = [], None
    for l in map(body, lines):
        m = UP_DIGEST.match(l)
        if m:
            digest = m.group(1)
            continue
        m = UP_DONE.match(l)
        if m:
            out.append((m.group(1), int(m.group(2)), digest))
            digest = None
    return out


def tamper(digest):
    """The workflow's rule for N3: the last hex digit d becomes (d + 1) mod 16."""
    return digest[:-1] + "%x" % ((int(digest[-1], 16) + 1) % 16)


def _one(evidence, prefix, filename, suffix):
    hits = sorted(Path(evidence).glob("%s-%s/%s" % (prefix, suffix, filename)))
    if len(hits) != 1:
        raise ValueError("%d %s-%s/%s found" % (len(hits), prefix, suffix, filename))
    return json.loads(hits[0].read_text())


def leg_job_name(inv):
    return "%scertify / %s · PG%s · %s%s" % (CERTIFY, inv["container_alias"], inv["pg_major"], inv["package_name"], SUFFIX)


def verify(mode, evidence, source, env):
    fx = json.loads(FIXTURES.read_text())
    exp = fx["expected"]
    run_id, att, run_no = env["GITHUB_RUN_ID"], env["GITHUB_RUN_ATTEMPT"], env["GITHUB_RUN_NUMBER"]
    sfx = "r%s-a%s" % (run_no, att)
    cases = {c["case"]: c for c in fx["cases"]}
    case_of = {c["cell_id"]: c["case"] for c in fx["cases"]}
    problems = {k: [] for k in CASES + ("overall",)}
    rows = []

    def check(who, ok, what):
        if not ok:
            problems[who if who in problems else "overall"].append(what)
        return ok

    def of(cid):
        return case_of.get(cid, "overall")

    if mode != "preview" or sorted(cases) != sorted(CASES) or exp["inputs"]["execution_mode"] != "preview":
        problems["overall"].append("this verifier checks the preview negative cases only (mode %r)" % mode)
        return problems, rows, {}

    exp_invs = {i["source_cell_id"]: [] for i in exp["plan"]["invocations"]}
    for i in exp["plan"]["invocations"]:
        exp_invs[i["source_cell_id"]].append(i)
    exp_ids = {i["invocation_id"] for i in exp["plan"]["invocations"]}

    def per_cell(items, key="cell_id"):
        out = {}
        for x in items or []:
            out.setdefault(x.get(key) if isinstance(x, dict) else None, []).append(x)
        return out

    # 1. The adapter's own outputs and the certify call's result. N3 makes the call fail; GitHub
    #    may then leave the outputs of the failed reusable workflow empty, so they are either all
    #    exactly as expected or all empty (the decision artifact below is checked either way).
    needs = json.loads(env["NEEDS_JSON"]).get("certify") or {}
    out = needs.get("outputs") or {}
    check("overall", needs.get("result") == "failure", "certify result %r, expected 'failure' (N3 blocks)" % needs.get("result"))
    shown = {k: out.get(k) or "" for k in OUTPUTS}
    if any(shown.values()):
        for k in OUTPUTS:
            check("overall", shown[k] == exp["certify_outputs"][k], "certify output %s=%r, expected %r" % (k, shown[k], exp["certify_outputs"][k]))
        outputs_note = "exposed"
    else:
        outputs_note = "not exposed by GitHub for the failed call (decision read from the artifact)"

    # 2. Only this attempt's evidence, each PEP document exactly once.
    names = sorted(p.name for p in Path(evidence).iterdir()) if Path(evidence).is_dir() else []
    check("overall", names, "no evidence downloaded")
    check("overall", all(n.endswith("-" + sfx) for n in names),
          "evidence from another run or attempt: %r" % [n for n in names if not n.endswith("-" + sfx)])
    docs = {}
    for key, prefix, fn in (("capture", "pep-capture-evidence", "capture-evidence.json"),
                            ("cert_plan", "pep-cert-plan", "cert-plan.json"),
                            ("plan", "pep-invocation-plan", "invocation-plan.json"),
                            ("result", "pep-certification", "cert-result.json"),
                            ("decision", "pep-certification", "cert-decision.json")):
        try:
            docs[key] = _one(evidence, prefix, fn, sfx)
        except (OSError, ValueError) as e:
            problems["overall"].append("%s: %s" % (key, e))
            docs[key] = {}
    cap, cp, plan, res, dec = (docs[k] for k in ("capture", "cert_plan", "plan", "result", "decision"))

    # 3. Run-wide expectations: provenance, inputs, counts, axes, the decision.
    cprov = cap.get("provenance") or {}
    check("overall", (cprov.get("pep_implementation_ref"), cprov.get("pep_resolved_sha")) == (STABLE_SHA, STABLE_SHA),
          "capture provenance %r" % ((cprov.get("pep_implementation_ref"), cprov.get("pep_resolved_sha")),))
    for nm, d in (("capture", cprov), ("cert-plan", cp.get("provenance") or {}), ("plan", plan.get("provenance") or {}),
                  ("result", res.get("provenance") or {})):
        check("overall", (d.get("run_id"), d.get("run_attempt")) == (run_id, att),
              "%s provenance run %r, expected this run (%s, attempt %s)" % (nm, (d.get("run_id"), d.get("run_attempt")), run_id, att))
    rp = res.get("provenance") or {}
    check("overall", (rp.get("pep_requested_ref"), rp.get("pep_resolved_sha")) == (STABLE_SHA, STABLE_SHA),
          "result provenance %r" % ((rp.get("pep_requested_ref"), rp.get("pep_resolved_sha")),))
    check("overall", cap.get("counts") == exp["capture"]["counts"], "capture counts %r, expected %r" % (cap.get("counts"), exp["capture"]["counts"]))
    check("overall", sorted(c.get("cell_id") for c in cap.get("cells") or []) == sorted(case_of),
          "capture cells %r, expected the five case cells" % sorted(c.get("cell_id") for c in cap.get("cells") or []))
    for k in ("plan_resolved", "execution_mode", "release_intent", "coverage_denominators"):
        check("overall", cp.get(k) == exp["cert_plan"][k], "cert-plan %s=%r, expected %r" % (k, cp.get(k), exp["cert_plan"][k]))
    check("overall", sorted(c.get("cell_id") for c in cp.get("cells") or []) == sorted(case_of),
          "cert-plan cells %r" % sorted(c.get("cell_id") for c in cp.get("cells") or []))
    for k in ("execution_mode", "plan_resolved", "release", "counts", "supported_pg_majors", "coverage_gaps", "uncertified_runtime_packages"):
        check("overall", plan.get(k) == exp["plan"][k], "plan %s=%r, expected %r" % (k, plan.get(k), exp["plan"][k]))
    pinc = (plan.get("matrix") or {}).get("include") or []
    check("overall", sorted(i.get("invocation_id") for i in pinc) == sorted(exp_ids),
          "plan invocations %r, expected %r" % (sorted(i.get("invocation_id") for i in pinc), sorted(exp_ids)))
    for k, v in exp["result"].items():
        check("overall", res.get(k) == v, "result %s=%r, expected %r" % (k, res.get(k), v))
    for k, v in exp["decision"].items():
        check("overall", dec.get(k) == v, "decision %s=%r, expected %r" % (k, dec.get(k), v))
    legs = res.get("legs") or []
    check("overall", sorted(l.get("invocation_id") for l in legs) == sorted(exp_ids),
          "result legs %r, expected %r" % (sorted(l.get("invocation_id") for l in legs), sorted(exp_ids)))
    for inv in pinc:
        if inv.get("source_cell_id") not in case_of:
            problems["overall"].append("planned invocation from an unknown cell %r" % inv.get("source_cell_id"))

    # 4. The leg summaries: one per expected invocation, from this run and attempt only.
    summaries = {}
    for d in sorted(Path(evidence).glob("pep-summary-*")):
        tag = d.name[:72] + ": "
        try:
            s = json.loads((d / "summary.json").read_text())
        except (OSError, ValueError) as e:
            problems["overall"].append(tag + "summary: %s" % e)
            continue
        iid = s.get("invocation_id")
        summaries.setdefault(iid, []).append((d, s))
        if iid not in exp_ids:
            problems["overall"].append(tag + "summary for an unplanned invocation %r" % iid)
    for f in (p for p in Path(evidence).rglob("*") if p.is_file()):
        check("overall", b"PRIVATE KEY" not in f.read_bytes(), "%s contains 'PRIVATE KEY'" % f.relative_to(evidence))

    # 5. Which PEP code ran. The adapter's reference and the commit it resolved to are separate
    #    checks; the nested workflows GitHub records under the resolved commit, not the branch.
    try:
        refs = [(r.get("path"), r.get("ref"), r.get("sha")) for r in source.run().get("referenced_workflows") or []]
        adapter = [r for r in refs if (r[0] or "").split("@")[0] == PEP_WF + "pep-release-certify.yml"]
        nested = sorted((r for r in refs if r not in adapter), key=repr)
        check("overall", [r[:2] for r in adapter] == [(PEP_WF + "pep-release-certify.yml@" + STABLE_REF, "refs/heads/" + STABLE_REF)],
              "adapter not called through @%s: %r" % (STABLE_REF, adapter))
        check("overall", [r[2] for r in adapter] == [STABLE_SHA],
              "adapter resolved to %r, expected %s" % ([r[2] for r in adapter], STABLE_SHA))
        check("overall", nested == sorted(((PEP_WF + n + "@" + STABLE_SHA, "refs/heads/" + STABLE_REF, STABLE_SHA) for n in NESTED), key=repr),
              "nested PEP workflows %r, expected %s at %s" % (nested, ", ".join(NESTED), STABLE_SHA))
        jobs = list_jobs(source)
    except (RuntimeError, OSError, ValueError) as e:
        problems["overall"].append("run metadata: %s" % e)
        jobs = []

    # 6. Jobs: exactly the expected set, each once; only PEP's enforce job red (N3).
    leg_names = {leg_job_name(i): i for i in exp["plan"]["invocations"]}
    pkg_names = {c["package_job"]: c for c in fx["cases"]}
    expected_names = set(FIXED_JOBS) | set(leg_names) | set(pkg_names) | {ASSERT_JOB}
    by_name = {}
    for j in jobs:
        by_name.setdefault(j.get("name"), []).append(j)
    for nm, js in sorted(by_name.items(), key=lambda kv: str(kv[0])):
        who = pkg_names[nm]["case"] if nm in pkg_names else of(leg_names[nm]["source_cell_id"]) if nm in leg_names else "overall"
        check(who, nm in expected_names, "unexpected job %r" % nm)
        check(who, len(js) == 1, "%d jobs named %r" % (len(js), nm))
    for nm in sorted(expected_names - set(by_name)):
        who = pkg_names[nm]["case"] if nm in pkg_names else of(leg_names[nm]["source_cell_id"]) if nm in leg_names else "overall"
        problems[who].append("job missing: %r" % nm)
    # This assert job has no log until it finishes, so it alone is skipped, and only when
    # SELF_JOB_ID names it exactly. Every other job is upstream of it: completed, log required.
    own_id = env.get("SELF_JOB_ID", "")
    own = [j for j in jobs if str(j.get("id")) == own_id]
    if not check("overall", own_id.isdigit() and len(own) == 1 and own[0].get("name") == ASSERT_JOB,
                 "own assertion job: SELF_JOB_ID %r does not name %r in this attempt" % (own_id, ASSERT_JOB)):
        own = []
    logs, heads = {}, {}
    for j in jobs:
        if j in own:
            continue
        nm = j.get("name")
        who = pkg_names[nm]["case"] if nm in pkg_names else of(leg_names[nm]["source_cell_id"]) if nm in leg_names else "overall"
        if not check(who, j.get("status") == "completed", "%s: required job not completed (%r)" % (nm, j.get("status"))):
            continue
        want = "failure" if nm == ENFORCE else "success"
        check(who, j.get("conclusion") == want, "%s: concluded %r, expected %r" % (nm, j.get("conclusion"), want))
        try:
            lines = CONTROL.sub("", source.log(j["id"])).splitlines()
        except (RuntimeError, OSError) as e:
            problems[who].append("%s: %s" % (nm, e))
            continue
        logs[nm] = lines
        heads[nm] = set(HEAD_LINE.findall("\n".join(lines)))
        outside = [l for l in lines if not ENV_LINE.match(l)]
        check(who, not [l for l in outside if "PRIVATE KEY-----" in l],
              "%s: PEM key armour in a log line (suspected exposure; not reproduced)" % nm)
        # A preview: neither value may reach ANY executed step of the run.
        for k, val in pair_env(lines):
            check(who, val == "", "%s: %s reached a step (%s)" % (nm, k, "masked" if val == "***" else "unmasked"))
    all_heads = set().union(*heads.values()) if heads else set()
    check("overall", all_heads and all(STABLE_SHA.startswith(h) for h in all_heads),
          "PEP checkouts at %r, expected %s" % (sorted(all_heads), STABLE_SHA[:7]))
    for nm in PEP_CHECKOUT_JOBS:
        if nm in logs:
            check("overall", heads.get(nm), "%s: no PEP checkout found" % nm)
    if ENFORCE in logs:
        d = exp["decision"]
        line = "certification_state=%s reason=%s conclusion=%s" % (d["certification_state"], d["reason_code"], d["workflow_conclusion"])
        text = [body(l) for l in logs[ENFORCE]]
        check("overall", line in text, "enforce did not report %r" % line)
        check("overall", any(l.endswith("Certification blocks the workflow (%s)." % d["reason_code"]) for l in text),
              "enforce did not block for %s" % d["reason_code"])

    # 7. Each case, separately.
    cap_cells = per_cell(cap.get("cells"))
    cp_cells = per_cell(cp.get("cells"))
    inv_by_cell = per_cell(pinc, "source_cell_id")
    gaps_plan, gaps_res = per_cell(plan.get("coverage_gaps")), per_cell(res.get("coverage_gaps"))
    unc_plan, unc_res = per_cell(plan.get("uncertified_runtime_packages")), per_cell(res.get("uncertified_runtime_packages"))
    legs_by_id = per_cell(legs, "invocation_id")
    inventory = [a for a in cap.get("live_inventory") or [] if isinstance(a, dict)]
    exp_gaps = per_cell(exp["plan"]["coverage_gaps"])
    exp_unc = per_cell(exp["plan"]["uncertified_runtime_packages"])
    exp_legs = {l["invocation_id"]: l for l in exp["legs"]}
    for name in CASES:
        c = cases[name]
        cid = c["cell_id"]
        tag = "%s (%s): " % (name, cid)

        # 7a. The package job: the case's files, sha256-checked, uploaded, and its receipt handling.
        js = by_name.get(c["package_job"]) or []
        lines = logs.get(c["package_job"])
        up_digest = None
        if len(js) == 1 and lines is not None:
            okd = sorted(Path(m.group(1)).name for m in (OK_LINE.match(body(l)) for l in lines) if m)
            check(name, okd == sorted(f["file"] for f in c["files"]),
                  tag + "sha256-checked files %r, expected %r" % (okd, sorted(f["file"] for f in c["files"])))
            ups = [u for u in uploads(lines) if u[0] == c["artifact_name"]]
            if check(name, len(ups) == 1 and ups[0][2], tag + "package upload %r not found once with a digest" % c["artifact_name"]):
                up_digest = ups[0][2]
                inv = [a for a in inventory if a.get("name") == c["artifact_name"]]
                check(name, len(inv) == 1 and (inv[0].get("id"), inv[0].get("digest")) == ups[0][1:],
                      tag + "package artifact in capture's inventory %r, upload logged %r" % (inv, ups[0][1:]))
            steps = receipt_steps(lines)
            wrote = [m.groups() for m in (WROTE.match(body(l)) for l in lines) if m]
            if c["receipt"] == "none":
                check(name, not steps and not wrote, tag + "a receipt step ran (%d), expected none" % len(steps))
            elif check(name, len(steps) == 1 and len(wrote) == 1, tag + "%d receipt step(s), %d receipt(s) written, expected 1" % (len(steps), len(wrote))):
                pin, inputs = steps[0]
                check(name, pin == RECEIPT_ACTION, tag + "receipt action %r" % pin)
                check(name, (inputs.get("cell_id"), inputs.get("package_artifact_name")) == (cid, c["artifact_name"]),
                      tag + "receipt inputs %r" % ((inputs.get("cell_id"), inputs.get("package_artifact_name")),))
                check(name, wrote[0] == (str(c["receipt_members"]), cid, "pep-receipt-" + cid),
                      tag + "receipt written %r, expected %d member(s)" % (wrote[0], c["receipt_members"]))
                got = (inputs.get("package_artifact_digest") or "")
                if up_digest:
                    want = up_digest if c["receipt"] == "normal" else tamper(up_digest)
                    check(name, got.split(":")[-1] == want,
                          tag + "receipt recorded digest %r, expected %r (%s)" % (got, want, "the upload's" if c["receipt"] == "normal" else "the upload's, last hex digit changed"))
                if c["receipt"] == "tampered":
                    printed = dict(m.groups() for m in (TAMPER.match(body(l)) for l in lines) if m)
                    check(name, up_digest and printed.get("upload", "").split(":")[-1] == up_digest
                          and printed.get("receipt", "").split(":")[-1] == tamper(up_digest),
                          tag + "changed-digest step printed %r" % printed)
            receipts = [a for a in inventory if a.get("name") == "pep-receipt-" + cid]
            check(name, len(receipts) == (0 if c["receipt"] == "none" else 1),
                  tag + "%d receipt artifact(s) in capture's inventory" % len(receipts))

        # 7b. Capture, the cert-plan reducer, the planner and the result: exactly the derived values.
        ce = cap_cells.get(cid) or []
        want = exp["capture"]["cells"][cid]
        check(name, len(ce) == 1 and {k: ce[0].get(k) for k in want} == want, tag + "capture %r, expected %r" % (ce, want))
        cc = cp_cells.get(cid) or []
        want = exp["cert_plan"]["cells"][cid]
        if check(name, len(cc) == 1, tag + "%d cert-plan cells" % len(cc)):
            got = {k: cc[0].get(k) for k in ("capture_evidence", "build_state", "target_selection_state", "publication_state")}
            got["members"] = sorted(({k: m.get(k) for k in ("artifact_member_path", "package_name", "package_class", "sha256", "selected", "exclusion_reasons")}
                                     for m in cc[0].get("members") or []), key=lambda m: str(m["artifact_member_path"]))
            got["targets"] = sorted(({k: t.get(k) for k in ("target_id", "physical_package", "build_pg_major", "package", "preview_eligibility", "preview_eligibility_reason")}
                                     for t in cc[0].get("targets") or []), key=lambda t: str(t["target_id"]))
            for k in want:
                check(name, got.get(k) == want[k], tag + "cert-plan %s %r, expected %r" % (k, got.get(k), want[k]))
        invs = inv_by_cell.get(cid, [])
        want_invs = exp_invs.get(cid, [])
        got_invs = sorted(({k: i.get(k) for k in want_invs[0]} if want_invs else i for i in invs), key=repr)
        check(name, got_invs == sorted(want_invs, key=repr), tag + "planned %r, expected %r" % (
            [(i.get("package_name"), i.get("pg_major"), i.get("container_alias")) for i in invs],
            [(i["package_name"], i["pg_major"], i["container_alias"]) for i in want_invs]))
        check(name, gaps_plan.get(cid, []) == exp_gaps.get(cid, []), tag + "plan gaps %r, expected %r" % (gaps_plan.get(cid, []), exp_gaps.get(cid, [])))
        check(name, gaps_res.get(cid, []) == exp_gaps.get(cid, []), tag + "result gaps %r, expected %r" % (gaps_res.get(cid, []), exp_gaps.get(cid, [])))
        check(name, unc_plan.get(cid, []) == exp_unc.get(cid, []), tag + "plan uncertified %r, expected %r" % (unc_plan.get(cid, []), exp_unc.get(cid, [])))
        check(name, unc_res.get(cid, []) == exp_unc.get(cid, []), tag + "result uncertified %r, expected %r" % (unc_res.get(cid, []), exp_unc.get(cid, [])))

        # 7c. Each expected preview leg: result leg, summary artifact and leg job, exactly once each.
        for wi in want_invs:
            iid = wi["invocation_id"]
            lt = tag + "leg %s: " % iid
            ll = legs_by_id.get(iid, [])
            if check(name, len(ll) == 1, lt + "%d result legs" % len(ll)):
                leg = ll[0]
                for k, v in exp_legs[iid].items():
                    check(name, leg.get(k) == v, lt + "result %s=%r, expected %r" % (k, leg.get(k), v))
                pi = leg.get("planned_invocation") or {}
                check(name, {k: pi.get(k) for k in wi} == wi, lt + "result planned_invocation differs from the plan")
                lp = leg.get("provenance") or {}
                check(name, (lp.get("pep_requested_ref"), lp.get("pep_resolved_sha"), lp.get("caller_run_id"), lp.get("caller_run_attempt"))
                      == (STABLE_SHA, STABLE_SHA, run_id, att), lt + "result leg provenance %r" % lp)
            ss = summaries.get(iid, [])
            if check(name, len(ss) == 1, lt + "%d summary artifacts" % len(ss)):
                d, s = ss[0]
                prefix = "pep-summary-spock-%s-%s-pg%s-%s-%s-certification-preview-" % (
                    wi["family"], wi["arch"], wi["pg_major"], wi["channel"], wi["container_alias"])
                check(name, d.name == "%s%s-%s" % (prefix, iid, sfx), lt + "summary artifact name %r" % d.name)
                sp = s.get("provenance") or {}
                check(name, (sp.get("caller_run_id"), sp.get("caller_run_attempt")) == (run_id, att),
                      lt + "summary from run %r, expected this run (%s, attempt %s)" % ((sp.get("caller_run_id"), sp.get("caller_run_attempt")), run_id, att))
                check(name, (sp.get("pep_requested_ref"), sp.get("pep_resolved_sha")) == (STABLE_SHA, STABLE_SHA),
                      lt + "summary provenance %r" % ((sp.get("pep_requested_ref"), sp.get("pep_resolved_sha")),))
                check(name, (s.get("execution_status"), s.get("test_verdict"), s.get("installed_package_sha256"), s.get("counts"), s.get("identity_evidence"))
                      == ("preview", "not_run", None, ZERO_COUNTS, PREVIEW_IDENTITY), lt + "summary not a preview: %r" % (
                          (s.get("execution_status"), s.get("test_verdict"), s.get("installed_package_sha256"), s.get("counts")),))
                check(name, not (d / "install-evidence.json").exists(), lt + "install evidence present in a preview")
            jn = leg_job_name(wi)
            lines = logs.get(jn)
            if len(by_name.get(jn) or []) == 1 and lines is not None:
                log = "\n".join(lines)
                check(name, heads.get(jn), lt + "no PEP checkout found")
                fwg = framework_group(lines)
                fw_env = dict(pair_env(fwg)) if fwg else {}
                check(name, fwg is not None and fw_env == {"PGEDGE_REPO_CLIENT_CRT": "", "PGEDGE_REPO_CLIENT_KEY": ""},
                      lt + "framework step without the empty client pair (%s)" % ("found" if fwg else "step not found"))
                check(name, "[repo-auth] client certificate:" not in log, lt + "repo-auth check ran in a preview")
                check(name, "Installed client certificate" not in log, lt + "certificate installed in a preview")

    # 8. One row per case cell: what the evidence shows, never inferred from job colour.
    for name in CASES:
        c = cases[name]
        cid = c["cell_id"]
        ce = (cap_cells.get(cid) or [{}])[0]
        invs = inv_by_cell.get(cid, [])
        g = gaps_plan.get(cid, [])
        if invs:
            outcome = "; ".join("preview %s PG%s on %s (summary %s, job %s)" % (
                i.get("package_name"), i.get("pg_major"), i.get("container_alias"),
                "yes" if len(summaries.get(i.get("invocation_id"), [])) == 1 else "MISSING",
                "yes" if len(by_name.get(leg_job_name(i)) or []) == 1 else "MISSING") for i in invs)
        else:
            outcome = "not planned"
        gtxt = "; ".join("%s gap %s: %s" % (x.get("scope"), x.get("reason"), x.get("detail")) for x in g) or "none"
        rows.append((name, cid, "%s%s" % (ce.get("verdict"), " " + ce["code"] if ce.get("code") else ""), outcome, gtxt,
                     "as expected" if not problems[name] else "PROBLEM (%d)" % len(problems[name])))
    return problems, rows, {"outputs": outputs_note, "decision": dec}


def main(argv):
    mode, evidence = argv[1], argv[2]
    env = os.environ
    source = Fixtures(env["VERIFY_FIXTURES"]) if env.get("VERIFY_FIXTURES") else Live(env)
    problems, rows, info = verify(mode, evidence, source, env)
    total = sum(len(v) for v in problems.values())
    verdicts = [(k, "as expected" if not problems[k] else "PROBLEM (%d)" % len(problems[k])) for k in CASES + ("overall",)]
    dec = info.get("decision") or {}
    text = ["case verdicts:"] + ["  %-8s %s" % v for v in verdicts]
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write("## Spock v5 negative cases (preview) through PEP @%s = %s\n\n" % (STABLE_REF, STABLE_SHA[:7]))
            f.write("Validation harness: nothing built or published; the packages are the already-published staging "
                    "files and the receipts are validation fixtures (N1 none, N3 with a changed digest); simulated run, "
                    "publication `skipped`. PEP's enforce job is expected to fail on N3; each case is judged separately.\n\n")
            f.write("decision: certification_state=`%s` policy=`%s` conclusion=`%s` reason=`%s`; certify outputs %s\n\n"
                    % (dec.get("certification_state"), dec.get("policy_decision"), dec.get("workflow_conclusion"),
                       dec.get("reason_code"), info.get("outputs", "not read")))
            f.write("| case | verdict |\n|---|---|\n")
            for v in verdicts:
                f.write("| %s | %s |\n" % v)
            f.write("\n| case | cell | capture | planned preview legs | coverage gaps | case verdict |\n|---|---|---|---|---|---|\n")
            for r in rows:
                f.write("| %s | %s | %s | %s | %s | %s |\n" % r)
            f.write("\n**%s**\n" % ("PASS" if not total else "FAIL: %d problem(s)" % total))
            for k in CASES + ("overall",):
                for p in problems[k]:
                    f.write("- %s: %s\n" % (k, p))
    for k in CASES + ("overall",):
        for p in problems[k]:
            text.append("%s: %s" % (k, p))
    print("\n".join(text))
    print("negative-case evidence as expected" if not total else "%d problem(s)" % total)
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
