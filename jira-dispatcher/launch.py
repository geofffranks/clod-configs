"""Polytoken worker launch, daemon API and session reconciliation."""
import http.client
import json
import os
import re
import subprocess
import urllib.parse

class LaunchError(RuntimeError): pass

class ContinueUncertain(LaunchError):
    """A continuation whose outcome cannot be proven; reconcile before fresh launch."""

class DaemonClient:
    def __init__(self,port,token,timeout=10): self.port=int(port); self.token=token; self.timeout=timeout
    def request(self,method,path,payload=None):
        c=http.client.HTTPConnection("127.0.0.1",self.port,timeout=self.timeout)
        headers={"Authorization":"Bearer "+self.token,"Accept":"application/json"}
        body=None
        if payload is not None: headers["Content-Type"]="application/json"; body=json.dumps(payload)
        try:
            c.request(method,path,body=body,headers=headers); r=c.getresponse(); raw=r.read()
            if r.status<200 or r.status>=300: raise LaunchError("daemon HTTP %d: %s"%(r.status,raw[:300]))
            return json.loads(raw.decode()) if raw else {}
        finally: c.close()
    def health(self): return self.request("GET","/health")
    def state(self): return self.request("GET","/state")
    def prompt(self,text): return self.request("POST","/prompt",{"prompt":text})
    def set_title(self,title):
        result=self.request("POST","/title",{"title":title})
        if not isinstance(result,dict) or result.get("title")!=title or result.get("overridden") is not True:
            raise ValueError("daemon did not confirm the exact title override")
        return result
    def events(self,after=None):
        path="/events"+("?after="+urllib.parse.quote(str(after)) if after is not None else "")
        return self.request("GET",path)
    def respond(self,interrogative_id,answer): return self.request("POST","/interrogative/%s/respond"%urllib.parse.quote(str(interrogative_id)),{"response":answer})
    def terminate(self): return self.request("POST","/terminate",{})

def _parse_spawn(output):
    match=re.search(r"session_id=([^\s]+)\s+port=(\d+)",output)
    if not match: raise LaunchError("polytoken output omitted session_id/port")
    return match.group(1),int(match.group(2))

def _credential(session_id,sessions_dir=None):
    root=sessions_dir or os.path.expanduser("~/.local/share/polytoken/sessions-v1")
    path=os.path.join(root,session_id,"credential.json")
    os.chmod(path,0o600)
    with open(path,encoding="utf-8") as f: data=json.load(f)
    return data.get("token") or data.get("bearer_token") or data.get("credential")

def _set_worker_title(daemon,store,key):
    """Cosmetic only: neither title nor diagnostic failures may trigger recovery."""
    try:
        try:
            daemon.set_title(key)
        except Exception as exc:
            # Fixed categories exclude HTTP bodies, tokens and arbitrary exception text.
            if isinstance(exc,LaunchError): detail="daemon_rejected"
            elif isinstance(exc,TimeoutError): detail="timeout"
            elif isinstance(exc,(OSError,http.client.HTTPException)): detail="transport_error"
            elif isinstance(exc,(ValueError,UnicodeError)): detail="invalid_response"
            else: detail="unexpected_error"
            store.journal(key,"worker_title_failed",detail)
        else:
            store.journal(key,"worker_title_set")
    except Exception:
        # The worker is already durably registered; diagnostics are best-effort too.
        pass

def launch(repo,facet,prompt,store,key,polytoken="polytoken",sessions_dir=None,timeout=3600):
    store.update(key,stage="launching",pending_operation={"stage":"launching","operation":"spawn","payload":{"repo":repo,"facet":facet,"prompt":prompt}},launch_intent={"repo":repo,"facet":facet,"prompt":prompt,"dispatch_started":False},event="launch_intent_persisted")
    if store.get_control("pause","false")=="true" or store.get_control("stop","false")=="true": raise LaunchError("dispatcher paused/stopped before worker spawn")
    # Once the subprocess starts, registry absence cannot prove it never spawned.
    store.update(key,launch_intent={"repo":repo,"facet":facet,"prompt":prompt,"dispatch_started":True},event="spawn_dispatch_started")
    completed=subprocess.run([polytoken,"--working-dir",repo,"new","--no-attach","--facet",facet,"--prompt",prompt],capture_output=True,text=True,timeout=timeout,check=False)
    if completed.returncode: raise LaunchError(completed.stderr or "polytoken new failed")
    sid,port=_parse_spawn(completed.stdout)
    store.update(key,stage="running",session_id=sid,daemon_port=port,launch_time=__import__("time").time(),pending_operation=None,event="worker_identity_captured",detail="port=%d"%port)
    token=_credential(sid,sessions_dir)
    if not token: raise LaunchError("credential file has no bearer token")
    daemon=DaemonClient(port,token)
    daemon.health()
    store.update(key,stage="running",session_id=sid,daemon_port=port,launch_time=__import__("time").time(),pending_operation=None,event="worker_started",detail="port=%d"%port)
    _set_worker_title(daemon,store,key)
    return sid,daemon

