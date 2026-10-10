"""Durable, non-LLM Jira delivery dispatcher CLI."""
import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from config import DEFAULTS, ConfigError, load, write_default
from jira import Jira, UncertainOutcome
from launch import launch, live_sessions, reconcile_session, pending_interrogative, LaunchError, ContinueUncertain, DaemonClient, resume_via_continue, is_live_session
from state import StateStore, ACTIVE_STAGES
from workers import PLAN_HEADER, COMPLETION_HEADER, WORKER_BLOCKER_HEADER, parse_approved_plan, parse_completion_report, adf_text, build_worker_prompt, build_resume_prompt, blocker_comment, delivery_report, dispatcher_authored

DEFAULT_STATE=os.path.expanduser("~/.local/share/polytoken/jira-dispatcher")

# Destinations required by the approved lifecycle contract, per state (sampled live).
REQUIRED_DESTINATIONS = {
    "Plannable": ("Ready", "In Progress"),
    "Ready": ("In Progress",),
    "In Progress": ("Blocked", "Awaiting Acceptance"),
    "Blocked": ("Ready",),
}

def dependency_keys(plan):
    raw=plan.get("values",{}).get("Depends on","")
    return [x.strip() for x in raw.replace(","," ").split() if x.strip() and x.strip().lower() not in ("none","n/a")]

def admission(issue,config,plan,dependencies_satisfied=True,repo_owned=False,global_count=0):
    fields=issue.get("fields",{}); issue_type=(fields.get("issuetype") or {}).get("name"); status=(fields.get("status") or {}).get("name")
    if issue_type not in config["allowed_types"] or issue_type in ("Process Friction","Epic","Subtask"): return False,"unsupported issue type"
    if status!="Ready": return False,"status is not Ready"
    project=fields.get(config["custom_project_field"]); project=project.get("value") or project.get("name") if isinstance(project,dict) else project
    if project not in config["repo_mappings"]: return False,"unmapped Project value"
    if not plan: return False,"approved queued plan missing"
    if not dependencies_satisfied: return False,"dependency is not Done"
    if repo_owned: return False,"repository already owned"
    if global_count>=config["max_global_active"]: return False,"global active limit reached"
    return True,"eligible"

def dependencies_done(jira,plan):
    for key in dependency_keys(plan):
        if (jira.get_issue(key).get("fields",{}).get("status") or {}).get("name")!="Done": return False
    return True

def _text(value):
    return adf_text(value)

def _admitted(store):
    return store.get_control("pause","false")!="true" and store.get_control("stop","false")!="true"

def _pending(store,key,stage,operation,payload):
    return store.update(key,stage=stage,pending_operation={"stage":stage,"operation":operation,"payload":payload},event="operation_pending",detail=operation)

def _parse_op(value):
    if isinstance(value,str):
        try: return json.loads(value)
        except ValueError: return None
    return value if isinstance(value,dict) else None

def _comments(jira,key):
    return sorted(jira.comments(key),key=lambda c: str(c.get("created",c.get("updated",""))),reverse=True)

def _when(comment):
    value=comment.get("created") or comment.get("updated") or ""
    try: return datetime.datetime.fromisoformat(value.replace("Z","+00:00")).timestamp()
    except (ValueError,TypeError): return 0

def _transition(jira,store,row,config,destination,hint_path):
    if not _admitted(store): raise RuntimeError("dispatcher paused/stopped before Jira transition")
    hints=config.get("transition_names",{}).get(hint_path,[])
    try:
        item=jira.transition_to(row["key"],destination,hints)
    except UncertainOutcome:
        if jira.verify_transition(row["key"],destination): return None
        raise
    if not jira.verify_transition(row["key"],destination): raise UncertainOutcome("transition response was not verified")
    if not hints or item.get("name") not in hints: store.journal(row["key"],"transition_name_discovered",str(item.get("name")))
    return item

def _preservation(row):
    sid=row.get("session_id"); port=row.get("daemon_port")
    healthy=bool(sid and port and row.get("_healthy"))
    excerpt=row.get("plan_excerpt") or ""
    values={}
    for label in ("Git","Source branch","Effort branch/workspace"):
        m=re.search(r"^%s:\s*(.*)$"%re.escape(label),excerpt,re.M|re.I)
        if m: values[label]=m.group(1).strip()
    branch=values.get("Source branch") or values.get("Git") or row.get("branch")
    workspace=values.get("Effort branch/workspace") or row.get("worktree_path") or row.get("repo")
    if healthy: return True,branch,workspace,"session retained"
    if not workspace or not branch: return False,branch,workspace,"session unavailable and plan lacks branch/workspace"
    try:
        status=subprocess.run(["git","-C",workspace,"status","--porcelain"],capture_output=True,text=True,timeout=15,check=False)
        log=subprocess.run(["git","-C",workspace,"log","--oneline","HEAD~1.."+branch],capture_output=True,text=True,timeout=15,check=False)
        if status.returncode==0 and log.returncode==0 and log.stdout.strip() and not status.stdout.strip():
            return True,branch,workspace,log.stdout.strip()
    except (OSError,subprocess.SubprocessError): pass
    return False,branch,workspace,"committed partial work not verified"

def _blocker_since(row):
    """Earliest timestamp valid NEW blocker/completion evidence can exist.

    After a resume, the durable reply epoch (persisted before delivery) governs;
    a post-delivery launch_time rewrite must never hide blockers posted while
    the reply was being delivered.
    """
    if row.get("resume_reply_time"): return row["resume_reply_time"]
    return row.get("launch_time") or 0

def _recover_or_reconcile(jira,store,key,config,note):
    """Bounded transient recovery; certain failures retry, uncertainty holds."""
    attempts=store.increment(key,"launch_attempts",event="recovery_retry",detail=str(note))
    if attempts>=config["transient_retry_cap"]:
        row=store.get(key)
        _escalate_recovery(jira,store,row,config,str(note))
    else:
        store.update(key,stage="recovery_pending",last_reconcile_notes=str(note),event="recovery_retry_pending",detail=str(attempts))
    return store.get(key)

