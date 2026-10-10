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
from config import DEFAULTS, ConfigError, load, write_default
from jira import Jira, UncertainOutcome
from launch import launch, live_sessions, reconcile_session, pending_interrogative, LaunchError, DaemonClient, resume_via_continue
from state import StateStore, ACTIVE_STAGES
from workers import parse_approved_plan, build_worker_prompt, blocker_comment, delivery_report

DEFAULT_STATE=os.path.expanduser("~/.local/share/polytoken/jira-dispatcher")

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
    if isinstance(value,str): return value
    if isinstance(value,dict): return "\n".join(x.get("text","") for x in value.get("content",[]) if isinstance(x,dict))
    return str(value or "")

def _comments(jira,key):
    return sorted(jira.comments(key),key=lambda c: str(c.get("created",c.get("updated",""))),reverse=True)

def _when(comment):
    value=comment.get("created") or comment.get("updated") or ""
    try: return datetime.datetime.fromisoformat(value.replace("Z","+00:00")).timestamp()
    except (ValueError,TypeError): return 0

def _transition(jira,store,row,config,destination,hint_path):
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
    # The daemon must be responding; the caller has already queried it where possible.
    healthy=bool(sid and port and row.get("_healthy"))
    plan=parse_approved_plan([]) or {}
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
        log=subprocess.run(["git","-C",workspace,"log","--oneline", "HEAD~1.."+branch],capture_output=True,text=True,timeout=15,check=False)
        if status.returncode==0 and log.returncode==0 and log.stdout.strip() and not status.stdout.strip():
            return True,branch,workspace,log.stdout.strip()
    except (OSError,subprocess.SubprocessError): pass
    return False,branch,workspace,"committed partial work not verified"

def _block(jira,store,row,config,reason,decision,checks="not verified",remaining="not verified",healthy=False):
    row=dict(row); row["_healthy"]=healthy
    preserved,branch,worktree,commits=_preservation(row)
    if not preserved:
        store.update(row["key"],stage="recovery_pending",last_reconcile_notes="preservation not verified; lane held: "+commits,event="recovery_pending_preservation",detail=commits)
        return False
    attempts=store.increment(row["key"],"blocker_attempts",event="blocker_attempt_recorded",detail=reason)
    if attempts>config.get("max_blocker_attempts",3):
        store.update(row["key"],stage="blocked",last_reconcile_notes="blocker attempt cap exceeded",event="blocker_escalated",detail=str(attempts))
        return False
    _transition(jira,store,row,config,"Blocked","block")
    report=blocker_comment(reason,decision,row.get("session_id"),worktree,branch,commits,checks,remaining)+"\nTicket: "+row["key"]
    markers=["Dispatcher blocker report",row["key"]]
    comment=jira.reconcile_comment(row["key"],report,markers)
    store.update(row["key"],stage="blocked",blocker_comment_id=str(comment.get("id","")),blocker_comment_time=_when(comment),last_reconcile_notes=reason,event="worker_blocked",detail=reason)
    return True