def resume_via_continue(session_id,polytoken="polytoken",timeout=3600):
    """Continue a retained session headlessly. Timeout/lost-output is UNCERTAIN, not certain failure."""
    try:
        p=subprocess.run([polytoken,"continue",session_id,"--no-attach"],capture_output=True,text=True,timeout=timeout,check=False)
    except subprocess.TimeoutExpired as exc:
        raise ContinueUncertain("continue timed out; outcome unknown") from exc
    if p.returncode: raise LaunchError(p.stderr or "polytoken continue failed")
    try:
        return _parse_spawn(p.stdout)
    except LaunchError as exc:
        raise ContinueUncertain("continue spawned but printed no session id/port; outcome unknown") from exc

def pending_interrogative(daemon):
    """Cursor-aware reducer: a resolution event clears an earlier pending question."""
    state=daemon.state()
    pending=state.get("pending_interrogative") or state.get("interrogative")
    if pending: return pending
    try: events=daemon.events()
    except Exception: return None
    events=events.get("events",events) if isinstance(events,dict) else events
    last=None
    for event in events or []:
        etype=str(event.get("type","")).lower()
        if etype in ("interrogative_resolved","interrogative_answered","pending_interrogative_resolved","interrogative_cleared"):
            last=None
        elif etype in ("interrogative_pending","pending_interrogative"):
            last=event.get("interrogative") or event
    return last

def is_live_session(session):
    """A registry row counts as live only when not terminal; 'historical' is dead."""
    state=str(session.get("termination_state",session.get("state",session.get("status","")))).lower()
    return state not in ("terminated","dead","stopped","exited","historical","finished","crashed")

def live_sessions(polytoken="polytoken",timeout=15):
    """Parse the polytoken sessions table (`sessions --all`) into normalized rows.

    Two renderings exist: the `--all` table (SESSION_ID STATUS TITLE
    LAST_ACTIVITY PROJECT_PATH) and a live table (SESSION_ID PORT PID
    STARTED_AT PROJECT_PATH). Both tail with an ISO timestamp followed by the
    project path; status is `historical` where the table says so, otherwise
    live/running.
    """
    p=subprocess.run([polytoken,"sessions","--all"],capture_output=True,text=True,timeout=timeout,check=False)
    if p.returncode: raise LaunchError(p.stderr or "polytoken sessions failed")
    stamp=re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
    rows=[]
    for line in (p.stdout or "").splitlines():
        line=line.strip()
        if not line or line.startswith("SESSION_ID"): continue
        stamp_m=stamp.search(line)
        if not stamp_m: continue
        first=line.split(None,2)[0] if not line.startswith("[legacy]") else line.split(None,3)[1]
        sid=first
        if not sid or not re.match(r"^[0-9a-z]{6}-[0-9a-z]{3,6}$",sid): continue
        state_text=line[:stamp_m.start()]
        kind=str(re.search(r"\bhistorical\b",state_text) and "historical" or "running")
        project_path=line[stamp_m.end():].strip() or None
        rows.append({"session_id":sid,"termination_state":kind,"project_path":project_path})
    return rows

def reconcile_session(key,repo,sessions,credential_root=None,launch_intent=None,launch_time=None,identity_confirmed=None):
    """Return one exact correlated live session; never adopts a substring match."""
    matches=[]
    for session in sessions:
        project=session.get("project_path") or session.get("working_dir")
        if os.path.realpath(project or "") != os.path.realpath(repo) or not is_live_session(session):
            continue
        preview=str(session.get("first_user_message_preview", session.get("last_user_message_preview", "")))
        exact=re.search(r"(?<![A-Z0-9-])%s(?![0-9])"%re.escape(key),preview)
        recorded=(session.get("ticket_key")==key)
        if launch_intent:
            facet=launch_intent.get("facet")
            correlated=bool(facet and session.get("facet")==facet and exact)
        else:
            correlated=bool(exact or recorded)
        if correlated: matches.append(session)
    if len(matches)!=1: return None
    s=matches[0]; sid=s.get("session_id") or s.get("id")
    if not sid: return None
    if identity_confirmed: identity_confirmed(sid,s.get("port"))
    try:
        token=_credential(sid,credential_root); port=s.get("port")
        if not token or not port: return None
        daemon=DaemonClient(port,token); daemon.health()
        return sid,daemon
    except (OSError,ValueError,LaunchError): return None