def _escalate_recovery(jira,store,row,config,reason):
    """Visible escalation after exhausted mechanical recovery.

    From In Progress or Blocked it transitions to Blocked (authorized source
    statuses). From any other status the ticket is NOT transitioned: the
    escalation comment alone makes the stuck effort visible and the lane is
    released for independent work.
    """
    key=row["key"]
    try:
        current=jira.get_issue(key)
        status=(current.get("fields",{}).get("status") or {}).get("name")
        episode=row.get("blocker_episode_id") or uuid.uuid4().hex
        store.update(key,blocker_episode_id=episode,event="recovery_escalation_started",detail=reason)
        body=("Dispatcher recovery escalation\nTicket: %s\nDispatcher episode: %s\n"
              "Reason: transient recovery attempts exhausted\nDetails: %s\n"
              "Decision needed: inspect the retained effort and choose the next action."%(key,episode,reason))
        if not _admitted(store):
            store.update(key,stage="recovery_pending",pending_operation={"stage":"recovery_pending","operation":"escalation","payload":{"reason":str(reason)}},event="recovery_escalation_pending",detail="paused")
            return False
        if status=="In Progress":
            _transition(jira,store,row,config,"Blocked","block")
        elif status not in ("Blocked",):
            # Unauthorized to transition from this status: comment-only escalation.
            comment=jira.reconcile_comment(key,body,["Dispatcher recovery escalation",key,episode])
            store.update(key,stage="blocked",pending_operation=None,blocker_comment_id=str(comment.get("id","")),blocker_comment_time=_when(comment),blocker_episode_id=episode,last_reconcile_notes=reason,event="recovery_escalated_comment_only",detail="status %s; no unauthorized transition"%status)
            return True
        comment=jira.reconcile_comment(key,body,["Dispatcher recovery escalation",key,episode])
        store.update(key,stage="blocked",pending_operation=None,blocker_comment_id=str(comment.get("id","")),blocker_comment_time=_when(comment),blocker_episode_id=episode,last_reconcile_notes=reason,event="recovery_escalated",detail=reason)
        return True
    except Exception as exc:
        # Retain the escalation as its own durable operation so the write replays.
        try: store.update(key,stage="recovery_pending",pending_operation={"stage":"recovery_pending","operation":"escalation","payload":{"reason":str(reason)}},last_reconcile_notes="escalation write pending: "+str(exc),event="recovery_escalation_pending",detail=str(exc))
        except Exception: pass
        return False

def _block_write(jira,store,row,config,payload):
    """Transition to Blocked and post/verify this episode's blocker report; idempotent per episode."""
    key=row["key"]
    episode=payload.get("episode")
    current=jira.get_issue(key)
    status=(current.get("fields",{}).get("status") or {}).get("name")
    if status!="Blocked":
        # Blockers may only ever be entered from the dispatcher-owned In Progress state.
        if status!="In Progress":
            store.journal(key,"block_write_invalid_source_status","blocker write held: Jira status is %s"%status)
            return False
        _transition(jira,store,row,config,"Blocked","block")
    report=blocker_comment(payload.get("reason",""),payload.get("decision",""),row.get("session_id"),
                           payload.get("worktree"),payload.get("branch"),payload.get("commits"),
                           payload.get("checks"),payload.get("remaining"))+"\nTicket: "+key+"\nDispatcher episode: "+episode
    if not _admitted(store): return False
    comment=jira.reconcile_comment(key,report,["Dispatcher blocker report",key,episode])
    store.update(key,stage="blocked",pending_operation=None,blocker_comment_id=str(comment.get("id","")),
                 blocker_comment_time=_when(comment),blocker_episode_id=episode,last_reconcile_notes=payload.get("reason"),
                 event="worker_blocked",detail=payload.get("reason"))
    return True

def _block(jira,store,row,config,reason,decision,checks="not verified",remaining="not verified",healthy=False):
    """Verify preservation first; recoverable work must precede any blocker posting."""
    row=dict(row); row["_healthy"]=healthy
    preserved,branch,worktree,preservation_note=_preservation(row)
    if not preserved:
        store.update(row["key"],stage="recovery_pending",last_reconcile_notes="preservation not verified; lane held: "+preservation_note,event="recovery_pending_preservation",detail=preservation_note)
        return False
    attempts=store.increment(row["key"],"blocker_attempts",event="blocker_attempt_recorded",detail=reason)
    if attempts>config.get("max_blocker_attempts",3):
        return _escalate_recovery(jira,store,store.get(row["key"]),config,"blocker attempt cap exceeded: "+reason)
    episode=uuid.uuid4().hex
    payload={"episode":episode,"reason":reason,"decision":decision,"worktree":worktree,"branch":branch,
             "commits":preservation_note,"checks":checks,"remaining":remaining}
    store.update(row["key"],blocker_episode_id=episode,event="blocker_episode_started",detail=reason)
    _pending(store,row["key"],"blocking","block_transition",payload)
    outcome=[False]
    def action():
        if _block_write(jira,store,row,config,payload): outcome[0]=True
    _do_bounded(action,jira,store,row,config,"block write")
    return outcome[0]

def _do_bounded(action,jira,store,row,config,what):
    try:
        action()
    except UncertainOutcome as exc:
        _recover_or_reconcile(jira,store,row["key"],config,"%s uncertain: %s"%(what,exc))
    except Exception as exc:
        _recover_or_reconcile(jira,store,row["key"],config,"%s failed: %s"%(what,exc))