def supervise_once(jira,store,config,polytoken="polytoken",sessions_dir=None):
    results=[]
    for original in store.list_efforts():
        if original["stage"] not in ("launching","running"): continue
        row=original; key=row["key"]; daemon=None; healthy=False
        try:
            if row.get("session_id") and row.get("daemon_port"):
                root=sessions_dir or os.path.expanduser("~/.local/share/polytoken/sessions-v1")
                from launch import _credential
                token=_credential(row["session_id"],root); daemon=DaemonClient(row["daemon_port"],token); daemon.health(); state=daemon.state(); daemon.events(); healthy=True
            else: state={}
        except Exception: state={}
        if not healthy:
            try: sessions=live_sessions(polytoken)
            except Exception as exc:
                attempts=store.increment(key,"launch_attempts",event="session_reconcile_failed",detail=str(exc))
                store.update(key,stage="recovery_pending",last_reconcile_notes=str(exc),event="recovery_pending",detail="launch retry %d"%attempts)
                results.append((key,"recovery_pending")); continue
            adopted=reconcile_session(key,row["repo"],sessions,sessions_dir)
            if adopted:
                sid,daemon=adopted; session=next((s for s in sessions if (s.get("session_id") or s.get("id"))==sid),{})
                store.update(key,stage="running",session_id=sid,daemon_port=session.get("port"),event="session_adopted",detail="exact unique live match")
                state=daemon.state(); daemon.events(); healthy=True; row=store.get(key)
            else:
                attempts=store.increment(key,"launch_attempts",event="session_missing",detail="no unique exact live session match")
                stage="recovery_pending" if attempts<config["transient_retry_cap"] else "blocking"
                store.update(key,stage=stage,last_reconcile_notes="session missing/unhealthy; no unique match",event="session_reconcile_pending",detail=str(attempts))
                results.append((key,stage)); continue
        row=dict(row); row["_healthy"]=healthy
        pending=pending_interrogative(daemon)
        if pending:
            store.update(key,pending_interrogative=pending,event="pending_interrogative",detail=str(pending))
            try: _block(jira,store,row,config,"Worker has a pending question: "+_text(pending),"Operator answer in Jira is required",healthy=healthy)
            except Exception as exc: store.update(key,stage="recovery_pending",last_reconcile_notes=str(exc),event="block_write_uncertain",detail=str(exc))
            results.append((key,store.get(key)["stage"])); continue
        comments=_comments(jira,key); launch_time=row.get("launch_time") or row.get("created_at") or 0
        blocker=next((c for c in comments if "Dispatcher blocker report" in _text(c.get("body")) and _when(c)>=launch_time),None)
        if blocker:
            try: _block(jira,store,row,config,_text(blocker.get("body")),"Operator decision/reply in Jira is required",healthy=healthy)
            except Exception as exc: store.update(key,stage="recovery_pending",last_reconcile_notes=str(exc),event="block_write_uncertain",detail=str(exc))
            results.append((key,store.get(key)["stage"])); continue
        completion=next((c for c in comments if "completion" in _text(c.get("body")).lower() and _when(c)>launch_time),None)
        if completion:
            body=_text(completion.get("body")); signature=str(completion.get("id") or body)
            if row.get("last_completion_signature")==signature and row.get("stage")=="awaiting": results.append((key,"awaiting")); continue
            try:
                _transition(jira,store,row,config,"Awaiting Acceptance","inprogress_to_awaiting")
                def fact(label):
                    m=re.search(r"^%s:\s*(.*)$"%re.escape(label),body,re.M|re.I); return m.group(1).strip() if m else "not verified"
                report=delivery_report(row.get("session_id"),fact("Branch"),fact("Worktree"),fact("Checks"),fact("Checks"),fact("Commits"),fact("Remaining manual checks"))+"\nTicket: "+key
                jira.reconcile_comment(key,report,["Delivery report",key])
                store.update(key,stage="awaiting",completion_comment_id=str(completion.get("id","")),last_completion_signature=signature,event="delivery_verified",detail="ticket completion comment reconciled")
            except Exception as exc: store.update(key,stage="recovery_pending",last_reconcile_notes=str(exc),event="delivery_reconcile_pending",detail=str(exc))
            results.append((key,store.get(key)["stage"])); continue
        results.append((key,"running"))
    return results

