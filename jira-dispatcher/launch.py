"""Polytoken worker launch, daemon API and session reconciliation."""
import http.client
import json
import os
import re
import subprocess
import urllib.parse

class LaunchError(RuntimeError): pass

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

def launch(repo,facet,prompt,store,key,polytoken="polytoken",sessions_dir=None,timeout=3600):
    store.update(key,stage="launching",launch_intent={"repo":repo,"facet":facet,"prompt":prompt},event="launch_intent_persisted")
    completed=subprocess.run([polytoken,"--working-dir",repo,"new","--no-attach","--facet",facet,"--prompt",prompt],capture_output=True,text=True,timeout=timeout,check=False)
    if completed.returncode: raise LaunchError(completed.stderr or "polytoken new failed")
    sid,port=_parse_spawn(completed.stdout)
    token=_credential(sid,sessions_dir)
    if not token: raise LaunchError("credential file has no bearer token")
    daemon=DaemonClient(port,token)
    daemon.health()
    store.update(key,stage="running",session_id=sid,daemon_port=port,launch_time=__import__("time").time(),event="worker_started",detail="port=%d"%port)
    return sid,daemon

def resume_via_continue(session_id,polytoken="polytoken",timeout=3600):
    p=subprocess.run([polytoken,"continue",session_id,"--no-attach"],capture_output=True,text=True,timeout=timeout,check=False)
    if p.returncode: raise LaunchError(p.stderr or "polytoken continue failed")
    return _parse_spawn(p.stdout)

def pending_interrogative(daemon):
    state=daemon.state()
    pending=state.get("pending_interrogative") or state.get("interrogative")
    if pending: return pending
    events=daemon.events()
    events=events.get("events",events) if isinstance(events,dict) else events
    for event in reversed(events or []):
        if event.get("type") in ("interrogative_pending","pending_interrogative"): return event.get("interrogative") or event
    return None

def live_sessions(polytoken="polytoken",timeout=15):
    p=subprocess.run([polytoken,"sessions","--all"],capture_output=True,text=True,timeout=timeout,check=False)
    if p.returncode: raise LaunchError(p.stderr or "polytoken sessions failed")
    try: data=json.loads(p.stdout)
    except ValueError: raise LaunchError("sessions output is not JSON")
    return data.get("sessions",data) if isinstance(data,dict) else data

def reconcile_session(key,repo,sessions,credential_root=None):
    """Return an exact matching live session; never adopts an ambiguous/unknown row."""
    matches=[]
    for session in sessions:
        project=session.get("project_path") or session.get("working_dir")
        state=str(session.get("termination_state",session.get("state",""))).lower()
        if os.path.realpath(project or "") == os.path.realpath(repo) and state not in ("terminated","dead","stopped","exited"):
            preview=str(session.get("last_user_message_preview", ""))
            if key in preview or session.get("ticket_key")==key: matches.append(session)
    if len(matches)!=1: return None
    s=matches[0]; sid=s.get("session_id") or s.get("id")
    if not sid: return None
    try:
        token=_credential(sid,credential_root); port=s.get("port")
        if not token or not port: return None
        daemon=DaemonClient(port,token); daemon.health()
        return sid,daemon
    except (OSError,ValueError,LaunchError): return None