def _acceptance_write(jira,store,row,config,payload):
    """Transition In Progress -> Awaiting Acceptance and post the delivery report; idempotent."""
    key=row["key"]
    current=jira.get_issue(key)
    status=(current.get("fields",{}).get("status") or {}).get("name")
    if status=="In Progress":
        _transition(jira,store,row,config,"Awaiting Acceptance","inprogress_to_awaiting")
        if not _admitted(store): return False
        current=jira.get_issue(key)
        status=(current.get("fields",{}).get("status") or {}).get("name")
    if status!="Awaiting Acceptance":
        store.update(key,stage="recovery_pending",last_reconcile_notes="unexpected status during delivery write: "+str(status),event="acceptance_report_held",detail=str(status))
        return False
    revision=str(payload.get("comment_id") or row.get("session_id") or row["id"])
    report=payload.get("report","")+"\nTicket: "+key+"\nDelivery evidence: "+revision
    if not _admitted(store): return False
    comment=jira.reconcile_comment(key,report,["Delivery report",key,"Delivery evidence: "+revision])
    store.update(key,stage="awaiting",pending_operation=None,completion_comment_id=payload.get("comment_id",""),
                 last_completion_signature=payload.get("comment_id",""),last_reconcile_notes="delivery report written",
                 event="delivery_verified",detail="structured worker report reconciled")
    return True

def _plan_currency_holds(jira,store,key):
    """Re-check that the ticket's newest approved plan is still a complete queued plan."""
    try:
        plan=parse_approved_plan(jira.comments(key))
    except Exception as exc:
        store.journal(key,"replay_plan_fetch_failed","could not re-read the plan; holding: %s"%exc); return False
    if not plan:
        store.journal(key,"replay_held_plan_not_queued","newest approved plan is not a complete queued plan; replay held")
        return False
    return True