def resume_candidates(jira,store,config,polytoken="polytoken",sessions_dir=None):
    outcomes=[]
    for row in store.list_efforts():
        if row["stage"] not in ("blocked","awaiting","recovery_pending","blocking"): continue
        try: issue=jira.get_issue(row["key"])
        except Exception: continue
        if ((issue.get("fields",{}).get("status") or {}).get("name"))!="Ready": continue
        plan=parse_approved_plan(jira.comments(row["key"]))
        if not plan or plan.get("values",{}).get("Delivery mode","").lower()!="queued":
            store.journal(row["key"],"resume_ineligible_interactive","plan is not queued"); continue
        blocker_time=row.get("blocker_comment_time") or 0
        reply=next((c for c in _comments(jira,row["key"]) if _when(c)>blocker_time and "Dispatcher blocker report" not in _text(c.get("body"))),None)
        if not reply:
            store.journal(row["key"],"ready_without_relevant_answer","ready without relevant answer; not speculating"); outcomes.append((row["key"],"skipped")); continue
        reply_text=_text(reply.get("body")); remaining="See approved plan and prior blocker report; remaining work not independently verified."
        prompt="Resume Jira %s. Operator reply: %s\n\nCurrent approved plan excerpt:\n%s\n\nRemaining work: %s\nPreservation: branch/worktree and prior commits are recorded in the dispatcher state; verify before editing.\nPrior blocker attempts: %d"%(row["key"],reply_text,plan["excerpt"],remaining,row["blocker_attempts"])
        continue_error=None
        if row.get("session_id"):
            try:
                sid,port=resume_via_continue(row["session_id"],polytoken)
                root=sessions_dir or os.path.expanduser("~/.local/share/polytoken/sessions-v1")
                from launch import _credential
                daemon=DaemonClient(port,_credential(sid,root)); daemon.prompt(prompt)
                store.update(row["key"],stage="running",session_id=sid,daemon_port=port,event="effort_resumed",detail="continued original session")
                outcomes.append((row["key"],"resumed")); continue
            except Exception as exc:
                continue_error=str(exc)
        try:
            # If the retained process cannot be continued, seed a fresh worker
            # with the same preservation summary and recorded attempt count.
            sid,daemon=launch(row["repo"],"quick-delivery",prompt,store,row["key"],polytoken=polytoken,sessions_dir=sessions_dir)
            detail="fresh recovery launch"+(" after continue failed: "+continue_error if continue_error else "")
            store.update(row["key"],event="effort_resumed",detail=detail)
            outcomes.append((row["key"],"resumed"))
        except Exception as exc:
            note="continue failed: %s; fresh launch failed: %s"%(continue_error,exc) if continue_error else str(exc)
            store.update(row["key"],stage="recovery_pending",last_reconcile_notes=note,event="resume_uncertain",detail=note); outcomes.append((row["key"],"recovery_pending"))
    return outcomes

def process_candidates(jira,store,config,facet="quick-delivery",sessions=None,polytoken="polytoken"):
    report=[]; owned={e["canonical_repo"] for e in store.list_efforts() if e["stage"] in ACTIVE_STAGES}
    if sessions is None:
        try: sessions=live_sessions(polytoken)
        except Exception as exc: return [{"key":None,"eligible":False,"reason":"live-session ownership scan failed: %s"%exc}]
    for s in sessions:
        path=s.get("project_path") or s.get("working_dir"); state=str(s.get("termination_state",s.get("state",""))).lower()
        if path and state not in ("terminated","dead","stopped","exited"): owned.add(os.path.realpath(path))
    try:
        for issue in jira.search('status = "In Progress"'):
            f=issue.get("fields",{}); pv=f.get(config["custom_project_field"]); pv=pv.get("value") or pv.get("name") if isinstance(pv,dict) else pv
            if pv in config["repo_mappings"]: owned.add(config["repo_mappings"][pv]["repo_path"])
        issues=list(jira.search())
    except Exception as exc: return [{"key":None,"eligible":False,"reason":"Jira ownership/admission scan failed: %s"%exc}]
    for issue in issues:
        key=issue.get("key"); fields=issue.get("fields",{}); plan=parse_approved_plan(((fields.get("comment") or {}).get("comments") or []))
        project=fields.get(config["custom_project_field"]); project=project.get("value") or project.get("name") if isinstance(project,dict) else project
        repo=config["repo_mappings"].get(project,{}).get("repo_path"); dep_ok=dependencies_done(jira,plan) if plan else False
        eligible,reason=admission(issue,config,plan,dep_ok,repo in owned if repo else False,store.active_count()); report.append({"key":key,"eligible":eligible,"reason":reason})
        if not eligible: continue
        try: row=store.claim(key,repo,repo,config["max_global_active"],str(plan["comment"].get("id","")),plan["excerpt"])
        except RuntimeError: continue
        try:
            store.update(key,stage="ready_to_inprogress",event="transition_pending")
            try: t=jira.transition_to(key,"In Progress",config["transition_names"].get("ready_to_inprogress",[]))
            except UncertainOutcome:
                if not jira.verify_transition(key,"In Progress"): raise
                t=None
            if not jira.verify_transition(key,"In Progress"): raise UncertainOutcome("In Progress transition not verified")
            if t and t.get("name") not in config["transition_names"].get("ready_to_inprogress",[]): store.journal(key,"transition_name_discovered",str(t.get("name")))
            store.update(key,stage="launching",event="transition_verified")
            launch(repo,facet,build_worker_prompt(key,plan["excerpt"],row["blocker_attempts"]),store,key,polytoken=polytoken,timeout=config["launch_timeout_seconds"]); owned.add(repo)
        except UncertainOutcome as exc: store.update(key,stage="recovery_pending",last_reconcile_notes=str(exc),event="write_uncertain",detail=str(exc))
        except Exception as exc:
            attempts=store.increment(key,"launch_attempts",detail=str(exc)); stage="blocking" if attempts>=config["transient_retry_cap"] else "recovery_pending"
            store.update(key,stage=stage,last_reconcile_notes=str(exc),event="launch_retry_exhausted" if stage=="blocking" else "launch_retry_pending",detail=str(exc))
    return report

