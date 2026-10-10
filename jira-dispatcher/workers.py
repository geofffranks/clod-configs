"""Worker-brief and Jira plan parsing helpers."""
import re

PLAN_HEADER="## Approved delivery plan"
COMPLETION_HEADER="## Delivery completion report"
WORKER_BLOCKER_HEADER="Worker blocker report"

# Comments the dispatcher itself posts on an effort's ticket. They are never
# counted as operator replies for resume eligibility.
DISPATCH_AUTHORED_MARKERS=(
    "Dispatcher blocker report",
    "Dispatcher recovery escalation",
    "Delivery report\n",
    COMPLETION_HEADER,
    PLAN_HEADER,
    "## Agent session attribution",
    "Agent session association:",
)


def dispatcher_authored(body):
    if not isinstance(body,str): return False
    return any(marker in body for marker in DISPATCH_AUTHORED_MARKERS)


def adf_text(value):
    """Recursively extract Jira ADF text while retaining paragraph boundaries."""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "".join(adf_text(item) for item in value)
    if not isinstance(value, dict):
        return str(value or "")
    node_type=value.get("type")
    content=value.get("content")
    if isinstance(content,list):
        text="".join(adf_text(child) for child in content)
        if node_type=="heading":
            level=(value.get("attrs") or {}).get("level",2)
            if isinstance(level,int) and 1<=level<=6: text="#"*level+" "+text
        return text + ("\n" if node_type in ("paragraph","heading","blockquote","listItem") and text and not text.endswith("\n") else "")
    return str(value.get("text", ""))


class CommentHistory(list):
    """Returned records plus proven coverage; omission is never an empty history."""
    def __init__(self, records=(), complete=False):
        super().__init__(records)
        self.complete=complete


def comment_history(issue):
    page=(issue.get("fields") or {}).get("comment") if isinstance(issue,dict) else None
    if not isinstance(page,dict) or not isinstance(page.get("comments"),list):
        return CommentHistory()
    records=page["comments"]
    total=page.get("total"); start=page.get("startAt",0); maximum=page.get("maxResults")
    complete=(isinstance(total,int) and not isinstance(total,bool) and total>=0
              and start==0 and len(records)==total
              and (maximum is None or isinstance(maximum,int) and maximum>=len(records))
              and all(isinstance(c,dict) and c.get("id") for c in records)
              and len({str(c["id"]) for c in records})==len(records))
    return CommentHistory(records,complete)


def parse_approved_plan(comments):
    # Plain lists are complete caller-owned snapshots; adapter histories carry coverage.
    if not getattr(comments,"complete",True): return None
    plans=[c for c in comments or [] if PLAN_HEADER in adf_text(c.get("body",""))]
    if not plans: return None
    import datetime
    try:
        stamps=[datetime.datetime.fromisoformat(c["created"].replace("Z","+00:00")).timestamp() for c in plans]
    except (KeyError,ValueError,TypeError):
        if len(plans)!=1: return None
        stamps=[0]
    newest=max(stamps)
    if stamps.count(newest)!=1: return None
    comment=plans[stamps.index(newest)]
    body=adf_text(comment.get("body","")); section=body[body.find(PLAN_HEADER):]
    values={}
    for label in ("Git", "Delivery mode", "Review panel", "Source branch", "Effort branch/workspace", "Depends on"):
        matches=re.findall(r"^%s:[ \t]*(.*)$"%re.escape(label),section,re.M|re.I)
        if len({m.strip().lower() for m in matches})>1: return None
        if matches: values[label]=matches[0].strip()
    mode=values.get("Delivery mode","").lower()
    if not re.match(r"^queued\b",mode): return None
    # Explanatory prose may mention the unselected route; alternatives are ambiguous.
    if re.search(r"(?:/|\|)\s*interactive\b",mode): return None
    if re.search(r"\b(?:or|and|alternatively)\s+interactive\b(?!\s+(?:delivery\s+)?(?:is\s+)?not\b)",mode): return None
    if not all(values.get(x) for x in ("Git","Review panel","Source branch","Effort branch/workspace")): return None
    return {"comment":comment,"excerpt":section.strip(),"values":values}