def supervise_once(jira,store,config,polytoken="polytoken",sessions_dir=None):
    results=[]
    for original in store.list_efforts():
        stage=original["stage"]
        if stage not in ("selected","ready_to_inprogress","launching","running","recovery_pending","blocking","awaiting"): continue
        key=original["key"]
        operation=_parse_op(original.get("pending_operation"))
        op_name=operation.get("operation") if isinstance(operation,dict) else None
        if stage=="awaiting":
            try:
                current=jira.get_issue(key)
                status_name=(current.get("fields",{}).get("status") or {}).get("name")
                if status_name in ("Done","Canceled","Cancelled"):
                    store.update(key,stage="done",pending_operation=None,event="human_terminal_observed",detail=status_name)
                    results.append((key,"done")); continue
            except Exception as exc:
                store.journal(key,"terminal_status_reconcile_failed",str(exc))
            continue
        row=original
        if row["stage"] in ("selected","ready_to_inprogress") or op_name=="ready_transition":
            try:
                issue=jira.get_issue(key); status=(issue.get("fields",{}).get("status") or {}).get("name")
                if status=="In Progress":
                    store.update(key,stage="launching",pending_operation={"stage":"launching","operation":"spawn","payload":{"not_spawned":True}},event="ready_transition_reconciled",detail="status already In Progress")
                elif status=="Ready":
                    if not _admitted(store): results.append((key,"ready_to_inprogress")); continue
                    if not _plan_currency_holds(jira,store,key):
                        store.update(key,stage="recovery_pending",last_reconcile_notes="plan currency re-check failed",event="ready_transition_held_plan",detail="plan not current queued approval")
                        results.append((key,"recovery_pending")); continue
                    store.update(key,stage="ready_to_inprogress",pending_operation={"stage":"ready_to_inprogress","operation":"ready_transition","payload":{"destination":"In Progress"}},event="ready_transition_retry")
                    _transition(jira,store,row,config,"In Progress","ready_to_inprogress")
                    store.update(key,stage="launching",pending_operation={"stage":"launching","operation":"spawn","payload":{"not_spawned":True}},event="ready_transition_verified")
                else:
                    store.update(key,stage="recovery_pending",last_reconcile_notes="unexpected status during launch recovery: "+str(status),event="ready_transition_held",detail=str(status)); results.append((key,"recovery_pending")); continue
            except UncertainOutcome as exc:
                _recover_or_reconcile(jira,store,key,config,"ready transition uncertain: %s"%exc)
                results.append((key,store.get(key)["stage"])); continue
            except Exception as exc:
                _recover_or_reconcile(jira,store,key,config,"ready transition failed: %s"%exc)
                results.append((key,store.get(key)["stage"])); continue
            row=store.get(key); operation=_parse_op(row.get("pending_operation"))
            op_name=operation.get("operation") if isinstance(operation,dict) else None
        if op_name=="block_transition":
            try:
                row=store.get(key)
                if _block_write(jira,store,row,config,operation.get("payload") or {}):
                    results.append((key,"blocked"))
                else: results.append((key,store.get(key)["stage"]))
            except UncertainOutcome as exc: _recover_or_reconcile(jira,store,key,config,"block write uncertain: %s"%exc); results.append((key,store.get(key)["stage"]))
            except Exception as exc: _recover_or_reconcile(jira,store,key,config,"block write failed: %s"%exc); results.append((key,store.get(key)["stage"]))
            continue
        if op_name=="acceptance_report":
            try:
                row=store.get(key)
                if _acceptance_write(jira,store,row,config,operation.get("payload") or {}):
                    results.append((key,"awaiting"))
                else: results.append((key,store.get(key)["stage"]))
            except UncertainOutcome as exc: _recover_or_reconcile(jira,store,key,config,"delivery write uncertain: %s"%exc); results.append((key,store.get(key)["stage"]))
            except Exception as exc: _recover_or_reconcile(jira,store,key,config,"delivery write failed: %s"%exc); results.append((key,store.get(key)["stage"]))
            continue
        if op_name=="escalation":
            try:
                row=store.get(key)
                if _escalate_recovery(jira,store,row,config,operation.get("payload",{}).get("reason","recovery exhausted")):
                    results.append((key,"blocked"))
                else: results.append((key,store.get(key)["stage"]))
            except Exception as exc: _recover_or_reconcile(jira,store,key,config,"escalation retry failed: %s"%exc); results.append((key,store.get(key)["stage"]))
            continue
        if op_name=="resume":
            # Persisted resume operations are driven by resume_candidates, which
            # replays them even when Jira is already In Progress.
            results.append((key,"resume")); continue
        if op_name=="spawn" and row["stage"] in ("launching","recovery_pending"):
            try:
                issue=jira.get_issue(key); status=(issue.get("fields",{}).get("status") or {}).get("name")
                if status!="In Progress":
                    store.update(key,stage="recovery_pending",last_reconcile_notes="spawn held because Jira is "+str(status),event="spawn_recovery_held",detail=str(status)); results.append((key,"recovery_pending")); continue
                if not _plan_currency_holds(jira,store,key):
                    store.update(key,stage="recovery_pending",last_reconcile_notes="plan currency re-check failed before spawn",event="spawn_held_plan",detail="plan not current queued approval")
                    results.append((key,"recovery_pending")); continue
                try: sessions=live_sessions(polytoken)
                except Exception as exc:
                    store.update(key,stage="recovery_pending",last_reconcile_notes="spawn registry scan failed; no relaunch: "+str(exc),event="spawn_registry_pending")
                    results.append((key,"recovery_pending")); continue
                intent=_parse_op(row.get("launch_intent")) or {}
                adopted=reconcile_session(key,row["repo"],sessions,sessions_dir,launch_intent=intent or None,launch_time=row.get("launch_time"),identity_confirmed=lambda sid,port:store.update(key,session_id=sid,daemon_port=port,pending_operation=None,stage="running",event="adopted_identity_captured"))
                if adopted:
                    sid,daemon=adopted; session=next((s for s in sessions if (s.get("session_id") or s.get("id"))==sid),{})
                    store.update(key,stage="running",session_id=sid,daemon_port=session.get("port"),pending_operation=None,event="spawn_reconciled",detail="unique live session")
                elif store.get(key).get("session_id"):
                    store.update(key,stage="recovery_pending",last_reconcile_notes="confirmed identity unhealthy; no duplicate spawn",event="adopted_health_pending")
                elif not (intent.get("dispatch_started") is False or not intent and (operation.get("payload") or {}).get("not_spawned") is True):
                    # Legacy/lost acknowledgments are uncertain, even after an empty scan.
                    store.update(key,stage="recovery_pending",last_reconcile_notes="original spawn not proven absent; registry cannot authorize relaunch",event="spawn_uncertain_held")
                elif not _admitted(store): results.append((key,"launching")); continue
                else:
                    payload=(operation.get("payload") or {}) if isinstance(operation,dict) else {}
                    launch(row["repo"],payload.get("facet","quick-delivery"),payload.get("prompt") or build_worker_prompt(key,row.get("plan_excerpt",""),row.get("blocker_attempts",0)),store,key,polytoken=polytoken,sessions_dir=sessions_dir,timeout=config.get("launch_timeout_seconds",3600))
                results.append((key,store.get(key)["stage"])); continue
            except UncertainOutcome as exc:
                _recover_or_reconcile(jira,store,key,config,"spawn uncertain: %s"%exc)
                results.append((key,store.get(key)["stage"])); continue
            except Exception as exc:
                _recover_or_reconcile(jira,store,key,config,"spawn failed: %s"%exc)
                results.append((key,store.get(key)["stage"])); continue
        # Healthy-session supervision (running rows).
        healthy=False; state={}
        try:
            if row.get("session_id") and row.get("daemon_port"):
                root=sessions_dir or os.path.expanduser("~/.local/share/polytoken/sessions-v1")
                from launch import _credential
                token=_credential(row["session_id"],root); daemon=DaemonClient(row["daemon_port"],token); daemon.health(); state=daemon.state(); daemon.events(); healthy=True
        except Exception: state={}
        if not healthy:
            try: sessions=live_sessions(polytoken)
            except Exception as exc:
                store.update(key,stage="recovery_pending",last_reconcile_notes="live-session ownership scan failed: %s"%exc,event="recovery_pending")
                results.append((key,"recovery_pending")); continue
            recorded=row.get("session_id")
            if recorded:
                adopted=reconcile_session(key,row["repo"],[s for s in sessions if (s.get("session_id") or s.get("id"))==recorded],sessions_dir,identity_confirmed=lambda sid,port:store.update(key,session_id=sid,daemon_port=port,event="retained_identity_captured"))
            else:
                intent=_parse_op(row.get("launch_intent"))
                adopted=reconcile_session(key,row["repo"],sessions,sessions_dir,launch_intent=intent,launch_time=row.get("launch_time"),identity_confirmed=lambda sid,port:store.update(key,session_id=sid,daemon_port=port,event="adopted_identity_captured"))
            if adopted:
                sid,daemon=adopted; session=next((s for s in sessions if (s.get("session_id") or s.get("id"))==sid),{})
                store.update(key,stage="running",session_id=sid,daemon_port=session.get("port"),event="session_adopted",detail="exact unique live match")
                state=daemon.state(); daemon.events(); healthy=True; row=store.get(key)
            else:
                attempts=store.increment(key,"launch_attempts",event="session_missing",detail="no exact live session match")
                if attempts>=config["transient_retry_cap"]:
                    _escalate_recovery(jira,store,store.get(key),config,"retained session missing or unhealthy")
                else:
                    store.update(key,stage="recovery_pending",last_reconcile_notes="session missing/unhealthy; no exact match",event="session_reconcile_pending",detail=str(attempts))
                results.append((key,store.get(key)["stage"])); continue
        row=dict(row); row["_healthy"]=healthy
        pending=pending_interrogative(daemon)
        recorded_pending=row.get("pending_interrogative")
        if not pending and recorded_pending:
            store.update(key,pending_interrogative=None,event="interrogative_cleared",detail="daemon reports no pending question")
            row=store.get(key)
        if pending:
            store.update(key,pending_interrogative=pending,event="pending_interrogative",detail=str(pending))
            _block(jira,store,row,config,"Worker has a pending question: "+_text(pending),"Operator answer in Jira is required",healthy=healthy)
            results.append((key,store.get(key)["stage"])); continue
        comments=_comments(jira,key)
        since=_blocker_since(row)
        blocker=next((c for c in comments if WORKER_BLOCKER_HEADER in _text(c.get("body")) and _when(c)>since),None)
        if blocker:
            try: _block(jira,store,row,config,_text(blocker.get("body")),"Operator decision/reply in Jira is required",healthy=healthy)
            except Exception as exc: store.update(key,stage="recovery_pending",last_reconcile_notes=str(exc),event="block_write_uncertain",detail=str(exc))
            results.append((key,store.get(key)["stage"])); continue
        since=max(since,row.get("blocker_comment_time") or 0)
        parsed=parse_completion_report(comments,since)
        if parsed:
            completion,facts,body=parsed; signature=str(completion.get("id") or body)
            if row.get("last_completion_signature")==signature and row.get("stage")=="awaiting": results.append((key,"awaiting")); continue
            report=delivery_report(row.get("session_id"),facts["Branch"],facts["Worktree"],facts["Checks"],facts["Review"],facts["Commits"],facts["Remaining manual checks"])
            payload={"comment_id":signature,"destination":"Awaiting Acceptance","report":report,"facts":facts}
            _pending(store,key,"recovery_pending","acceptance_report",payload)
            try:
                _acceptance_write(jira,store,store.get(key),config,payload)
            except Exception as exc:
                _recover_or_reconcile(jira,store,key,config,"delivery write failed: %s"%exc)
            results.append((key,store.get(key)["stage"])); continue
        results.append((key,"running"))
    return results