def status(store):
    efforts=store.list_efforts(); counts={"active":0,"waiting":0,"blocked":0,"blocked-recovery":0,"uncertain(recovery_pending)":0}
    for e in efforts:
        stage=e["stage"]
        if stage in ("running","launching"): counts["active"]+=1
        elif stage in ("selected","ready_to_inprogress","awaiting"): counts["waiting"]+=1
        elif stage=="blocked": counts["blocked"]+=1
        elif stage=="blocking": counts["blocked-recovery"]+=1
        elif stage=="recovery_pending": counts["uncertain(recovery_pending)"]+=1
    print(json.dumps({"paused":store.get_control("pause","false")=="true","stopped":store.get_control("stop","false")=="true","summary":counts,"efforts":efforts},indent=2,default=str))

def preflight(config,store_dir):
    errors=[]; warnings=[]
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
        jira=Jira(client,config["jira_project"],config["custom_project_field"]); jira.discover_cloud_id()
        states=("Ready","In Progress","Blocked","Plannable")
        issues=list(jira.search())
        sampled=set()
        for issue in issues:
            state=(issue.get("fields",{}).get("status") or {}).get("name")
            if state in states and state not in sampled:
                transitions=jira.transitions(issue["key"]); sampled.add(state)
                required="In Progress" if state=="Ready" else ("Blocked" if state=="In Progress" else ("Ready" if state=="Blocked" else "Ready"))
                vals=transitions.get("transitions",transitions) if isinstance(transitions,dict) else transitions
                if not any((t.get("to") or {}).get("name")==required for t in vals or []): warnings.append("pending: no required transition from %s to %s"%(state,required))
        for state in states:
            if state not in sampled: warnings.append("pending: no ticket in state %s to sample"%state)
    except Exception as exc: warnings.append("gateway/Jira checks pending: %s"%exc)
    return errors,warnings

def run_once(args,config,store):
    if not config["active"]: raise ConfigError("dispatcher config active is false; refusing ticket processing")
    from mcp_client import MCPClient
    client=MCPClient(config["gateway_url"]); client.initialize(); jira=Jira(client,config["jira_project"],config["custom_project_field"])
    if store.get_control("stop","false")=="true":
        for e in store.list_efforts():
            if e["stage"] in ("launching","running"): store.journal(e["key"],"supervision detached","daemon left alive; no new admission")
        return []
    supervise_once(jira,store,config,polytoken=args.polytoken)
    resume_candidates(jira,store,config,polytoken=args.polytoken)
    if store.get_control("pause","false")=="true": return []
    return process_candidates(jira,store,config,facet=args.facet,polytoken=args.polytoken)

def main(argv=None):
    parser=argparse.ArgumentParser(); parser.add_argument("command",choices=("run","status","pause","resume","stop","preflight","init-config")); parser.add_argument("--once",action="store_true"); parser.add_argument("--state-dir",default=DEFAULT_STATE); parser.add_argument("--config"); parser.add_argument("--facet",default="quick-delivery"); parser.add_argument("--polytoken",default="polytoken")
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
            if args.command=="resume": store.set_control("stop","false")
            return 0
        if args.command=="preflight":
            errors,warnings=preflight(config,args.state_dir)
            for e in errors: print("ERROR: "+e)
            for w in warnings: print("WARNING: "+w)
            print("Preflight: "+("FAIL" if errors else "local and reachable checks passed")); return bool(errors)
        if args.command=="run":
            while True:
                run_once(args,config,store)
                if args.once or store.get_control("stop","false")=="true": break
                time.sleep(config["launch_poll_interval_seconds"])
            return 0
    finally: store.close()
    return 0

if __name__=="__main__": raise SystemExit(main())
