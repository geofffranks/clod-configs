"""Worker-brief and Jira plan parsing helpers."""
import re

PLAN_HEADER="## Approved delivery plan"

def parse_approved_plan(comments):
    for comment in comments or []:
        body=comment.get("body","")
        if isinstance(body,dict):
            body="\n".join(part.get("text","") for part in body.get("content",[]) if isinstance(part,dict))
        if not isinstance(body,str) or PLAN_HEADER not in body: continue
        section=body[body.find(PLAN_HEADER):]
        values={}
        for label in ("Git", "Delivery mode", "Review panel", "Source branch", "Effort branch/workspace", "Depends on"):
            match=re.search(r"^%s:\s*(.*)$"%re.escape(label),section,re.M|re.I)
            if match: values[label]=match.group(1).strip()
        if values.get("Delivery mode","").lower()!="queued": continue
        if not values.get("Git") or not values.get("Review panel"): continue
        return {"comment":comment,"excerpt":section.strip(),"values":values}
    return None

def build_worker_prompt(key,plan_excerpt,blocker_attempts=0):
    return """Unattended queued delivery for Jira ticket %s.

Approved delivery plan:
%s

Work only in the approved effort workspace and follow the approved plan. Commit partial intended work regularly to the approved branch. Never push or merge without explicit authority in the plan. Do not create a worktree or change the plan's repository/branch choices. Use the established lappie/appium-mcp project procedures for device and integration resources. If a resource conflicts or an admission prerequisite is unsatisfied, stop and report a blocker rather than proceeding.

Report blocker outcomes including any pending question. Do not guess an answer to a pending daemon question. Limit problem-solving attempts to three; this effort has recorded %d prior blocker attempt(s). Consult the appropriate downstream reasoning channels for blockers, then make at most one bounded new approach with the advice documented. If still unresolved, report the blocker outcome and recovery advice.

At completion, post a completion comment with actual checks run and results, reviews performed and signatures, Git facts (branch, commits, worktree), remaining work, and remaining manual checks. Do not claim checks or review that did not happen. The dispatcher will verify delivery and move the ticket to Awaiting Acceptance; do not transition Jira status yourself.""" % (key,plan_excerpt,blocker_attempts)

def blocker_comment(reason,decision,session_id,worktree,branch,commits,checks,remaining):
    return ("Dispatcher blocker report\nReason: %s\nDecision needed: %s\nSession: %s\nWorktree: %s\nBranch: %s\nCommits: %s\nChecks/review: %s\nRemaining work/limits: %s" % (reason,decision,session_id or "none",worktree or "none",branch or "none",commits or "none",checks or "not verified",remaining or "unknown"))

def delivery_report(session_id,branch,worktree,checks,review,commits,remaining_manual_checks):
    return ("Delivery report\nSession id: %s\nBranch: %s\nWorktree: %s\nCommits: %s\nChecks: %s\nReview: %s\nRemaining manual checks: %s"%(session_id or "not verified",branch or "not verified",worktree or "not verified",commits or "not verified",checks or "not verified",review or "not verified",remaining_manual_checks or "not verified"))