def _owned_repos(jira,store,config,polytoken="polytoken",exclude_key=None):
    """Canonical repos currently owned; a resumed effort's own retained session never counts against itself."""
    efforts=store.list_efforts()
    own_session=None
    for e in efforts:
        if exclude_key and e["key"]==exclude_key: own_session=e.get("session_id")
    owned={e["canonical_repo"] for e in efforts if e["stage"] in ACTIVE_STAGES and e["key"]!=exclude_key}
    recorded={e.get("session_id") for e in efforts if e.get("session_id")}
    for s in live_sessions(polytoken):
        sid=s.get("session_id") or s.get("id")
        if sid and (sid in recorded or sid==own_session): continue
        path=s.get("project_path") or s.get("working_dir")
        if path and is_live_session(s): owned.add(os.path.realpath(path))
    for issue in jira.search('status = "In Progress"'):
        fields=issue.get("fields",{}); pv=fields.get(config["custom_project_field"]); pv=pv.get("value") or pv.get("name") if isinstance(pv,dict) else pv
        if pv in config["repo_mappings"]: owned.add(config["repo_mappings"][pv]["repo_path"])
    return owned

def _resume_ready(jira,store,row,config,plan,reply,polytoken=None,sessions_dir=None):
    """Claim + persist intent (with the durable reply epoch) + verify Ready->In Progress."""
    key=row["key"]
    reply_time=None
    try: reply_time=_when(reply) if isinstance(reply,dict) else None
    except Exception: reply_time=None
    try:
        if not _admitted(store): return row,"paused"
        store.resume_claim(key,{"reply_id":str(reply.get("id") or ""),},repo=row.get("canonical_repo"),global_limit=config["max_global_active"])
        row=store.get(key)
        prompt=build_resume_prompt(key,plan["excerpt"],_text(reply.get("body")),reply.get("id") or "",row.get("blocker_attempts",0))
        # Persist the exact prompt, reply text and the DURABLE reply epoch before any
        # external transition; delivery later must not move this epoch.
        store.update(key,resume_intent={"prompt":prompt,"reply_id":str(reply.get("id") or ""),"reply_text":_text(reply.get("body")),"reply_time":reply_time},event="resume_intent_persisted",detail=str(reply.get("id") or ""))
        if not _admitted(store): return store.get(key),"paused"
        _transition(jira,store,store.get(key),config,"In Progress","ready_to_inprogress")
        return store.get(key),None
    except UncertainOutcome as exc:
        _recover_or_reconcile(jira,store,key,config,"resume transition uncertain: %s"%exc); return store.get(key),"held"
    except Exception as exc:
        _recover_or_reconcile(jira,store,key,config,"resume transition failed: %s"%exc); return store.get(key),"held"

