#!/usr/bin/env python3
"""Evidence check for the temporary PEP Spock v5 full check (T2). Validation harness only.

Run by the workflow's assert job; also run offline against fixtures. Usage:

    verify_spock_full.py full <evidence-dir>

The evidence directory holds this run's downloaded PEP artifacts (pep-certification-*,
pep-invocation-plan-*, pep-cert-plan-*, pep-capture-evidence-*, pep-summary-*). The expected
cells, files and checksums come from spock-fixtures.json beside this script, the same table the
package jobs downloaded and checksum-verified. Run metadata, the attempt's jobs (every page) and
their logs come from the GitHub API, or, when VERIFY_FIXTURES names a directory, from run.json,
jobs.json and logs/<job id>.log there. NEEDS_JSON is the assert job's toJSON(needs). SELF_JOB_ID
is the assert job's own id (job.check_run_id): that job is still running, so it is the one job
whose log is not read; every other job must have completed successfully with a readable log.
Exit status 0 only if the evidence matches every expectation below.

Coverage is counted from evidence, never from job colour: each of the 56 detector cells must be
accepted by capture, and each PG16-18 cell must appear exactly once as an invocation, a matched
result leg, a leg job and a summary artifact of this run and attempt; each PG19 cell must be
exactly one pg_not_supported gap. Anything absent is reported as missing, not as covered.

The adapter is called through the branch reference @v1_STABLE. The reference and the commit it
resolved to are checked separately: GitHub records the adapter as `...@v1_STABLE` (ref
refs/heads/v1_STABLE) and each nested PEP workflow as `...@<commit>`; all must be STABLE_SHA, as
must PEP's own provenance records and its checkouts.

What the run is: the packages are the already-published spock50 5.0.13-1 staging files,
downloaded and checksum-verified, and the receipts are recorded in the run. Nothing is built or
published, and no original build provenance is established. `simulated: false` and the `success`
publication inputs are synthetic.
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
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path
from urllib.parse import urlsplit

STABLE_REF = "v1_STABLE"
STABLE_SHA = "9b3c9e964487568a7b3f3a8f0a3c68000fe0d943"   # v1_STABLE after PEP #38 merged
PEP_WF = "pgEdge/pgedge-pep-test/.github/workflows/"
NESTED = ("pep-capture.yml", "pep-certify.yml", "pep-integration.yml")
HEAD_LINE = re.compile(r"HEAD is now at ([0-9a-f]{7,40}) ")
NAMES = ("PGEDGE_REPO_CLIENT_CRT", "PGEDGE_REPO_CLIENT_KEY")
FIXTURES = Path(__file__).with_name("spock-fixtures.json")

# The release identity the harness passes (synthetic where the header says so).
COMPONENT, VERSION, BUILDNUM, TAG, CHANNEL = "spock", "5.0.13", "1", "v5.0.13", "staging"
SUPPORTED_PG = ("16", "17", "18")                  # PEP S: pep_exec_catalog.json supported_pg_majors
N_CELLS, N_LEGS, N_GAPS, N_UNCERTIFIED = 56, 42, 14, 16
# The container PEP's planner picks for each (os, arch) at S (pep_exec_catalog.json + containers_list.json).
ALIAS = {("el-9", "amd64"): "oel9-amd64", ("el-9", "arm64"): "rocky9-arm64",
         ("el-10", "amd64"): "alma10-amd64", ("el-10", "arm64"): "alma10-arm64"}
ALIAS.update({(os_, a): "%s-%s" % (cat, a) for os_, cat in (("bookworm", "debian12"), ("trixie", "debian13"),
              ("jammy", "ubuntu2204"), ("noble", "ubuntu2404"), ("resolute", "ubuntu2604"))
              for a in ("amd64", "arm64")})
DIST = {"el-9": "el9", "el-10": "el10"}            # release dist token; a DEB cell's is its codename
UNCERTIFIED_REASON = ("RPM-only JIT bitcode companion; the Spock functional test does not install it "
                      "or exercise JIT")           # aspects/pipeline/pep_capture_policy.json, spock entry
IDENTITY = {"l1": "proven", "l2a": "proven", "l2b": "not_attempted"}
COUNTS = {"tests": 15, "failures": 0, "errors": 0, "skipped": 1}
SKIP_TEST = "test_verify_spock_pkg_version"
SKIP_MESSAGE = "integration mode: test_spock_identity checks the exact requested version"
# Every leg runs exactly these test functions once each (run 40662190528's Spock JUnit); only the
# parametrized id after "[" differs by platform.
TESTS = ("test_install_prerequisites", "test_configure_repository", "test_install_spock_packages",
         "test_verify_spock_pkg_version", "test_spock_identity", "test_verify_bundled_files", "test_verify_sbom",
         "test_initialize_nodes", "test_setup_cross_wiring", "test_verify_spock_extension_version", "test_spock_node",
         "test_show_sub_status", "test_insert_and_verify_replication", "test_cleanup_nodes", "test_component_uninstall")
OUTPUTS = {"certification_state": "incomplete", "execution_status": "completed", "test_verdict": "pass",
           "coverage_status": "partial", "certification_conclusion": "success", "reason_code": "partial_coverage"}
DECISION = {"certification_state": "incomplete", "policy_decision": "report", "workflow_conclusion": "success",
            "reason_code": "partial_coverage", "requested_mode": "observe"}
RESULT_COUNTS = {"expected_invocations": 42, "matched": 42, "completed": 42, "pass": 42, "fail": 0,
                 "incomplete": 0, "infra_failure": 0, "not_run": 0, "preview": 0, "missing": 0,
                 "unexpected_results": 0, "planner_gaps": 14}
CERTIFY = "Certify packages (PEP)"
LEG_SUFFIX = " / full test (install and product tests)"
ASSERT_JOB = "assert Spock v5 full evidence"
FIXED_JOBS = ("Detect build matrix", "Check the 56 detector cells",
              "Fixed validation identity (synthetic inputs; nothing is published)",
              CERTIFY + " / Release inputs", CERTIFY + " / certify / identity",
              CERTIFY + " / certify / capture / capture", CERTIFY + " / certify / plan",
              CERTIFY + " / certify / aggregate", CERTIFY + " / certify / enforce",
              CERTIFY + " / Release certification summary", ASSERT_JOB)
PEP_CHECKOUT_JOBS = (CERTIFY + " / Release inputs", CERTIFY + " / certify / capture / capture",
                     CERTIFY + " / certify / plan", CERTIFY + " / certify / aggregate",
                     CERTIFY + " / Release certification summary")
PER_PAGE, MAX_PAGES = 100, 20

CONTROL = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-_]|[\x00-\x08\x0b-\x1f\x7f-\x9f]")
ENV_LINE = re.compile(r"^\S+\s+(PGEDGE_REPO_CLIENT_(?:CRT|KEY)):(?: (.*))?$")
PEM_ARMOUR = re.compile(r"-----(?:BEGIN|END) [A-Z0-9 ]*(?:PRIVATE KEY|CERTIFICATE)[A-Z0-9 ]*-----")
PG_IN_NAME = re.compile(r"postgresql-?(\d+)")


class _HttpsOnlyRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urlsplit(newurl).scheme != "https":
            raise urllib.error.URLError("refused non-HTTPS redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def all_jobs(page):
    """Every job of the attempt: pages of PER_PAGE until total_count jobs are read. A run of this
    harness has more than 100 jobs, so a single page would silently drop the rest."""
    jobs, total = [], None
    for n in range(1, MAX_PAGES + 1):
        doc = page(n)
        batch, count = doc.get("jobs"), doc.get("total_count")
        if not isinstance(batch, list) or not isinstance(count, int) or isinstance(count, bool):
            raise RuntimeError("jobs page %d is malformed" % n)
        if total is None:
            total = count
        elif count != total:
            raise RuntimeError("jobs total_count changed between pages (%d, then %d)" % (total, count))
        jobs += batch
        if len(jobs) >= total or not batch:
            break
    ids = [j.get("id") for j in jobs]
    if len(jobs) != total or len(set(ids)) != len(ids):
        raise RuntimeError("jobs listing incomplete: %d listed (%d distinct) of total_count %r"
                           % (len(jobs), len(set(ids)), total))
    return jobs


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

    def jobs(self):
        return all_jobs(lambda n: self._gh("repos/%s/actions/runs/%s/attempts/%s/jobs?per_page=%d&page=%d"
                                           % (self.repo, self.run_id, self.att, PER_PAGE, n)))

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
    """run.json, jobs.json (served in pages of PER_PAGE, as the API serves it) and logs/<id>.log."""

    def __init__(self, d):
        self.d = Path(d)

    def run(self):
        return json.loads((self.d / "run.json").read_text())

    def jobs(self):
        doc = json.loads((self.d / "jobs.json").read_text())
        return all_jobs(lambda n: {"total_count": doc["total_count"],
                                   "jobs": doc["jobs"][(n - 1) * PER_PAGE:n * PER_PAGE]})

    def log(self, jid):
        return (self.d / "logs" / ("%s.log" % jid)).read_text()


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


def expected_cells(fx):
    """Per detector cell: identity, its runtime and llvmjit files, pin, container, artifact and job names."""
    out = {}
    for cid, d in sorted(fx["detector"].items()):
        files = fx["cells"][cid]
        runtime = [f for f in files if f["class"] == "runtime"]
        if len(runtime) != 1:
            raise ValueError("fixture cell %s has %d runtime files" % (cid, len(runtime)))
        dist = DIST.get(d["os"], d["os"])
        base = d["image"].split(":")[1]
        name = ("rpm__el-%s__%s__pg%s" if d["family"] == "rpm" else "deb__%s__%s__pg%s") % (base, d["arch"], d["pg_major"])
        out[cid] = dict(d, cell_id=cid, files=files, runtime=runtime[0], release="1." + dist,
                        pin="%s-1.%s" % (VERSION, dist), alias=ALIAS[(d["os"], d["arch"])],
                        tested=d["pg_major"] in SUPPORTED_PG, artifact=name,
                        jit=[f for f in files if f["class"] == "llvmjit"],
                        job="Package %s (%s %s pg%s) [pep-cell:%s]" % (d["family"].upper(), d["image"], d["arch"],
                                                                     d["pg_major"], cid),
                        leg_job="%s / certify / %s · PG%s · %s%s" % (CERTIFY, ALIAS[(d["os"], d["arch"])],
                                                                   d["pg_major"], runtime[0]["name"], LEG_SUFFIX))
    return out


def expected_invocation(c, repo):
    rt = c["runtime"]
    return {"arch": c["arch"], "channel": CHANNEL, "component": COMPONENT, "container_alias": c["alias"],
            "effective_tag": TAG, "expected_binary": "", "expected_buildnum": BUILDNUM,
            "expected_deb": c["pin"] if c["family"] == "deb" else "",
            "expected_rpm": c["pin"] if c["family"] == "rpm" else "", "expected_version": VERSION,
            "family": c["family"], "package": {"name": rt["name"], "native_arch": rt["arch"], "release": c["release"],
                                               "sha256": rt["sha256"], "version": VERSION},
            "package_name": rt["name"], "pg_major": c["pg_major"], "producer_repo": repo,
            "source_cell_id": c["cell_id"], "source_target_id": "%s::%s" % (c["cell_id"], rt["name"])}


def expected_gaps(cells):
    return sorted(({"arch": c["arch"], "cell_id": c["cell_id"], "detail": c["pg_major"], "family": c["family"],
                    "os": c["os"], "physical_package": c["runtime"]["name"], "reason": "pg_not_supported",
                    "scope": "target", "target_id": "%s::%s" % (c["cell_id"], c["runtime"]["name"])}
                   for c in cells.values() if not c["tested"]), key=lambda g: g["cell_id"])


def expected_uncertified(cells):
    return sorted(({"arch": c["arch"], "build_pg_major": c["pg_major"], "cell_id": c["cell_id"], "family": c["family"],
                    "os": c["os"], "path": f["file"], "physical_package": f["name"], "reason": UNCERTIFIED_REASON,
                    "sha256": f["sha256"]} for c in cells.values() for f in c["jit"]),
                  key=lambda u: (u["cell_id"], u["physical_package"]))


def differ(got, want, keys):
    """A short account of two record lists: what is missing and what is unexpected."""
    def show(r):
        return tuple(r.get(k) for k in keys) if isinstance(r, dict) else repr(r)[:60]
    return "missing %s; unexpected %s" % ([show(r) for r in want if r not in got][:3], [show(r) for r in got if r not in want][:3])


def _one(evidence, prefix, filename):
    hits = sorted(Path(evidence).glob("%s-r*-a*/%s" % (prefix, filename)))
    if len(hits) != 1:
        raise ValueError("%d %s/%s found" % (len(hits), prefix, filename))
    return json.loads(hits[0].read_text())


def junit_problems(d, s, c, tag):
    """The leg's JUnit report (the one current-run.json names): 15 tests, the one intended skip."""
    out = []
    try:
        cur = json.loads((d / "current-run.json").read_text())
        reports = cur.get("reports") or []
        if len(reports) != 1:
            return [tag + "current-run.json names %d reports, expected 1" % len(reports)]
        rel = reports[0][len("test-logs/"):] if reports[0].startswith("test-logs/") else None
        if not rel or ".." in Path(rel).parts or not (d / rel).is_file():
            return [tag + "JUnit report %r not in the artifact" % reports[0]]
        if Path(rel).name != "report-%s-spock-%s.xml" % (c["family"], c["pg_major"]):
            out.append(tag + "JUnit report %r is not this leg's family and PG major" % rel)
        root = ET.fromstring((d / rel).read_bytes())
    except (OSError, ValueError, ET.ParseError) as e:
        return [tag + "JUnit report: %s" % e]
    suites = [root] if root.tag == "testsuite" else root.findall("testsuite")
    got = {k: sum(int(x.get(k, "0")) for x in suites) for k in COUNTS}
    if got != COUNTS:
        out.append(tag + "JUnit counts %r, expected %r" % (got, COUNTS))
    cases = [tc for x in suites for tc in x.iter("testcase")]
    skipped = [(tc.get("name"), tc.find("skipped").get("message")) for tc in cases if tc.find("skipped") is not None]
    bad = [tc.get("name") for tc in cases if tc.find("failure") is not None or tc.find("error") is not None]
    if len(cases) != COUNTS["tests"]:
        out.append(tag + "JUnit has %d test cases, expected %d" % (len(cases), COUNTS["tests"]))
    names = Counter((tc.get("name") or "").split("[")[0] for tc in cases)
    if names != Counter(TESTS):
        out.append(tag + "JUnit test names differ: missing %s, unexpected %s"
                   % (sorted((Counter(TESTS) - names).elements()), sorted((names - Counter(TESTS)).elements())))
    if len(skipped) != 1 or not (skipped[0][0] or "").startswith(SKIP_TEST + "[") or skipped[0][1] != SKIP_MESSAGE:
        out.append(tag + "skips %r, expected only %s (%r)" % (skipped, SKIP_TEST, SKIP_MESSAGE))
    if bad:
        out.append(tag + "failed or errored tests %r" % bad)
    if (s.get("counts") or {}) != got:
        out.append(tag + "summary counts %r differ from its JUnit %r" % (s.get("counts"), got))
    return out