def parse_completion_report(comments, launch_time=0):
    """Return only a structured, positive worker report with actual results.

    Negative completion evidence (failed checks, rejected review, "not ready"
    outcomes) never authorizes acceptance; it is screened out explicitly.
    """
    negative=r"(?:\bfail(?:ed|s|ure)?\b|\breject(?:ed)?\b|\bnot\s+approved\b|\bchanges?\s+requested\b|\bnot\s+passing\b|\bnot\s+complete\b|\bincomplete\b|\bunresolved\b|\bcrash(?:ed)?\b)"
    for comment in sorted(comments or [], key=lambda c: str(c.get("created", c.get("updated", ""))), reverse=True):
        body=adf_text(comment.get("body", ""))
        if COMPLETION_HEADER not in body or "Worker completion report" not in body: continue
        if re.search(r"(?:\bcompletion\b.{0,80}\b(?:blocked|not ready|not complete|required)\b|\bwhat\s+(?:is\s+)?required\s+for\s+completion\b)",body,re.I): continue
        report=body[body.find(COMPLETION_HEADER):]
        try:
            import datetime
            stamp=comment.get("created") or comment.get("updated") or ""
            when=datetime.datetime.fromisoformat(stamp.replace("Z","+00:00")).timestamp()
        except (ValueError,TypeError):
            when=0
        if when <= launch_time or re.search(r"\bcompletion\s+(?:is\s+)?(?:blocked|not ready|not complete)\b",report,re.I): continue
        fields={}
        for label in ("Checks", "Review", "Branch", "Worktree", "Commits", "Remaining manual checks"):
            m=re.search(r"^%s:\s*(.*)$"%re.escape(label),report,re.M|re.I)
            fields[label]=m.group(1).strip() if m else ""
        if not all(fields[x] and fields[x].lower() not in ("not run","not verified","none") for x in ("Checks","Review","Branch","Worktree","Commits")): continue
        # A structured report with negative check or review outcomes is evidence of
        # unfinished delivery, not a completion.
        if re.search(negative,fields["Checks"],re.I) or re.search(negative,fields["Review"],re.I): continue
        return comment, fields, report
    return None


def build_resume_prompt(key,plan_excerpt,reply_text,reply_id,blocker_attempts=0):
    return """Resume unattended queued delivery for Jira ticket %s. Reply id: %s.

Operator reply:
%s

Current approved plan excerpt:
%s

Preservation: branch/worktree and prior commits are recorded in the dispatcher state; verify them before editing anything. Do not re-answer an already-answered question; the operator's reply above is the decision for the recorded blocker episode. Do not guess answers to any NEW pending daemon question: commit the intended partial work and stop for the next blocker report if one arises.

Limit problem-solving attempts in total to three recorded attempts; this effort has recorded %d prior blocker attempt(s) before this resume.""" % (key,reply_id,reply_text,plan_excerpt,blocker_attempts)


def build_worker_prompt(key,plan_excerpt,blocker_attempts=0):
    return """Unattended queued delivery for Jira ticket %s.

Approved delivery plan:
%s

The dispatcher owns this session's delivery/recovery attribution comment and Agent Sessions update. Do not duplicate those associations; include actual results in the required worker evidence comments. Do not use attribution comments as operator decisions.

Work only in the approved effort workspace and follow the approved plan. Commit partial intended work regularly to the approved branch. Never push or merge without explicit authority in the plan. Do not create a worktree or change the plan's repository/branch choices. Use the established lappie/appium-mcp project procedures for device and integration resources. If a resource conflicts or an admission prerequisite is unsatisfied, stop and report a blocker rather than proceeding.

Report blocker outcomes including any pending question; when you must block, post a comment headed exactly `Worker blocker report` with `Reason:`, `Decision needed:`, `Checks/review:`, and `Remaining work:` fields (commit intended partial work first). Do not guess an answer to a pending daemon question. Limit problem-solving attempts to three; this effort has recorded %d prior blocker attempt(s). Consult the appropriate downstream reasoning channels for blockers, then make at most one bounded new approach with the advice documented. If still unresolved, report the blocker outcome and recovery advice.

At completion, post a comment headed exactly `## Delivery completion report` and include the marker `Worker completion report`, followed by actual `Checks:`, `Review:`, `Branch:`, `Worktree:`, `Commits:`, and `Remaining manual checks:` fields. Include results, reviews performed and signatures, Git facts, remaining work, and manual checks. Do not claim checks or review that did not happen. The dispatcher will verify delivery and move the ticket to Awaiting Acceptance; do not transition Jira status yourself.""" % (key,plan_excerpt,blocker_attempts)

def blocker_comment(reason,decision,session_id,worktree,branch,commits,checks,remaining):
    return ("Dispatcher blocker report\nReason: %s\nDecision needed: %s\nSession: %s\nWorktree: %s\nBranch: %s\nCommits: %s\nChecks/review: %s\nRemaining work/limits: %s" % (reason,decision,session_id or "none",worktree or "none",branch or "none",commits or "none",checks or "not verified",remaining or "unknown"))

def delivery_report(session_id,branch,worktree,checks,review,commits,remaining_manual_checks):
    return ("Delivery report\nDispatcher-observed facts:\nSession id: %s\nBranch: %s\nWorktree: %s\nCommits: %s\nWorker-reported facts:\nChecks: %s\nReview: %s\nRemaining manual checks: %s"%(session_id or "not verified",branch or "not verified",worktree or "not verified",commits or "not verified",checks or "not verified",review or "not verified",remaining_manual_checks or "not verified"))