def resume_candidates(jira,store,config,polytoken="polytoken",sessions_dir=None,facet="quick-delivery"):
    """Resume human-unblocked efforts; replays persisted resume operations too."""
    outcomes=[]
    for row in store.list_efforts():
        if row["stage"] not in ("blocked","blocking","recovery_pending","awaiting"): continue
        key=row["key"]
        operation=_parse_op(row.get("pending_operation"))
        resuming=bool(operation and operation.get("operation")=="resume")
        try:
            issue=jira.get_issue(key)
        except Exception:
            store.journal(key,"resume_status_fetch_failed","could not fetch ticket status; holding"); outcomes.append((key,"held")); continue
        fields=issue.get("fields",{})
        status_name=(fields.get("status") or {}).get("name")
        if status_name in ("Done","Canceled","Cancelled") and row["stage"]=="awaiting":
            store.update(key,stage="done",pending_operation=None,event="human_terminal_observed",detail=status_name)
            outcomes.append((key,"done")); continue
        if status_name!="Ready" and not (resuming and status_name=="In Progress"):
            continue
        try:
            comments=jira.comments(key)
        except Exception:
            store.journal(key,"resume_comments_fetch_failed","could not fetch comments; holding"); outcomes.append((key,"held")); continue
        plan=parse_approved_plan(comments)
        if not plan:
            store.journal(key,"resume_ineligible_plan","newest approved plan is not a complete queued approved plan"); outcomes.append((key,"skipped")); continue
        issue_type=(fields.get("issuetype") or {}).get("name")
        project=fields.get(config["custom_project_field"]); project=project.get("value") or project.get("name") if isinstance(project,dict) else project
        if issue_type not in config["allowed_types"] or project not in config["repo_mappings"]:
            store.journal(key,"resume_ineligible_ticket","type/mapping no longer eligible: %s/%s"%(issue_type,project)); outcomes.append((key,"skipped")); continue
        if not dependencies_done(jira,plan):
            store.journal(key,"resume_dependency_unsatisfied","dependency is not Done"); outcomes.append((key,"skipped")); continue
        if not resuming:
            blocker_time=row.get("blocker_comment_time") or 0
            if not blocker_time:
                store.journal(key,"resume_blocker_time_unverified","blocker comment time not verified; not authorizing replies"); outcomes.append((key,"skipped")); continue
            consumed=str(row.get("consumed_reply_id") or "")
            reply=next((c for c in _comments(jira,key) if _when(c)>blocker_time and str(c.get("id") or "")!=consumed and not dispatcher_authored(_text(c.get("body")))),None)
            if not reply:
                store.journal(key,"ready_without_relevant_answer","ready without relevant answer; not speculating"); outcomes.append((key,"skipped")); continue
            try:
                owned=_owned_repos(jira,store,config,polytoken,exclude_key=key)
            except Exception as exc:
                store.journal(key,"resume_ownership_scan_failed","could not verify repository ownership; not speculating: %s"%exc); outcomes.append((key,"held")); continue
            if row.get("canonical_repo") in owned:
                store.journal(key,"resume_repository_occupied","canonical repository is already owned; holding"); outcomes.append((key,"held")); continue
            if not _admitted(store): outcomes.append((key,"paused")); continue
            row,outcome=_resume_ready(jira,store,row,config,plan,reply)
            if outcome: outcomes.append((key,outcome)); continue
        else:
            # A persisted resume with Jira still Ready must reconcile the
            # Ready->In Progress transition (verify/complete) before executing;
            # the durable resume_intent is preserved untouched.
            if status_name=="Ready":
                try:
                    if not _admitted(store): outcomes.append((key,"paused")); continue
                    _transition(jira,store,store.get(key),config,"In Progress","ready_to_inprogress")
                except UncertainOutcome as exc:
                    _recover_or_reconcile(jira,store,key,config,"resume transition uncertain: %s"%exc); outcomes.append((key,store.get(key)["stage"])); continue
                except Exception as exc:
                    _recover_or_reconcile(jira,store,key,config,"resume transition failed: %s"%exc); outcomes.append((key,store.get(key)["stage"])); continue
        row=store.get(key)
        outcomes.append(_resume_execute(jira,store,row,config,sessions_dir,polytoken,facet))
    return outcomes

def _resume_execute(jira,store,row,config,sessions_dir,polytoken,facet):
    """Deliver the persisted reply to the worker: retained question, continue, or fresh launch."""
    key=row["key"]
    intent=row.get("resume_intent")
    if isinstance(intent,str):
        try: intent=json.loads(intent)
        except ValueError: intent={}
    if not isinstance(intent,dict): intent={}
    prompt=intent.get("prompt")
    pending=row.get("pending_interrogative")
    if isinstance(pending,str):
        try: pending=json.loads(pending)
        except ValueError: pending=None
    if pending is not None and not isinstance(pending,dict): pending={"id":str(pending)}
    reply_time=intent.get("reply_time")
    consume={"consumed_reply_id":str(intent.get("reply_id") or ""), "resume_reply_time":reply_time, "pending_interrogative":None}
    retained_sid=row.get("session_id")
    # A retained question is answered through the respond endpoint; resolution must
    # be verified against the daemon state, not assumed.
    if pending and pending.get("id") and retained_sid:
        try:
            root=sessions_dir or os.path.expanduser("~/.local/share/polytoken/sessions-v1")
            from launch import _credential
            token=_credential(retained_sid,root)
            daemon=DaemonClient(row.get("daemon_port"),token); daemon.health()
            if not _admitted(store): return (key,"paused")
            daemon.respond(pending.get("id"),intent.get("reply_text") or "")
            state=daemon.state()
            if state.get("pending_interrogative") or state.get("interrogative"):
                store.journal(key,"resume_interrogative_resolution_unverified","respond acknowledged but the question is still pending; holding")
                return (key,"held")
            store.update(key,pending_interrogative=None,event="interrogative_answered",detail=str(pending.get("id")))
            row=store.get(key)
        except Exception as exc:
            store.journal(key,"resume_interrogative_respond_failed",str(exc))
            _recover_or_reconcile(jira,store,key,config,"interrogative respond failed: %s"%exc)
            return (key,store.get(key)["stage"])
    elif pending and not retained_sid:
        store.journal(key,"resume_interrogative_no_session","retained question without a retained session; holding")
        return (key,"held")
    if retained_sid:
        confirmed_sid=None
        try:
            if not _admitted(store): return (key,"paused")
            sid,port=resume_via_continue(retained_sid,polytoken)
            confirmed_sid=sid
            store.update(key,session_id=sid,daemon_port=port,event="continued_identity_captured")
            if not _admitted(store): return (key,"paused")
            root=sessions_dir or os.path.expanduser("~/.local/share/polytoken/sessions-v1")
            from launch import _credential
            daemon=DaemonClient(port,_credential(sid,root))
            if not _admitted(store): return (key,"paused")
            daemon.prompt(prompt or "")
            store.update(key,stage="running",session_id=sid,daemon_port=port,pending_operation=None,**consume,event="effort_resumed",detail="continued original session")
            return (key,"resumed")
        except (ContinueUncertain,TimeoutError,OSError,UncertainOutcome) as exc:
            return (key,_reconcile_retained(jira,store,key,confirmed_sid or retained_sid,polytoken,sessions_dir,consume,prompt))
        except Exception as exc:
            if confirmed_sid:
                store.update(key,stage="recovery_pending",last_reconcile_notes="confirmed continuation needs reconciliation: "+str(exc),event="resume_identity_retained")
                return (key,"recovery_pending")
            return (key,_resume_fresh(jira,store,store.get(key),config,sessions_dir,polytoken,facet,reason=str(exc)))
    return (key,_resume_fresh(jira,store,store.get(key),config,sessions_dir,polytoken,facet,reason=None))