def verify(mode, evidence, source, env):
    if mode != "full":
        raise SystemExit("mode must be full")
    out = (json.loads(env["NEEDS_JSON"]).get("certify") or {}).get("outputs") or {}
    run_id, att, run_no, repo = (env.get("GITHUB_RUN_ID", ""), env.get("GITHUB_RUN_ATTEMPT", ""),
                                 env.get("GITHUB_RUN_NUMBER", ""), env.get("GITHUB_REPOSITORY", ""))
    problems, rows = [], []

    def check(ok, what):
        if not ok:
            problems.append(what)
        return ok

    try:
        cells = expected_cells(json.loads(FIXTURES.read_text()))
    except (OSError, ValueError, KeyError) as e:
        return ["fixtures %s: %s" % (FIXTURES.name, e)], [], out, {"cells": {}, "uncertified": [], "ev": {}}
    check(len(cells) == N_CELLS and sum(c["tested"] for c in cells.values()) == N_LEGS
          and sum(len(c["jit"]) for c in cells.values()) == N_UNCERTIFIED,
          "fixtures: %d cells, %d tested, %d llvmjit" % (len(cells), sum(c["tested"] for c in cells.values()),
                                                          sum(len(c["jit"]) for c in cells.values())))
    tested = {cid for cid, c in cells.items() if c["tested"]}
    # Per-cell evidence, filled below; the coverage table is computed from it alone.
    ev = {cid: {"capture": None, "inv": None, "leg": None, "summary": [], "job": None, "gap": None, "tests": "", "sha": ""}
          for cid in cells}
    listed = []

    # 1. The adapter's own outputs: every axis and the policy reason, not just the state.
    for k, v in OUTPUTS.items():
        check(out.get(k) == v, "certify output %s=%r, expected %r" % (k, out.get(k), v))

    # 2. Every downloaded artifact belongs to this run number and attempt.
    for d in (sorted(p for p in Path(evidence).iterdir() if p.is_dir()) if Path(evidence).is_dir() else []):
        check(d.name.endswith("-r%s-a%s" % (run_no, att)), "%s: not an artifact of run %s attempt %s" % (d.name[:80], run_no, att))

    # 3. Capture accepted exactly the 56 receipts, each bound to its cell's package artifact.
    try:
        cap = _one(evidence, "pep-capture-evidence", "capture-evidence.json")
        c = cap.get("counts") or {}
        want = {"planned_cells": N_CELLS, "receipt_candidates": N_CELLS, "accepted_receipt_cells": N_CELLS,
                "rejected_receipt_cells": 0, "ambiguous_receipt_cells": 0, "absent_receipt_cells": 0,
                "verified_package_artifacts": N_CELLS,
                "verified_members": sum(len(x["files"]) for x in cells.values())}
        check(c == want, "capture counts %r, expected %r" % (c, want))
        inv = {e.get("id"): e.get("name") for e in cap.get("live_inventory") or []}
        seen = {}
        for x in cap.get("cells") or []:
            seen[x.get("cell_id")] = seen.get(x.get("cell_id"), 0) + 1
            if x.get("cell_id") in ev:
                ev[x["cell_id"]]["capture"] = x.get("verdict")
                cc = cells[x["cell_id"]]
                check((x.get("verdict"), x.get("code")) == ("accepted", None),
                      "capture %s: %r %r" % (x["cell_id"], x.get("verdict"), x.get("code")))
                check(inv.get(x.get("package_artifact_id")) == cc["artifact"]
                      and inv.get(x.get("receipt_artifact_id")) == "pep-receipt-" + x["cell_id"],
                      "capture %s: receipt/package artifacts %r/%r, expected pep-receipt-<cell>/%s"
                      % (x["cell_id"], inv.get(x.get("receipt_artifact_id")), inv.get(x.get("package_artifact_id")), cc["artifact"]))
        check(seen == {cid: 1 for cid in cells}, "capture cells: %d listed, missing %s, extra or repeated %s"
              % (len(seen), sorted(set(cells) - set(seen))[:5], sorted(k for k, n in seen.items() if k not in cells or n > 1)[:5]))
        cp = cap.get("provenance") or {}
        check((cp.get("pep_implementation_ref"), cp.get("pep_resolved_sha")) == (STABLE_SHA, STABLE_SHA),
              "capture provenance %r" % ((cp.get("pep_implementation_ref"), cp.get("pep_resolved_sha")),))
        check((cp.get("run_id"), cp.get("run_attempt")) == (run_id, att),
              "capture is of run %r attempt %r, not this one" % (cp.get("run_id"), cp.get("run_attempt")))
    except (OSError, ValueError) as e:
        problems.append("capture evidence: %s" % e)

    # 4. The cert-plan: the release identity, and every cell's receipt members = the fixture files.
    try:
        cplan = _one(evidence, "pep-cert-plan", "cert-plan.json")
        check(cplan.get("plan_resolved") is True and cplan.get("execution_mode") == mode,
              "cert-plan resolved/mode %r" % ((cplan.get("plan_resolved"), cplan.get("execution_mode")),))
        ri = {"channel": CHANNEL, "effective_tag": TAG, "intended_buildnum": BUILDNUM, "intended_version": VERSION,
              "logical_component": COMPONENT, "simulated": False}
        check(cplan.get("release_intent") == ri, "cert-plan release_intent %r" % cplan.get("release_intent"))
        got = {}
        for x in cplan.get("cells") or []:
            got.setdefault(x.get("cell_id"), []).append(sorted((m.get("artifact_member_path"), m.get("package_name"), m.get("sha256"))
                                                              for m in x.get("members") or []))
        check(sorted(got) == sorted(cells) and all(len(v) == 1 for v in got.values()),
              "cert-plan cells: missing %s, extra %s" % (sorted(set(cells) - set(got))[:5], sorted(set(got) - set(cells))[:5]))
        for cid, c in cells.items():
            want = sorted((f["file"], f["name"], f["sha256"]) for f in c["files"])
            if cid in got:
                check(got[cid][0] == want, "cert-plan %s: receipt members differ from the fixture files" % cid)
    except (OSError, ValueError) as e:
        problems.append("cert-plan: %s" % e)

    # 5. The invocation plan: 42 runs (each PG16-18 runtime package on its own PG major in its
    #    container), the 14 PG19 gaps, and the llvmjit companions listed as not certified.
    try:
        plan = _one(evidence, "pep-invocation-plan", "invocation-plan.json")
        pc = plan.get("counts") or {}
        check(plan.get("plan_resolved") is True and plan.get("execution_mode") == mode,
              "plan resolved/mode %r" % ((plan.get("plan_resolved"), plan.get("execution_mode")),))
        check((pc.get("invocations"), pc.get("planned_cells"), pc.get("coverage_gaps")) == (N_LEGS, N_CELLS, N_GAPS),
              "plan invocations/cells/gaps %r" % ((pc.get("invocations"), pc.get("planned_cells"), pc.get("coverage_gaps")),))
        check(pc.get("gaps_by_scope") == {"cell": 0, "member": 0, "target": N_GAPS}, "plan gaps_by_scope %r" % pc.get("gaps_by_scope"))
        check(plan.get("supported_pg_majors") == list(SUPPORTED_PG), "plan supported_pg_majors %r" % plan.get("supported_pg_majors"))
        check(plan.get("release") == {"channel": CHANNEL, "effective_tag": TAG, "intended_buildnum": BUILDNUM,
                                      "intended_version": VERSION, "logical_component": COMPONENT},
              "plan release %r" % plan.get("release"))
        gaps = sorted(plan.get("coverage_gaps") or [], key=lambda g: str(g.get("cell_id")))
        for g in gaps:
            if g.get("cell_id") in ev:
                ev[g["cell_id"]]["gap"] = "%s (%s)" % (g.get("reason"), g.get("detail"))
        check(gaps == expected_gaps(cells), "plan coverage_gaps differ from the 14 PG19 pg_not_supported gaps: %s"
              % differ(gaps, expected_gaps(cells), ("cell_id", "scope", "reason", "detail")))
        unc = sorted(plan.get("uncertified_runtime_packages") or [], key=lambda u: (str(u.get("cell_id")), str(u.get("physical_package"))))
        listed = [(u.get("cell_id"), u.get("physical_package")) for u in unc if isinstance(u, dict)]
        check(unc == expected_uncertified(cells), "plan uncertified_runtime_packages differ from the 16 RPM llvmjit companions: %s"
              % differ(unc, expected_uncertified(cells), ("cell_id", "physical_package")))
        invs = (plan.get("matrix") or {}).get("include") or []
        by_cell = {}
        for i in invs:
            by_cell.setdefault(i.get("source_cell_id"), []).append(i)
        check(sorted(by_cell) == sorted(tested) and all(len(v) == 1 for v in by_cell.values()) and len(invs) == N_LEGS,
              "plan invocations: %d; missing %s; extra or repeated %s"
              % (len(invs), sorted(tested - set(by_cell))[:5], sorted(k for k, v in by_cell.items() if k not in tested or len(v) > 1)[:5]))
        plan_ids = {}
        for cid, v in by_cell.items():
            if cid in tested and len(v) == 1:
                i = v[0]
                rest = {k: i.get(k) for k in i if k != "invocation_id"}
                check(rest == expected_invocation(cells[cid], repo),
                      "plan %s: %s" % (cid, sorted(k for k in set(rest) | set(expected_invocation(cells[cid], repo))
                                                    if rest.get(k) != expected_invocation(cells[cid], repo).get(k))))
                ok_id = re.fullmatch(r"spock-%s-pg%s-[0-9a-f]{16}" % (re.escape(cells[cid]["alias"]), cells[cid]["pg_major"]),
                                     str(i.get("invocation_id")))
                if check(ok_id, "plan %s: invocation_id %r" % (cid, i.get("invocation_id"))):
                    plan_ids[i["invocation_id"]] = cid
                    ev[cid]["inv"] = i["invocation_id"]
    except (OSError, ValueError) as e:
        problems.append("invocation plan: %s" % e)
        plan_ids = {}

    # 6. The certification result, its decision, and every leg in it.
    try:
        res = _one(evidence, "pep-certification", "cert-result.json")
        dec = _one(evidence, "pep-certification", "cert-decision.json")
        check({k: dec.get(k) for k in DECISION} == DECISION, "decision %r" % {k: dec.get(k) for k in DECISION})
        for k in ("execution_status", "test_verdict", "coverage_status"):
            check(res.get(k) == OUTPUTS[k], "result %s=%r" % (k, res.get(k)))
            check((dec.get("axes") or {}).get(k) == OUTPUTS[k], "decision axis %s=%r" % (k, (dec.get("axes") or {}).get(k)))
        check(res.get("result_resolved") is True and not res.get("errors"), "result not resolved: %r" % res.get("errors"))
        rp = res.get("provenance") or {}
        check((rp.get("pep_requested_ref"), rp.get("pep_resolved_sha")) == (STABLE_SHA, STABLE_SHA),
              "result provenance %r" % ((rp.get("pep_requested_ref"), rp.get("pep_resolved_sha")),))
        check((rp.get("run_id"), rp.get("run_attempt")) == (run_id, att), "result is of run %r attempt %r" % (rp.get("run_id"), rp.get("run_attempt")))
        check(sorted(res.get("coverage_gaps") or [], key=lambda g: str(g.get("cell_id"))) == expected_gaps(cells),
              "result coverage_gaps differ from the 14 PG19 gaps")
        check(sorted(res.get("uncertified_runtime_packages") or [], key=lambda u: (str(u.get("cell_id")), str(u.get("physical_package"))))
              == expected_uncertified(cells), "result uncertified_runtime_packages differ from the 16 llvmjit companions")
        check(not res.get("unexpected_results"), "unexpected results %r" % res.get("unexpected_results"))
        check(not res.get("historical_results"), "historical results %r" % res.get("historical_results"))
        rc = res.get("counts") or {}
        for k, v in RESULT_COUNTS.items():
            check(rc.get(k) == v, "result count %s=%r, expected %r" % (k, rc.get(k), v))
        legs = res.get("legs") or []
        by = {}
        for leg in legs:
            by.setdefault((leg.get("planned_invocation") or {}).get("source_cell_id"), []).append(leg)
        check(sorted(by) == sorted(tested) and all(len(v) == 1 for v in by.values()),
              "result legs: %d; missing %s; extra or repeated %s"
              % (len(legs), sorted(tested - set(by))[:5], sorted(k for k, v in by.items() if k not in tested or len(v) > 1)[:5]))
        for cid, v in by.items():
            if cid not in tested or len(v) != 1:
                continue
            leg, c = v[0], cells[cid]
            tag = "leg %s: " % cid
            pi = leg.get("planned_invocation") or {}
            check({k: pi.get(k) for k in pi if k != "invocation_id"} == expected_invocation(c, repo)
                  and pi.get("invocation_id") == ev[cid]["inv"] == leg.get("invocation_id"),
                  tag + "planned invocation differs from the plan's")
            prov = leg.get("provenance") or {}
            ok = check((leg.get("reconciliation"), leg.get("execution_status"), leg.get("test_verdict")) == ("matched", "completed", "pass"),
                       tag + "reconciliation/status/verdict %r" % ((leg.get("reconciliation"), leg.get("execution_status"), leg.get("test_verdict")),))
            ok &= check(leg.get("package_digest") == "match", tag + "package_digest %r" % leg.get("package_digest"))
            ok &= check(leg.get("installed_package_sha256") == c["runtime"]["sha256"],
                        tag + "installed sha256 %r, fixture %s" % (leg.get("installed_package_sha256"), c["runtime"]["sha256"]))
            ok &= check(leg.get("identity_evidence") == IDENTITY and leg.get("unproven_identity_rungs") == [],
                        tag + "identity %r" % leg.get("identity_evidence"))
            ok &= check(leg.get("counts") == COUNTS, tag + "counts %r, expected %r" % (leg.get("counts"), COUNTS))
            ok &= check((prov.get("pep_requested_ref"), prov.get("pep_resolved_sha")) == (STABLE_SHA, STABLE_SHA),
                        tag + "provenance %r" % ((prov.get("pep_requested_ref"), prov.get("pep_resolved_sha")),))
            ok &= check((prov.get("caller_run_id"), prov.get("caller_run_attempt")) == (run_id, att),
                        tag + "result from run %r attempt %r" % (prov.get("caller_run_id"), prov.get("caller_run_attempt")))
            ev[cid]["leg"] = ("pass" if ok else "PROBLEM") if leg.get("test_verdict") != "fail" else "fail"
    except (OSError, ValueError) as e:
        problems.append("certification result: %s" % e)

    # 7. Each leg's own uploaded evidence: one summary artifact per planned invocation.
    summaries = sorted(Path(evidence).glob("pep-summary-*-r*-a*"))
    check(len(summaries) == N_LEGS, "%d leg summaries, expected %d" % (len(summaries), N_LEGS))
    for d in summaries:
        tag = d.name[:72] + ": "
        try:
            s = json.loads((d / "summary.json").read_text())
        except (OSError, ValueError) as e:
            problems.append(tag + "summary: %s" % e)
            continue
        cid = plan_ids.get(s.get("invocation_id"))
        if not check(cid is not None, tag + "invocation_id %r is not a planned invocation" % s.get("invocation_id")):
            continue
        c = cells[cid]
        before = len(problems)                 # any problem below marks this cell's summary evidence as differing
        ev[cid]["summary"].append(d.name)
        n = s.get("counts") or {}
        ev[cid]["tests"] = "%s: %s skipped, %s failed" % (n.get("tests"), n.get("skipped"), (n.get("failures") or 0) + (n.get("errors") or 0))
        ev[cid]["sha"] = "= fixture" if s.get("installed_package_sha256") == c["runtime"]["sha256"] else "DIFFERS"
        check(d.name.startswith("pep-summary-spock-%s-%s-pg%s-%s-%s-certification-full-%s-r"
                                % (c["family"], c["arch"], c["pg_major"], CHANNEL, c["alias"], s["invocation_id"])),
              tag + "artifact name does not match its leg")
        prov = s.get("provenance") or {}
        check((prov.get("pep_requested_ref"), prov.get("pep_resolved_sha")) == (STABLE_SHA, STABLE_SHA),
              tag + "summary provenance %r" % ((prov.get("pep_requested_ref"), prov.get("pep_resolved_sha")),))
        check((prov.get("caller_run_id"), prov.get("caller_run_attempt")) == (run_id, att),
              tag + "summary from run %r attempt %r, not this run" % (prov.get("caller_run_id"), prov.get("caller_run_attempt")))
        check((s.get("execution_status"), s.get("test_verdict")) == ("completed", "pass"),
              tag + "summary %r" % ((s.get("execution_status"), s.get("test_verdict")),))
        check(s.get("installed_package_sha256") == c["runtime"]["sha256"], tag + "summary installed sha256 %r" % s.get("installed_package_sha256"))
        check(s.get("identity_evidence") == IDENTITY, tag + "summary identity %r" % s.get("identity_evidence"))
        target = {"package_name": c["runtime"]["name"], "family": c["family"], "arch": c["arch"],
                  "pg_major": c["pg_major"], "container_alias": c["alias"], "channel": CHANNEL}
        try:
            ie = json.loads((d / "install-evidence.json").read_text())
            check(ie.get("installed") is True and ie.get("install_kind") == "pinned" and ie.get("install_token") == c["pin"],
                  tag + "install %r %r %r, expected a pinned install of %s" % (ie.get("installed"), ie.get("install_kind"), ie.get("install_token"), c["pin"]))
            check(ie.get("installed_sha256") == c["runtime"]["sha256"], tag + "installed sha256 %r" % ie.get("installed_sha256"))
            check(ie.get("target") == target, tag + "install target %r" % ie.get("target"))
            check(ie.get("run_token") == "%s-%s" % (run_id, att) and ie.get("expected_version") == VERSION,
                  tag + "install run_token/version %r" % ((ie.get("run_token"), ie.get("expected_version")),))
        except (OSError, ValueError) as e:
            problems.append(tag + "install evidence: %s" % e)
        try:
            oi = json.loads((d / "observed-identity.json").read_text())
            check(oi.get("target") == target and (oi.get("observed") or {}).get("package_manager_version") == c["pin"],
                  tag + "observed identity %r" % (oi.get("observed"),))
        except (OSError, ValueError) as e:
            problems.append(tag + "observed identity: %s" % e)
        try:
            pv = json.loads((d / "prerequisite-versions.json").read_text())
            iv = pv.get("installed_versions") or {}
            pgs = {m.group(1) for k in iv for m in [PG_IN_NAME.search(k)] if m}
            check((pv.get("pg_major"), pv.get("channel"), pv.get("requested_package")) == (c["pg_major"], CHANNEL, c["runtime"]["name"])
                  and iv.get(c["runtime"]["name"]) == c["pin"] and pgs == {c["pg_major"]},
                  tag + "prerequisites pg %r channel %r %s=%r, PostgreSQL majors %s"
                  % (pv.get("pg_major"), pv.get("channel"), c["runtime"]["name"], iv.get(c["runtime"]["name"]), sorted(pgs)))
        except (OSError, ValueError) as e:
            problems.append(tag + "prerequisite versions: %s" % e)
        problems.extend(junit_problems(d, s, c, tag))
        ev[cid]["summary_ok"] = len(problems) == before
    for cid, c in cells.items():
        if c["tested"]:
            check(len(ev[cid]["summary"]) == 1, "%s: %d summary artifacts, expected 1" % (cid, len(ev[cid]["summary"])))
    for f in (p for p in Path(evidence).rglob("*") if p.is_file()):
        data = f.read_bytes()
        check(b"PRIVATE KEY" not in data and not PEM_ARMOUR.search(data.decode("latin-1")),
              "%s: PEM armour in an artifact file (not reproduced)" % f.relative_to(evidence))

    # 8. Which PEP code ran. The adapter's reference and the commit it resolved to are separate
    #    checks; the nested workflows GitHub records under the resolved commit, not the branch.
    try:
        refs = [(r.get("path"), r.get("ref"), r.get("sha")) for r in source.run().get("referenced_workflows") or []]
        adapter = [r for r in refs if (r[0] or "").split("@")[0] == PEP_WF + "pep-release-certify.yml"]
        nested = sorted((r for r in refs if r not in adapter), key=repr)
        check([r[:2] for r in adapter] == [(PEP_WF + "pep-release-certify.yml@" + STABLE_REF, "refs/heads/" + STABLE_REF)],
              "adapter not called through @%s: %r" % (STABLE_REF, adapter))
        check([r[2] for r in adapter] == [STABLE_SHA],
              "adapter resolved to %r, expected %s" % ([r[2] for r in adapter], STABLE_SHA))
        check(nested == sorted(((PEP_WF + n + "@" + STABLE_SHA, "refs/heads/" + STABLE_REF, STABLE_SHA) for n in NESTED), key=repr),
              "nested PEP workflows %r, expected %s at %s" % (nested, ", ".join(NESTED), STABLE_SHA))
    except (RuntimeError, OSError, ValueError) as e:
        problems.append("run metadata: %s" % e)
    try:
        jobs = source.jobs()
    except (RuntimeError, OSError, ValueError, KeyError) as e:
        problems.append("jobs listing: %s" % e)
        jobs = []

    # 9. The attempt's jobs: exactly the harness's jobs, each once. The package and leg jobs are
    #    named after their cells, so a missing or extra cell job is visible here too.
    want_names = list(FIXED_JOBS) + [c["job"] for c in cells.values()] + [c["leg_job"] for c in cells.values() if c["tested"]]
    names = {}
    for j in jobs:
        names[j.get("name")] = names.get(j.get("name"), 0) + 1
    check(not jobs or names == {n: 1 for n in want_names},
          "jobs: %d listed, %d expected; missing %s; unexpected or repeated %s"
          % (len(jobs), len(want_names), sorted(set(want_names) - set(names))[:4],
             sorted(n for n, k in names.items() if n not in want_names or k > 1)[:4]))
    by_name = {j.get("name"): j for j in jobs}
    for cid, c in cells.items():
        ev[cid]["job"] = "ok" if by_name.get(c["job"]) else None
    # This assert job has no log until it finishes, so it alone is skipped, and only when
    # SELF_JOB_ID names it exactly. Every other job is upstream of it: completed, log required.
    heads = set()
    own_id = env.get("SELF_JOB_ID", "")
    own = [j for j in jobs if str(j.get("id")) == own_id]
    if not check(own_id.isdigit() and len(own) == 1 and own[0].get("name") == ASSERT_JOB,
                 "own assertion job: SELF_JOB_ID %r does not name %r in this attempt" % (own_id, ASSERT_JOB)):
        own = []
    leg_names = {c["leg_job"]: cid for cid, c in cells.items() if c["tested"]}
    for j in jobs:
        if j in own:
            continue
        name = j.get("name")
        if not check(j.get("status") == "completed", "%s: required job not completed (%r)" % (name, j.get("status"))):
            continue
        check(j.get("conclusion") == "success", "%s: concluded %r" % (name, j.get("conclusion")))
        try:
            lines = CONTROL.sub("", source.log(j["id"])).splitlines()
        except (RuntimeError, OSError) as e:
            problems.append("%s: %s" % (name, e))
            continue
        found = set(HEAD_LINE.findall("\n".join(lines)))
        heads |= found
        if name in leg_names or name in PEP_CHECKOUT_JOBS:
            check(found, "%s: no PEP checkout found" % name)
        check(not [l for l in lines if PEM_ARMOUR.search(l) or "PRIVATE KEY-----" in l],
              "%s: PEM armour in a log line (suspected exposure; not reproduced)" % name)
        for nm, val in pair_env(lines):
            check(val in ("", "***"), "%s: %s shown unmasked in a step (value not reproduced)" % (name, nm))
        if name in leg_names:
            cid = leg_names[name]
            log = "\n".join(lines)
            fwg = framework_group(lines)
            fw_env = dict(pair_env(fwg)) if fwg else {}
            ok = check(fwg is not None, "%s: framework step block not found" % name)
            for nm in NAMES:
                ok &= check(fw_env.get(nm) == "***", "%s: %s did not reach the framework step (%r)" % (name, nm, fw_env.get(nm)))
            ok &= check("[repo-auth] client certificate: complete" in log, "%s: pair not complete at the check" % name)
            ok &= check("Installed client certificate, pgEdge repositories enabled" in log, "%s: certificate not installed" % name)
            ev[cid]["cert"] = "ok" if ok else "PROBLEM"
            rows.append((name, "ok" if ok else "PROBLEM"))
    check(heads and all(STABLE_SHA.startswith(h) for h in heads), "PEP checkouts at %r, expected %s" % (sorted(heads), STABLE_SHA[:7]))
    for cid, c in cells.items():
        if c["tested"]:
            check(by_name.get(c["leg_job"]) is not None and ev[cid].get("cert") == "ok",
                  "%s: no leg job with certificate evidence" % cid)
    return problems, rows, out, {"cells": coverage(cells, ev), "uncertified": listed, "ev": ev}


