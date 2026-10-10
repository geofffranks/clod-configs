#!/usr/bin/env bash
# Local-only Jira dispatcher regression tests. No real Jira/gateway/session calls.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="$REPO/jira-dispatcher"
python3 -m py_compile "$RUNTIME"/*.py || exit 1
python3 - "$RUNTIME" <<'PY'
import http.server, json, os, socketserver, sys, tempfile, threading, unittest
sys.path.insert(0, sys.argv[1])
from mcp_client import MCPClient
from jira import Jira, UncertainOutcome
from state import StateStore
from config import validate, ConfigError, DEFAULTS
from workers import parse_approved_plan, blocker_comment, delivery_report
from launch import _parse_spawn, reconcile_session, LaunchError
from dispatcher import admission, supervise_once, resume_candidates, preflight, process_candidates
import dispatcher

class FakeHandler(http.server.BaseHTTPRequestHandler):
    page=0
    calls=[]
    def log_message(self,*a): pass
    def do_POST(self):
        req=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))))
        m=req.get('method'); rid=req.get('id')
        if m=='initialize': result={'protocolVersion':'2024-11-05','capabilities':{},'serverInfo':{'name':'fake'}}
        elif m=='tools/list': result={'tools':[]}
        elif m=='tools/call':
            name=req['params']['name']; args=req['params'].get('arguments',{}); type(self).calls.append((name,args))
            if name=='getAccessibleAtlassianResources': result=[{'id':'cloud-test'}]
            elif name=='searchJiraIssuesUsingJql':
                type(self).page+=1
                result={'issues':[{'key':'LAP-%d'%type(self).page}], 'nextPageToken':'p2' if type(self).page==1 else None}
            else: result={'ok':True}
        else: result={}
        data=json.dumps({'jsonrpc':'2.0','id':rid,'result':result}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Mcp-Session-Id','fake-session'); self.end_headers(); self.wfile.write(data)

class FakeSSE(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        req=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))))
        data=json.dumps({'jsonrpc':'2.0','id':req.get('id'),'result':{'tools':[{'name':'sse'}]}})
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers(); self.wfile.write(('event: message\ndata: '+data+'\n\n').encode())

def serve(handler):
    server=socketserver.TCPServer(('127.0.0.1',0),handler); threading.Thread(target=server.serve_forever,daemon=True).start(); return server

class DispatcherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server=serve(FakeHandler); cls.url='http://127.0.0.1:%d/mcp'%cls.server.server_address[1]
    @classmethod
    def tearDownClass(cls): cls.server.shutdown(); cls.server.server_close()
    def setUp(self): self.tmp=tempfile.TemporaryDirectory(); self.store=StateStore(self.tmp.name)
    def tearDown(self): self.store.close(); self.tmp.cleanup()
    def config(self):
        c=dict(DEFAULTS); c['repo_mappings']={'lappie':{'repo_path':self.tmp.name},'appium-mcp':{'repo_path':self.tmp.name+'/appium'}}; c['max_global_active']=1; return c
    def test_mcp_happy_path_session(self):
        client=MCPClient(self.url); client.initialize(); self.assertEqual(client.session_id,'fake-session'); self.assertEqual(client.tools_list(),{'tools':[]})
    def test_sse_envelope(self):
        s=serve(FakeSSE)
        try:
            c=MCPClient('http://127.0.0.1:%d/mcp'%s.server_address[1]); self.assertEqual(c.tools_list(),{'tools':[{'name':'sse'}]})
        finally: s.shutdown(); s.server_close()
    def test_jira_pagination_rank(self):
        FakeHandler.page=0; j=Jira(MCPClient(self.url),'LAP'); issues=list(j.search()); self.assertEqual([i['key'] for i in issues],['LAP-1','LAP-2'])
    def test_plan_queued_label(self):
        plan=parse_approved_plan([{'id':'c1','body':'## Approved delivery plan\nGit: branch\nDelivery mode: queued\nReview panel: panel\nDepends on: LAP-1'}]); self.assertIsNotNone(plan); self.assertEqual(plan['values']['Delivery mode'],'queued')
    def test_plan_interactive_rejected(self):
        self.assertIsNone(parse_approved_plan([{'body':'## Approved delivery plan\nGit: branch\nDelivery mode: interactive\nReview panel: panel'}]))
    def test_admission_unsupported_and_process_friction(self):
        c=self.config(); base={'key':'LAP-1','fields':{'issuetype':{'name':'Story'},'status':{'name':'Ready'},'customfield_10043':'lappie'}}; plan={'values':{'Delivery mode':'queued'}}
        x=json.loads(json.dumps(base)); x['fields']['issuetype']['name']='Epic'; self.assertFalse(admission(x,c,plan)[0])
        x=json.loads(json.dumps(base)); x['fields']['issuetype']['name']='Process Friction'; self.assertFalse(admission(x,c,plan)[0])
    def test_admission_missing_mapping_dependency_ownership_cap(self):
        c=self.config(); issue={'key':'LAP-2','fields':{'issuetype':{'name':'Story'},'status':{'name':'Ready'},'customfield_10043':'unknown'}}; plan={'values':{'Delivery mode':'queued'}}
        self.assertIn('unmapped',admission(issue,c,plan)[1]); issue['fields']['customfield_10043']='lappie'
        self.assertIn('dependency',admission(issue,c,plan,False)[1]); self.assertIn('owned',admission(issue,c,plan,True,True)[1]); self.assertIn('global',admission(issue,c,plan,True,False,1)[1])
    def test_rank_jql(self):
        FakeHandler.page=0; FakeHandler.calls=[]; list(Jira(MCPClient(self.url)).search())
        calls=[a for n,a in FakeHandler.calls if n=='searchJiraIssuesUsingJql']
        self.assertEqual(calls[0]['jql'],'project = "LAP" ORDER BY Rank'); self.assertIn('customfield_10043',calls[0]['fields']); self.assertEqual(calls[1]['nextPageToken'],'p2')
    def test_comment_reconcile_dedupes_existing_marker(self):
        class FakeJira:
            def __init__(self): self.writes=0
            def verify_comment(self,key,markers): return [{'body':'Delivery report marker LAP-9'}]
            def comment(self,key,text): self.writes+=1; raise UncertainOutcome('lost acknowledgment')
        fake=FakeJira(); result=Jira.reconcile_comment(fake,'LAP-9','report',['Delivery report','LAP-9'])
        self.assertIn('LAP-9',result['body']); self.assertEqual(fake.writes,0)
    def test_double_claim_protected(self):
        self.store.claim('LAP-1',self.tmp.name,self.tmp.name)
        with self.assertRaises(RuntimeError): self.store.claim('LAP-1',self.tmp.name,self.tmp.name)
    def test_atomic_per_repo_global_claim(self):
        self.store.claim('LAP-1',self.tmp.name,self.tmp.name)
        with self.assertRaises(RuntimeError): self.store.claim('LAP-2',self.tmp.name,self.tmp.name)
        with self.assertRaises(RuntimeError): self.store.claim('LAP-3',self.tmp.name+'/other',self.tmp.name+'/other')
    def test_launch_intent_then_spawn_parse(self):
        self.store.claim('LAP-1',self.tmp.name,self.tmp.name); self.store.update('LAP-1',stage='launching',launch_intent={'prompt':'x'},event='launch_intent_persisted')
        self.assertEqual(self.store.get('LAP-1')['stage'],'launching'); self.assertEqual(_parse_spawn('session_id=real-123 port=4321'),('real-123',4321))
    def test_existing_live_session_reconcile(self):
        sessions=[{'session_id':'real-id','project_path':self.tmp.name,'termination_state':'running','ticket_key':'LAP-1','port':1234}]
        # No credential/daemon is fabricated: missing credential safely declines adoption.
        self.assertIsNone(reconcile_session('LAP-1',self.tmp.name,sessions,self.tmp.name))
    def test_transition_match_requires_name_and_destination(self):
        ts=[{'id':'1','name':'Start Progress','to':{'name':'Review'}},{'id':'2','name':'Start Progress','to':{'name':'In Progress'}}]
        self.assertEqual(Jira.select_transition(ts,'Start Progress','In Progress')['id'],'2')
        with self.assertRaises(LookupError): Jira.select_transition(ts,'Start Progress','Done')
    def test_counters_survive_reopen(self):
        self.store.claim('LAP-1',self.tmp.name,self.tmp.name); self.store.increment('LAP-1','launch_attempts'); path=self.store.path; self.store.close(); self.store=StateStore(self.tmp.name); self.assertEqual(self.store.get('LAP-1')['launch_attempts'],1)
    def test_control_flags(self):
        self.store.set_control('pause','true'); self.assertEqual(self.store.get_control('pause'),'true'); self.store.set_control('pause','false'); self.assertEqual(self.store.get_control('pause'),'false')
    def test_config_invalid_rejected(self):
        c=dict(DEFAULTS); c['allowed_types']=['Epic']
        with self.assertRaises(ConfigError): validate(c,check_paths=False)
    def test_required_comment_markers(self):
        b=blocker_comment('reason','decision','real-session','/work','branch','abc123','tests passed','one task');
        for word in ('Reason:','Decision needed:','Session:','Worktree:','Branch:','Commits:'): self.assertIn(word,b)
        d=delivery_report('real-session','branch','/work','tests','review','abc123','manual UI test')
        for word in ('Session id:','Branch:','Worktree:','Remaining manual checks:'): self.assertIn(word,d)

    def test_supervision_completion_requires_ticket_comment_and_reports_delivery(self):
        class FakeDaemon:
            def health(self): return {"ok":True}
            def state(self): return {}
            def events(self): return {"events":[]}
        class FakeJira:
            def __init__(self): self.comments_by_key={"LAP-9":[{"id":"done1","created":"2999-01-01T00:00:00Z","body":"Completion report\nBranch: feat/x\nWorktree: /tmp/work\nCommits: abc..def\nChecks: unit tests passed\nReview: approved\nRemaining manual checks: none"}]}; self.status="In Progress"; self.writes=[]
            def comments(self,key): return self.comments_by_key.get(key,[])
            def transitions(self,key): return {"transitions":[{"id":"7","name":"Implementation Complete","to":{"name":"Awaiting Acceptance"}}]}
            def transition_to(self,key,dest,names): self.writes.append(("transition",dest,names)); self.status=dest; return {"id":"7","name":"Implementation Complete"}
            def verify_transition(self,key,dest): return self.status==dest
            def reconcile_comment(self,key,text,markers): self.writes.append(("comment",text)); return {"id":"delivery","body":text,"created":"2999-01-01T00:00:01Z"}
        self.store.claim("LAP-9",self.tmp.name,self.tmp.name); self.store.update("LAP-9",stage="running",session_id="real-id",daemon_port=1,launch_time=1)
        old=dispatcher.DaemonClient; dispatcher.DaemonClient=lambda *a,**k: FakeDaemon()
        old_cred=__import__('launch')._credential; __import__('launch')._credential=lambda *a,**k:"token"
        old_pending=__import__('launch').pending_interrogative; __import__('launch').pending_interrogative=lambda d:None
        try:
            j=FakeJira(); self.assertEqual(supervise_once(j,self.store,self.config()),[("LAP-9","awaiting")]); self.assertEqual(self.store.get("LAP-9")["stage"],"awaiting")
            report=[w[1] for w in j.writes if w[0]=="comment"][0]
            for marker in ("Session id:","Branch: feat/x","Worktree: /tmp/work","Commits: abc..def","Checks: unit tests passed","Remaining manual checks: none"): self.assertIn(marker,report)
        finally: dispatcher.DaemonClient=old; __import__('launch')._credential=old_cred; __import__('launch').pending_interrogative=old_pending

    def test_supervision_question_preservation_failure_holds_lane(self):
        class DeadDaemon:
            def health(self): raise OSError("gone")
        self.store.claim("LAP-10",self.tmp.name,self.tmp.name); self.store.update("LAP-10",stage="running",session_id="gone",daemon_port=1)
        old=dispatcher.live_sessions; dispatcher.live_sessions=lambda *a,**k:[]
        try:
            result=supervise_once(object(),self.store,self.config())
            self.assertEqual(self.store.get("LAP-10")["stage"],"recovery_pending")
            self.assertEqual(result[0][1],"recovery_pending")
        finally: dispatcher.live_sessions=old

    def test_resume_requires_new_reply_and_preserves_attempt_count(self):
        class FakeJira:
            def __init__(self,comments): self.cs=comments
            def get_issue(self,key): return {"fields":{"status":{"name":"Ready"}}}
            def comments(self,key): return self.cs
        self.store.claim("LAP-11",self.tmp.name,self.tmp.name,plan_excerpt="## Approved delivery plan\nGit: branch\nDelivery mode: queued\nReview panel: panel")
        self.store.increment("LAP-11","blocker_attempts"); self.store.update("LAP-11",stage="blocked",blocker_comment_time=100)
        plan={"id":"p","body":"## Approved delivery plan\nGit: branch\nDelivery mode: queued\nReview panel: panel"}
        j=FakeJira([plan]); self.assertEqual(resume_candidates(j,self.store,self.config()),[("LAP-11","skipped")]); self.assertEqual(self.store.get("LAP-11")["blocker_attempts"],1)
        self.assertIn("not speculating",self.store.events("LAP-11")[-1]["detail"])

    def test_controls_config_and_preflight_local_pending(self):
        c=validate({"question_grace_polls":0,"max_blocker_attempts":3},check_paths=False)
        self.assertEqual(c["transition_names"]["inprogress_to_awaiting"],["Implementation Complete"])
        self.store.claim("LAP-12",self.tmp.name,self.tmp.name); self.store.update("LAP-12",stage="blocked")
        self.assertIn("blocked",__import__('state').STAGES)
        oldwhich=dispatcher.shutil.which; dispatcher.shutil.which=lambda x:None
        try:
            errors,warnings=preflight(c,self.tmp.name); self.assertTrue(errors)
        finally: dispatcher.shutil.which=oldwhich

    def test_resume_continue_failure_falls_back_with_preservation_and_attempts(self):
        class FakeJira:
            def get_issue(self,key): return {"fields":{"status":{"name":"Ready"}}}
            def comments(self,key): return [{"id":"p","created":"2020-01-01T00:00:00Z","body":"## Approved delivery plan\nGit: feat/keep\nDelivery mode: queued\nReview panel: review"},{"id":"r","created":"2021-01-01T00:00:00Z","body":"Proceed with the documented remaining tests."}]
        self.store.claim("LAP-20",self.tmp.name,self.tmp.name,plan_excerpt="## Approved delivery plan\nGit: feat/keep\nDelivery mode: queued\nReview panel: review")
        self.store.increment("LAP-20","blocker_attempts"); self.store.update("LAP-20",stage="blocked",session_id="retained",blocker_comment_time=1)
        old_continue=dispatcher.resume_via_continue; old_launch=dispatcher.launch; captured={}
        def fail_continue(*a,**k): raise RuntimeError("continue unavailable")
        def fake_launch(repo,facet,prompt,store,key,**kwargs): captured.update(repo=repo,facet=facet,prompt=prompt); return "fresh",object()
        dispatcher.resume_via_continue=fail_continue; dispatcher.launch=fake_launch
        try:
            self.assertEqual(resume_candidates(FakeJira(),self.store,self.config()),[("LAP-20","resumed")])
            self.assertIn("Proceed with the documented remaining tests",captured["prompt"])
            self.assertIn("Current approved plan excerpt",captured["prompt"]); self.assertIn("Preservation:",captured["prompt"])
            self.assertEqual(self.store.get("LAP-20")["blocker_attempts"],1)
            self.assertIn("after continue failed",self.store.events("LAP-20")[-1]["detail"])
        finally: dispatcher.resume_via_continue=old_continue; dispatcher.launch=old_launch

    def test_preserved_question_blocks_once_and_releases_repo_lane(self):
        import subprocess
        repo=os.path.join(self.tmp.name,"preserved"); os.makedirs(repo)
        subprocess.run(["git","init",repo],capture_output=True,check=True); subprocess.run(["git","-C",repo,"config","user.email","fake@example.invalid"],check=True); subprocess.run(["git","-C",repo,"config","user.name","Fake"],check=True)
        with open(os.path.join(repo,"partial.txt"),"w") as f: f.write("partial\n")
        subprocess.run(["git","-C",repo,"add","partial.txt"],check=True); subprocess.run(["git","-C",repo,"commit","-m","partial"],capture_output=True,check=True)
        self.store.claim("LAP-21",repo,repo,plan_excerpt="## Approved delivery plan\nGit: master\nDelivery mode: queued\nReview panel: review\nEffort branch/workspace: "+repo)
        self.store.update("LAP-21",stage="running",session_id="kept",daemon_port=1234,launch_time=1)
        class Daemon:
            def health(self): return {"ok":True}
            def state(self): return {"pending_interrogative":{"question":"Which API?"}}
            def events(self): return {"events":[]}
        class FakeJira:
            def __init__(self): self.status="In Progress"; self.writes=[]
            def transitions(self,key): return {"transitions":[{"id":"b","name":"Block","to":{"name":"Blocked"}}]}
            def transition_to(self,key,dest,names): self.writes.append(("transition",dest,names)); self.status=dest; return {"name":"Block"}
            def verify_transition(self,key,dest): return self.status==dest
            def reconcile_comment(self,key,text,markers): self.writes.append(("comment",text)); return {"id":"block1","created":"2999-01-01T00:00:00Z","body":text}
            def comments(self,key): return []
        old_client=dispatcher.DaemonClient; old_cred=__import__('launch')._credential; old_pending=__import__('launch').pending_interrogative
        dispatcher.DaemonClient=lambda *a,**k:Daemon(); __import__('launch')._credential=lambda *a,**k:"token"; __import__('launch').pending_interrogative=lambda d:d.state()["pending_interrogative"]
        try:
            jira=FakeJira(); self.assertEqual(supervise_once(jira,self.store,self.config()),[("LAP-21","blocked")])
            comments=[x[1] for x in jira.writes if x[0]=="comment"]; self.assertEqual(len(comments),1)
            for marker in ("Reason:","Decision needed:","Session:","Worktree:","Branch:","Commits:","Checks/review:","Remaining work/limits:"): self.assertIn(marker,comments[0])
            c=self.config(); c["max_global_active"]=2
            self.store.claim("LAP-22",repo+"-other",repo+"-other",global_limit=2)
            self.assertEqual(self.store.get("LAP-21")["blocker_attempts"],1)
        finally: dispatcher.DaemonClient=old_client; __import__('launch')._credential=old_cred; __import__('launch').pending_interrogative=old_pending

    def test_run_once_controls_supervision_and_admission(self):
        args=type("Args",(),{"polytoken":"fake","facet":"quick-delivery"})()
        cfg=self.config(); cfg["active"]=True; calls=[]
        class FakeClient:
            def __init__(self,*a,**k): pass
            def initialize(self): return {}
        old_client=dispatcher.MCPClient if hasattr(dispatcher,"MCPClient") else None
        old_supervise=dispatcher.supervise_once; old_resume=dispatcher.resume_candidates; old_process=dispatcher.process_candidates
        import mcp_client
        original=mcp_client.MCPClient; mcp_client.MCPClient=FakeClient
        dispatcher.supervise_once=lambda *a,**k:calls.append("supervise") or []
        dispatcher.resume_candidates=lambda *a,**k:calls.append("resume") or []
        dispatcher.process_candidates=lambda *a,**k:calls.append("admit") or []
        try:
            self.store.set_control("stop","true"); self.assertEqual(dispatcher.run_once(args,cfg,self.store),[]); self.assertEqual(calls,[])
            self.store.set_control("stop","false"); self.store.set_control("pause","true"); self.assertEqual(dispatcher.run_once(args,cfg,self.store),[]); self.assertEqual(calls,["supervise","resume"])
            self.store.set_control("pause","false"); calls.clear(); self.assertEqual(dispatcher.run_once(args,cfg,self.store),[]); self.assertEqual(calls,["supervise","resume","admit"])
        finally:
            mcp_client.MCPClient=original; dispatcher.supervise_once=old_supervise; dispatcher.resume_candidates=old_resume; dispatcher.process_candidates=old_process

    def test_uncertain_spawn_output_records_recovery(self):
        self.store.claim("LAP-25",self.tmp.name,self.tmp.name)
        self.store.update("LAP-25",stage="launching",launch_intent={"prompt":"x"})
        attempts_before=self.store.get("LAP-25")["launch_attempts"]
        with self.assertRaises(LaunchError): _parse_spawn("garbage")
        attempts=self.store.increment("LAP-25","launch_attempts",event="launch_uncertain",detail="polytoken output omitted session_id/port")
        self.assertEqual(attempts,attempts_before+1)
        self.assertEqual(self.store.get("LAP-25")["launch_attempts"],attempts_before+1)

    def test_blocker_attempt_cap_escalates_without_duplicate_jira_writes(self):
        self.store.claim("LAP-24",self.tmp.name,self.tmp.name)
        self.store.update("LAP-24",stage="running",session_id="real",daemon_port=1)
        for _ in range(3): self.store.increment("LAP-24","blocker_attempts")
        class Daemon:
            def health(self): return {}
            def state(self): return {"pending_interrogative":{"question":"Still unresolved?"}}
            def events(self): return {"events":[]}
        class FakeJira:
            def __init__(self): self.transitions=[]; self.comments=[]
            def transitions(self,key): return {"transitions":[{"id":"b","name":"Block","to":{"name":"Blocked"}}]}
            def transition_to(self,key,dest,names): self.transitions.append(dest); return {"name":"Block"}
            def verify_transition(self,key,dest): return True
            def reconcile_comment(self,key,text,markers): self.comments.append(text); return {"id":"b"}
        old_client=dispatcher.DaemonClient; old_cred=__import__('launch')._credential; old_pending=__import__('launch').pending_interrogative
        dispatcher.DaemonClient=lambda *a,**k:Daemon(); __import__('launch')._credential=lambda *a,**k:"token"; __import__('launch').pending_interrogative=lambda d:d.state()["pending_interrogative"]
        try:
            jira=FakeJira(); self.assertEqual(supervise_once(jira,self.store,self.config()),[("LAP-24","blocked")])
            self.assertEqual(self.store.get("LAP-24")["stage"],"blocked"); self.assertEqual(self.store.get("LAP-24")["blocker_attempts"],4)
            self.assertEqual(jira.transitions,[]); self.assertEqual(jira.comments,[])
        finally: dispatcher.DaemonClient=old_client; __import__('launch')._credential=old_cred; __import__('launch').pending_interrogative=old_pending

    def test_state_restart_keeps_completion_idempotent(self):
        self.store.claim("LAP-23",self.tmp.name,self.tmp.name); self.store.update("LAP-23",stage="running",session_id="real",daemon_port=1,launch_time=1)
        path=self.store.directory; self.store.close(); self.store=StateStore(path)
        class FakeDaemon:
            def health(self): return {}
            def state(self): return {}
            def events(self): return {"events":[]}
        class FakeJira:
            def __init__(self): self.status="In Progress"; self.writes=[]; self.cs=[{"id":"done","created":"2999-01-01T00:00:00Z","body":"Completion\nBranch: b\nWorktree: w\nCommits: c\nChecks: passed\nRemaining manual checks: none"}]
            def comments(self,k): return self.cs
            def transitions(self,k): return {"transitions":[{"id":"a","name":"Implementation Complete","to":{"name":"Awaiting Acceptance"}}]}
            def transition_to(self,k,d,n): self.writes.append(("transition",d)); self.status=d; return {"name":"Implementation Complete"}
            def verify_transition(self,k,d): return self.status==d
            def reconcile_comment(self,k,text,markers): self.writes.append(("comment",text)); self.cs.append({"id":"delivery","created":"2999-01-01T00:00:01Z","body":text}); return self.cs[-1]
        old_client=dispatcher.DaemonClient; old_cred=__import__('launch')._credential; old_pending=__import__('launch').pending_interrogative
        dispatcher.DaemonClient=lambda *a,**k:FakeDaemon(); __import__('launch')._credential=lambda *a,**k:"token"; __import__('launch').pending_interrogative=lambda d:None
        try:
            j=FakeJira(); self.assertEqual(supervise_once(j,self.store,self.config()),[("LAP-23","awaiting")]); self.assertEqual(supervise_once(j,self.store,self.config()),[]); self.assertEqual(self.store.get("LAP-23")["stage"],"awaiting")
            self.assertEqual([x for x in j.writes if x[0]=="transition"],[ ("transition","Awaiting Acceptance") ])
            self.assertEqual(len([x for x in j.writes if x[0]=="comment"]),1)
        finally: dispatcher.DaemonClient=old_client; __import__('launch')._credential=old_cred; __import__('launch').pending_interrogative=old_pending

    def test_preservation_git_fixture_variants(self):
        import subprocess
        repo=os.path.join(self.tmp.name,"repo"); os.makedirs(repo)
        subprocess.run(["git","init",repo],capture_output=True,check=True)
        subprocess.run(["git","-C",repo,"config","user.email","fake@example.invalid"],check=True)
        subprocess.run(["git","-C",repo,"config","user.name","Fake"],check=True)
        with open(os.path.join(repo,".git","HEAD")) as f: branch=f.read().strip().split("/")[-1]
        for i in (1,2):
            with open(os.path.join(repo,"f%d.txt"%i),"w") as f: f.write("work\n")
            subprocess.run(["git","-C",repo,"add","."],check=True)
            subprocess.run(["git","-C",repo,"commit","-m","partial %d"%i],capture_output=True,check=True)
        row={"session_id":None,"daemon_port":None,"_healthy":False,
             "plan_excerpt":"Git: %s\nEffort branch/workspace: %s"%(branch,repo)}
        ok,b,w,commits=dispatcher._preservation(row)
        self.assertTrue(ok); self.assertEqual(b,branch); self.assertEqual(w,repo); self.assertTrue(commits)
        with open(os.path.join(repo,"f3.txt"),"w") as f: f.write("uncommitted\n")
        ok,b,w,commits=dispatcher._preservation(row)
        self.assertFalse(ok); self.assertIn("not verified",commits)

    def test_reconcile_adopt_unique_rejects_zero_or_two(self):
        import launch
        old_client=launch.DaemonClient
        class OKDaemon:
            def __init__(self,port,token,timeout=10): self.port=port
            def health(self): return {"ok":True}
        launch.DaemonClient=OKDaemon
        cred=os.path.join(self.tmp.name,"sess1","credential.json")
        os.makedirs(os.path.dirname(cred))
        with open(cred,"w") as f: f.write('{"token":"tok"}')
        try:
            self.store.claim("LAP-26",self.tmp.name,self.tmp.name)
            live={"session_id":"sess1","project_path":self.tmp.name,"state":"running","last_user_message_preview":"LAP-26","port":1234}
            adopted=reconcile_session("LAP-26",self.tmp.name,[live],self.tmp.name)
            self.assertIsNotNone(adopted); self.assertEqual(adopted[0],"sess1"); self.assertEqual(adopted[1].port,1234)
            self.assertIsNone(reconcile_session("LAP-26",self.tmp.name,[],self.tmp.name))
            ambiguous=[dict(live),dict(live,session_id="sess2")]
            self.assertIsNone(reconcile_session("LAP-26",self.tmp.name,ambiguous,self.tmp.name))
        finally: launch.DaemonClient=old_client

    def test_end_to_end_launch_supervision_delivery(self):
        import subprocess
        daemon_holder={}; gw_holder={}
        class GW(http.server.BaseHTTPRequestHandler):
            issue={"key":"LAP-30","fields":{"issuetype":{"name":"Story"},"status":{"name":"Ready"},"customfield_10043":{"value":"lappie"}}}
            comments=[{"id":"plan","created":"2020-01-01T00:00:00Z","body":"## Approved delivery plan\nGit: main\nDelivery mode: queued\nReview panel: review panel\nDepends on: none"}]
            status="Ready"; comment_id=0; writes=[]
            def log_message(self,*a): pass
            def do_POST(self):
                req=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0')))); m=req.get("method"); rid=req.get("id")
                cls=type(self); result={}
                if m=="initialize": result={"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"fake"}}
                elif m=="tools/call":
                    name=req["params"]["name"]; args=req["params"].get("arguments",{})
                    if name=="getAccessibleAtlassianResources": result=[{"id":"cloud"}]
                    elif name=="searchJiraIssuesUsingJql":
                        jql=args.get("jql","")
                        status="In Progress" if '"In Progress"' in jql else "any"
                        issues=[dict(cls.issue,fields=dict(cls.issue["fields"],status={"name":cls.status}))] if (status=="any" or cls.status=="In Progress") else []
                        result={"issues":issues,"nextPageToken":None}
                    elif name=="getJiraIssue":
                        result={"key":args.get("issueIdOrKey"),"fields":{"status":{"name":cls.status},"comment":{"comments":cls.comments}}}
                    elif name=="getTransitionsForJiraIssue":
                        result={"transitions":[{"id":"t1","name":"Start Progress","to":{"name":"Review"}},{"id":"t2","name":"Go","to":{"name":"In Progress"}},{"id":"t3","name":"Implementation Complete","to":{"name":"Awaiting Acceptance"}},{"id":"t4","name":"Block","to":{"name":"Blocked"}}]}
                    elif name=="transitionJiraIssue":
                        tid=args["transition"]["id"]; dest={"t2":"In Progress","t3":"Awaiting Acceptance"}.get(tid)
                        cls.status=dest; cls.writes.append(("transition",tid,dest))
                    elif name=="addCommentToJiraIssue":
                        cls.comment_id+=1
                        comment={"id":"c%d"%cls.comment_id,"created":"2999-01-01T00:00:%02dZ"%(cls.comment_id+9),"body":args["comment"]["body"]}
                        cls.comments.append(comment); cls.writes.append(("comment",comment["body"]))
                data=json.dumps({"jsonrpc":"2.0","id":rid,"result":result}).encode()
                self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(data))); self.send_header("Mcp-Session-Id","fake-session"); self.end_headers(); self.wfile.write(data)
        class DM(http.server.BaseHTTPRequestHandler):
            prompts=[]
            def log_message(self,*a): pass
            def _reply(self,payload):
                data=json.dumps(payload).encode(); self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(data))); self.end_headers(); self.wfile.write(data)
            def do_GET(self):
                path=self.path.split("?")[0]
                if path=="/health": self._reply({"ok":True})
                elif path=="/state": self._reply({})
                elif path=="/events": self._reply({"events":[]})
                else: self.send_response(404); self.end_headers()
            def do_POST(self):
                self.rfile.read(int(self.headers.get('Content-Length','0')))
                if self.path=="/prompt": type(self).prompts.append("prompted"); self._reply({})
                else: self.send_response(404); self.end_headers()
            do_POST=do_POST
            do_GET=do_GET
        gws=serve(GW); gw_holder["server"]=gws
        try:
            dms=serve(DM)
            try:
                bin_dir=os.path.join(self.tmp.name,"bin"); os.makedirs(bin_dir)
                shim=os.path.join(bin_dir,"polytoken")
                with open(shim,"w") as f:
                    f.write("#!/bin/sh\necho $(printf '%%s' \"$3\") >> %s\nif [ \"$3\" = \"new\" ]; then echo \"session_id=worker port=%d\"; fi\nif [ \"$1\" = \"sessions\" ]; then echo '{\"sessions\":[]}'; fi\n"%(os.path.join(self.tmp.name,"launch.log"),dms.server_address[1]))
                os.chmod(shim,0o755)
                sess_dir=os.path.join(self.tmp.name,"sessions-v1"); os.makedirs(os.path.join(sess_dir,"worker"))
                with open(os.path.join(sess_dir,"worker","credential.json"),"w") as f: f.write('{"token":"tok"}')
                c=dict(DEFAULTS); c["repo_mappings"]={"lappie":{"repo_path":self.tmp.name}}; c["max_global_active"]=1; c["active"]=True; c["gateway_url"]="http://127.0.0.1:%d/mcp"%gws.server_address[1]; c["jira_project"]="LAP"
                from jira import Jira as J
                from mcp_client import MCPClient as C
                jira=J(C(c["gateway_url"]),"LAP",c["custom_project_field"])
                GW.issue["fields"]["comment"]={"comments":GW.comments}
                old_launch=dispatcher.launch
                def iso_launch(repo,facet,prompt,store,key,**kw): return old_launch(repo,facet,prompt,store,key,sessions_dir=sess_dir,**kw)
                dispatcher.launch=iso_launch
                try: report=process_candidates(jira,self.store,c,facet="quick-delivery",polytoken=shim)
                finally: dispatcher.launch=old_launch
                self.assertEqual(report[0]["eligible"],True,report)
                row=self.store.get("LAP-30"); self.assertEqual(row["stage"],"running",json.dumps({"row":{k:row[k] for k in ("stage","session_id","daemon_port","last_reconcile_notes")},"events":self.store.events("LAP-30")})); self.assertEqual(row["session_id"],"worker"); self.assertEqual(row["daemon_port"],dms.server_address[1])
                self.assertEqual([w[1] for w in GW.writes if w[0]=="transition"],["t2"])
                with open(os.path.join(self.tmp.name,"launch.log")) as f: new_count=f.read().count("new")
                self.assertEqual(new_count,1)
                GW.comments.append({"id":"done","created":"2999-01-01T00:00:05Z","body":"Completion report\nBranch: main\nWorktree: %s\nCommits: abc..def\nChecks: unit passed\nReview: approved\nRemaining manual checks: device run"%self.tmp.name})
                out=supervise_once(jira,self.store,c,polytoken=shim,sessions_dir=sess_dir)
                self.assertEqual(out,[("LAP-30","awaiting")]); self.assertEqual(GW.status,"Awaiting Acceptance")
                notes=[w[1] for w in GW.writes if w[0]=="comment"]
                self.assertEqual(len(notes),1,"NOTES:"+repr(notes))
                for marker in ("Delivery report","Session id: worker","Branch: main","Worktree: "+self.tmp.name,"Commits: abc..def","Checks: unit passed","Remaining manual checks: device run"): self.assertIn(marker,notes[0])
                second=process_candidates(jira,self.store,c,facet="quick-delivery",polytoken=shim)
                self.assertEqual(second[0]["eligible"],False); self.assertIn("Ready",second[0]["reason"])
                self.assertEqual(supervise_once(jira,self.store,c,polytoken=shim,sessions_dir=sess_dir),[])
                with open(os.path.join(self.tmp.name,"launch.log")) as f: launch_log=f.read(); new_count=launch_log.count("new")
                self.assertEqual(new_count,1,launch_log)
                self.assertEqual([w for w in GW.writes if w[0]=="transition"],[("transition","t2","In Progress"),("transition","t3","Awaiting Acceptance")])
                self.assertEqual(len([w for w in GW.writes if w[0]=="comment"]),1)
            finally: dms.shutdown(); dms.server_close()
        finally: gws.shutdown(); gws.server_close()

    def test_preflight_gateway_sampling_readonly_pending_warnings(self):
        import subprocess
        repo=os.path.join(self.tmp.name,"repo"); os.makedirs(repo)
        subprocess.run(["git","init",repo],capture_output=True,check=True)
        class PH(http.server.BaseHTTPRequestHandler):
            calls=[]
            def log_message(self,*a): pass
            def do_POST(self):
                req=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0')))); m=req.get("method"); rid=req.get("id"); result={}
                if m=="initialize": result={"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"fake"}}
                elif m=="tools/call":
                    name=req["params"]["name"]; type(self).calls.append(name)
                    if name=="getAccessibleAtlassianResources": result=[{"id":"cloud"}]
                    elif name=="searchJiraIssuesUsingJql":
                        result={"issues":[{"key":"LAP-9","fields":{"status":{"name":"Ready"}}}],"nextPageToken":None}
                    elif name=="getTransitionsForJiraIssue": result={"transitions":[{"id":"1","name":"Go","to":{"name":"In Progress"}}]}
                data=json.dumps({"jsonrpc":"2.0","id":rid,"result":result}).encode()
                self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(data))); self.send_header("Mcp-Session-Id","s"); self.end_headers(); self.wfile.write(data)
        ps=serve(PH)
        try:
            c=dict(DEFAULTS); c["gateway_url"]="http://127.0.0.1:%d/mcp"%ps.server_address[1]; c["jira_project"]="LAP"; c["repo_mappings"]={"lappie":{"repo_path":repo}}
            old_run=dispatcher.subprocess.run; dispatcher.subprocess.run=lambda *a,**k: subprocess.CompletedProcess([],0)
            try: errors,warnings=preflight(c,self.tmp.name)
            finally: dispatcher.subprocess.run=old_run
            self.assertEqual(errors,[],errors)
            self.assertEqual(len(warnings),3,warnings)
            self.assertIn("pending: no ticket in state In Progress to sample"," | ".join(warnings))
            self.assertTrue(PH.calls)
            for name in PH.calls: self.assertIn(name,("getAccessibleAtlassianResources","searchJiraIssuesUsingJql","getTransitionsForJiraIssue"),name)
        finally: ps.shutdown(); ps.server_close()

suite=unittest.defaultTestLoader.loadTestsFromTestCase(DispatcherTests)
result=unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(0 if result.wasSuccessful() else 1)
PY