def _reconcile_retained(jira,store,key,sid,polytoken,sessions_dir,consume,prompt):
    """Uncertain continuation: verify health, then (re)send the reply so it is never silently consumed."""
    try:
        sessions=live_sessions(polytoken)
        candidates=[s for s in sessions if (s.get("session_id") or s.get("id"))==sid]
        if len(candidates)==1:
            s=candidates[0]; root=sessions_dir or os.path.expanduser("~/.local/share/polytoken/sessions-v1")
            from launch import _credential
            token=_credential(sid,root); daemon=DaemonClient(s.get("port"),token)
            daemon.health()
            state=daemon.state()
            if not (state.get("pending_interrogative") or state.get("interrogative")):
                if not _admitted(store): return "paused"
                daemon.prompt(prompt or "")
                store.update(key,stage="running",session_id=sid,daemon_port=s.get("port"),pending_operation=None,**consume,event="effort_resumed",detail="retained session reconciled; reply re-sent")
                return "resumed"
    except (TimeoutError,OSError,LaunchError):
        pass
    store.update(key,stage="recovery_pending",last_reconcile_notes="uncertain continuation outcome; deferring fresh launch",event="resume_uncertain",detail=sid)
    return "recovery_pending"

def _resume_fresh(jira,store,row,config,sessions_dir,polytoken,facet,reason):
    key=row["key"]
    intent=row.get("resume_intent")
    if isinstance(intent,str):
        try: intent=json.loads(intent)
        except ValueError: intent={}
    if not isinstance(intent,dict): intent={}
    consume={"consumed_reply_id":str(intent.get("reply_id") or ""), "resume_reply_time":intent.get("reply_time") or time.time(), "pending_interrogative":None}
    try:
        if not _admitted(store): return "paused"
        launch(row.get("repo"),facet,intent.get("prompt") or build_resume_prompt(key,"","","",row.get("blocker_attempts",0)),store,key,polytoken=polytoken,sessions_dir=sessions_dir,timeout=config.get("launch_timeout_seconds",3600))
        store.update(key,**consume,event="effort_resumed",detail=("fresh recovery launch"+(" after continue failure: "+str(reason) if reason else "")))
        return "resumed"
    except Exception as exc:
        note="fresh launch failed: %s"%(str(exc))
        _recover_or_reconcile(jira,store,key,config,note)
        return "recovery_pending"

def process_candidates(jira,store,config,facet="quick-delivery",polytoken="polytoken"):
    report=[]
    try:
        owned=_owned_repos(jira,store,config,polytoken)
    except Exception as exc:
        return [{"key":None,"eligible":False,"reason":"ownership/admission scan failed: %s"%exc}]
    try:
        issues=list(jira.search())
    except Exception as exc:
        return [{"key":None,"eligible":False,"reason":"Jira admission scan failed: %s"%exc}]
    for issue in issues:
        key=issue.get("key"); fields=issue.get("fields",{})
        project=fields.get(config["custom_project_field"]); project=project.get("value") or project.get("name") if isinstance(project,dict) else project
        repo=config["repo_mappings"].get(project,{}).get("repo_path")
        # Listing fetches are comment-free; the approved plan is read per candidate.
        plan=None; dep_ok=False
        if (issue.get("fields",{}).get("issuetype") or {}).get("name") in config["allowed_types"] and (fields.get("status") or {}).get("name")=="Ready" and repo:
            try: plan=parse_approved_plan(jira.comments(key))
            except Exception as exc:
                report.append({"key":key,"eligible":False,"reason":"plan fetch failed: %s"%exc}); continue
            dep_ok=dependencies_done(jira,plan) if plan else False
        intended_stage=(fields.get("status") or {}).get("name")
        stage_note="status is not Ready" if intended_stage!="Ready" else None
        eligible,reason=admission(issue,config,plan,dep_ok,repo in owned if repo else False,store.active_count())
        if stage_note and not eligible: reason=stage_note
        report.append({"key":key,"eligible":eligible,"reason":reason})
        if not eligible: continue
        if not _admitted(store): break
        try: row=store.claim(key,repo,repo,config["max_global_active"],str(plan["comment"].get("id","")),plan["excerpt"])
        except RuntimeError: continue
        try:
            _pending(store,key,"ready_to_inprogress","ready_transition",{"destination":"In Progress"})
            if not _admitted(store): break
            _transition(jira,store,row,config,"In Progress","ready_to_inprogress")
            prompt=build_worker_prompt(key,plan["excerpt"],row["blocker_attempts"])
            store.update(key,stage="launching",pending_operation={"stage":"launching","operation":"spawn","payload":{"repo":repo,"facet":facet,"prompt":prompt}},event="transition_verified")
            launch(repo,facet,prompt,store,key,polytoken=polytoken,timeout=config["launch_timeout_seconds"]); owned.add(repo)
        except UncertainOutcome as exc: store.update(key,stage="recovery_pending",last_reconcile_notes=str(exc),event="write_uncertain",detail=str(exc))
        except Exception as exc:
            _recover_or_reconcile(jira,store,key,config,str(exc))
    return report

def status(store):
    efforts=store.list_efforts(); counts={"active":0,"waiting":0,"blocked":0,"blocked-recovery":0,"uncertain(recovery_pending)":0,"done":0}
    for e in efforts:
        stage=e["stage"]
        if stage in ("running","launching"): counts["active"]+=1
        elif stage in ("selected","ready_to_inprogress","awaiting"): counts["waiting"]+=1
        elif stage=="blocked": counts["blocked"]+=1
        elif stage=="blocking": counts["blocked-recovery"]+=1
        elif stage=="recovery_pending": counts["uncertain(recovery_pending)"]+=1
        elif stage=="done": counts["done"]+=1
    print(json.dumps({"paused":store.get_control("pause","false")=="true","stopped":store.get_control("stop","false")=="true","summary":counts,"efforts":efforts,"session_associations":store.associations()},indent=2,default=str))