def coverage(cells, ev):
    """One row per detector cell, from evidence only: tested-pass needs capture, plan, result leg,
    summary (with every check on it passing: install, identity, prerequisites, JUnit), package job and
    leg job (with certificate evidence); a gap needs the plan's gap."""
    table = {}
    for cid, c in cells.items():
        e = ev[cid]
        if c["tested"]:
            have = {"capture": e["capture"] == "accepted", "plan": bool(e["inv"]), "result": e["leg"] is not None,
                    "summary": len(e["summary"]) == 1, "package job": bool(e["job"]), "leg job": e.get("cert") == "ok"}
            lacking = [k for k, v in have.items() if not v]
            if lacking:
                status = "missing: " + ", ".join(lacking)
            elif e["leg"] == "fail":
                status = "tested-fail"
            elif e["leg"] == "PROBLEM" or e.get("summary_ok") is not True:
                status = "tested, evidence differs (see problems)"
            else:
                status = "tested-pass"
        else:
            status = ("gap: " + e["gap"]) if e["gap"] and e["capture"] == "accepted" else "missing: gap not reported"
        table[cid] = status
    return table


def main(argv):
    mode, evidence = argv[1], argv[2]
    env = os.environ
    source = Fixtures(env["VERIFY_FIXTURES"]) if env.get("VERIFY_FIXTURES") else Live(env)
    try:
        problems, rows, out, cov = verify(mode, evidence, source, env)
    except Exception as e:      # malformed evidence of an unexpected shape: still a reported failure
        problems, rows, out = ["verifier stopped on malformed evidence: %s: %s" % (type(e).__name__, e)], [], {}
        cov = {"cells": {}, "uncertified": [], "ev": {}}
    table, ev = cov["cells"], cov["ev"]
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        try:
            cells = expected_cells(json.loads(FIXTURES.read_text()))
        except (OSError, ValueError, KeyError):
            cells = {}
        with open(summary, "a") as f:
            f.write("## Spock v5 full check through PEP @%s = %s\n\n" % (STABLE_REF, STABLE_SHA[:7]))
            f.write("Validation harness, not a release: nothing is built or published. The packages are the "
                    "already-published spock50 5.0.13-1 staging files, downloaded and sha256-checked against the "
                    "fixture table; the receipts bind them to this run's cells only (no build provenance). "
                    "`simulated: false` and the `success` publication inputs are synthetic.\n\n")
            f.write("certification_state=`%s` execution_status=`%s` test_verdict=`%s` coverage_status=`%s` reason_code=`%s`\n\n"
                    % tuple(out.get(k) for k in ("certification_state", "execution_status", "test_verdict",
                                                 "coverage_status", "reason_code")))
            counts = {}
            for v in table.values():
                k = v.split(":")[0]
                counts[k] = counts.get(k, 0) + 1
            f.write("Coverage from evidence: %s\n\n" % ", ".join("%s %d" % kv for kv in sorted(counts.items())))
            f.write("| detector cell | container | PG | package | coverage | tests | installed sha256 |\n"
                    "|---|---|---|---|---|---|---|\n")
            for cid in sorted(table):
                c, e = cells.get(cid) or {}, ev.get(cid) or {}
                f.write("| `%s` | %s | %s | %s | %s | %s | %s |\n" % (cid, c.get("alias"), c.get("pg_major"),
                        (c.get("runtime") or {}).get("name"), table[cid], e.get("tests", ""), e.get("sha", "")))
            f.write("\nListed by the plan as not certified by policy (RPM llvmjit companions, not coverage gaps): %d\n\n"
                    % len(cov["uncertified"]))
            for cid, n in cov["uncertified"]:
                f.write("- `%s` %s\n" % (cid, n))
            f.write("\n| PEP test leg | credential evidence |\n|---|---|\n")
            for r in rows:
                f.write("| %s | %s |\n" % r)
            f.write("\n**%s**\n" % ("PASS" if not problems else "FAIL: %d problem(s)" % len(problems)))
            for p in problems:
                f.write("- %s\n" % p)
    print("\n".join(problems) if problems else "Spock full evidence as expected")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