def preflight(config,store_dir):
    """Read-only runtime checks; per-type/per-path outcomes; pending is a warning, not a pass."""
    errors=[]; warnings=[]; verified=[]
    for name in ("python3","polytoken","git"):
        exe=shutil.which(name)
        if not exe: errors.append(name+" missing")
        elif name=="polytoken":
            try: subprocess.run([exe,"models"],capture_output=True,text=True,timeout=20,check=True)
            except Exception as exc: errors.append("polytoken models failed: %s"%exc)
    for name,item in config["repo_mappings"].items():
        path=item["repo_path"]
        if not os.path.isdir(path): errors.append("repo path missing: "+name)
        elif not os.path.isdir(os.path.join(path,".git")): errors.append("not a git repository: "+name)
    if not os.access(store_dir,os.W_OK) and os.path.exists(store_dir): errors.append("state dir not writable")
    try:
        from mcp_client import MCPClient
        client=MCPClient(config["gateway_url"],timeout=5); client.initialize()
        jira=Jira(client,config["jira_project"],config["custom_project_field"])
        jira.discover_cloud_id()
        present_types=set()
        try:
            metadata=jira.issue_types()
            present_types={t.get("name") for t in metadata or []}
        except Exception as exc:
            warnings.append("pending: issue-type metadata sample failed: %s"%exc)
        for t in config["allowed_types"]:
            if present_types and t not in present_types:
                warnings.append("pending: issue type %s not present in project metadata"%t)
            elif present_types:
                verified.append("issue type %s present"%t)
        for t in config["allowed_types"]:
            try: issues=[i for i in jira.search('issuetype = "%s"'%t)][:50]
            except Exception as exc:
                warnings.append("pending: could not sample tickets for type %s: %s"%(t,exc)); continue
            by_state={}
            for issue in issues:
                state=(issue.get("fields",{}).get("status") or {}).get("name")
                if state not in by_state:
                    by_state[state]=issue.get("key")
                    try: transitions=jira.transitions(issue.get("key"))
                    except Exception as exc:
                        warnings.append("pending: transition metadata failed for %s (%s): %s"%(issue.get("key"),t,exc)); continue
                    vals=transitions.get("transitions",transitions) if isinstance(transitions,dict) else transitions
                    required=REQUIRED_DESTINATIONS.get(state,())
                    for destination in required:
                        if any((item.get("to") or {}).get("name")==destination for item in vals or []):
                            verified.append("%s %s -> %s sampled on %s"%(t,state,destination,issue.get("key")))
                        else:
                            warnings.append("pending: no sampled %s ticket in state %s offered a transition to %s"%(t,state,destination))
            for state in REQUIRED_DESTINATIONS:
                if state not in by_state:
                    warnings.append("pending: no %s ticket in state %s to sample"%(t,state))
    except Exception as exc: warnings.append("gateway/Jira checks pending: %s"%exc)
    return errors,warnings,verified

def run_once(args,config,store):
    if not config["active"]: raise ConfigError("dispatcher config active is false; refusing ticket processing")
    from mcp_client import MCPClient
    client=MCPClient(config["gateway_url"]); client.initialize(); jira=Jira(client,config["jira_project"],config["custom_project_field"],agent_sessions_field=config["agent_sessions_field"],store=store)
    if store.get_control("stop","false")=="true":
        for e in store.list_efforts():
            if e["stage"] in ("launching","running"): store.journal(e["key"],"supervision detached","daemon left alive; no new admission")
        return []
    supervise_once(jira,store,config,polytoken=args.polytoken,sessions_dir=getattr(args,"sessions_dir",None))
    resume_candidates(jira,store,config,polytoken=args.polytoken,sessions_dir=getattr(args,"sessions_dir",None),facet=args.facet)
    if store.get_control("pause","false")=="true": return []
    results=process_candidates(jira,store,config,facet=args.facet,polytoken=args.polytoken)
    jira.sync_attribution(store)
    return results

def main(argv=None):
    parser=argparse.ArgumentParser(); parser.add_argument("command",choices=("run","status","pause","resume","stop","preflight","init-config")); parser.add_argument("--once",action="store_true"); parser.add_argument("--state-dir",default=DEFAULT_STATE); parser.add_argument("--config"); parser.add_argument("--facet",default="quick-delivery"); parser.add_argument("--polytoken",default="polytoken"); parser.add_argument("--sessions-dir",default=None)
    args=parser.parse_args(argv); cfgpath=args.config or os.path.join(args.state_dir,"config.json")
    if args.command=="init-config":
        try: write_default(cfgpath); print(cfgpath); return 0
        except FileExistsError: print("config already exists: "+cfgpath,file=sys.stderr); return 1
    try: config=load(cfgpath)
    except ConfigError as exc: print(str(exc),file=sys.stderr); return 2
    os.makedirs(args.state_dir,mode=0o700,exist_ok=True); store=StateStore(args.state_dir)
    try:
        if args.command=="status": status(store); return 0
        if args.command in ("pause","resume","stop"):
            store.set_control("pause","true" if args.command=="pause" else "false")
            if args.command=="stop": store.set_control("stop","true")
            if args.command=="resume": store.set_control("stop","false"); store.set_control("pause","false")
            return 0
        if args.command=="preflight":
            errors,warnings,verified=preflight(config,args.state_dir)
            for e in errors: print("ERROR: "+e)
            for v in verified: print("OK: "+v)
            for w in warnings: print("WARNING: "+w)
            print("Preflight: "+("FAIL" if errors else "local checks passed; gateway/Jira and per-type sampling pending/verified as listed above"))
            return bool(errors)
        if args.command=="run":
            try:
                run_once(args,config,store)
            except ConfigError as exc:
                # An inactive config is an expected, operator-controlled state —
                # report it cleanly instead of crashing with a traceback.
                print("Dispatcher inactive: %s"%exc)
                return 0
            while True:
                if args.once or store.get_control("stop","false")=="true": break
                time.sleep(config["launch_poll_interval_seconds"])
                run_once(args,config,store)
            return 0
    finally: store.close()
    return 0

if __name__=="__main__": raise SystemExit(main())
