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
            elif name=="searchJiraIssuesUsingJql":
                type(self).page+=1
                result={'issues':[{'key':'LAP-%d'%type(self).page,'fields':{'status':{'name':'Ready'},'issuetype':{'name':'Story'}}}], 'nextPageToken':'p2' if type(self).page==1 else None}
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
            def __init__(self): self.comments_by_key={"LAP-9":[{"id":"done1","created":"2999-01-01T00:00:00Z","body":"## Delivery completion report\nWorker completion report\nBranch: feat/x\nWorktree: /tmp/work\nCommits: abc..def\nChecks: unit tests passed\nReview: approved\nRemaining manual checks: none"}]}; self.status="In Progress"; self.writes=[]
            def get_issue(self,key): return {"fields":{"status":{"name":self.status},"comment":{"comments":self.comments_by_key.get("LAP-9",[])}}}
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
            def get_issue(self,key): return {"fields":{"status":{"name":"Ready"},"issuetype":{"name":"Story"},"customfield_10043":"lappie"}}
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
        import mcp_client
        old_mcp=mcp_client.MCPClient
        class IsolatedMCP:
            def __init__(self,*a,**k): pass
            def initialize(self): raise RuntimeError("isolated fake gateway unavailable")
        mcp_client.MCPClient=IsolatedMCP
        try:
            errors,warnings,verified=preflight(c,self.tmp.name); self.assertTrue(errors)
        finally: dispatcher.shutil.which=oldwhich; mcp_client.MCPClient=old_mcp

    def test_resume_continue_failure_falls_back_with_preservation_and_attempts(self):
        class FakeJira:
            def __init__(self): self.status="Ready"
            def get_issue(self,key): return {"fields":{"status":{"name":self.status},"issuetype":{"name":"Story"},"customfield_10043":"lappie"}}
            def comments(self,key): return [{"id":"p","created":"2020-01-01T00:00:00Z","body":"## Approved delivery plan\nGit: feat/keep\nDelivery mode: queued\nReview panel: review"},{"id":"r","created":"2021-01-01T00:00:00Z","body":"Proceed with the documented remaining tests."}]
            def search(self,jql=""): return []
            def transitions(self,key): return {"transitions":[{"id":"g","name":"Go","to":{"name":"In Progress"}}]}
            def transition_to(self,key,dest,names): self.status=dest; return {"name":"Go"}
            def verify_transition(self,key,dest): return self.status==dest
        self.store.claim("LAP-20",self.tmp.name,self.tmp.name,plan_excerpt="## Approved delivery plan\nGit: feat/keep\nDelivery mode: queued\nReview panel: review")
        self.store.increment("LAP-20","blocker_attempts"); self.store.update("LAP-20",stage="blocked",session_id="retained",blocker_comment_time=1)
        old_continue=dispatcher.resume_via_continue; old_launch=dispatcher.launch; old_live=dispatcher.live_sessions
        dispatcher.live_sessions=lambda *a,**k:[]
        captured={}
        def fail_continue(*a,**k): raise RuntimeError("continue unavailable")
        def fake_launch(repo,facet,prompt,store,key,**kwargs): captured.update(repo=repo,facet=facet,prompt=prompt); return "fresh",object()
        dispatcher.resume_via_continue=fail_continue; dispatcher.launch=fake_launch
        try:
            self.assertEqual(resume_candidates(FakeJira(),self.store,self.config()),[("LAP-20","resumed")])
            self.assertIn("Proceed with the documented remaining tests",captured["prompt"])
            self.assertIn("Current approved plan excerpt",captured["prompt"]); self.assertIn("Preservation:",captured["prompt"])
            self.assertEqual(self.store.get("LAP-20")["blocker_attempts"],1)
            self.assertIn("after continue failure",self.store.events("LAP-20")[-1]["detail"])
        finally: dispatcher.resume_via_continue=old_continue; dispatcher.launch=old_launch; dispatcher.live_sessions=old_live

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
            def get_issue(self,key): return {"fields":{"status":{"name":self.status}}}
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

    def test_blocker_attempt_cap_escalates_with_visible_jira_escalation(self):
        self.store.claim("LAP-24",self.tmp.name,self.tmp.name)
        self.store.update("LAP-24",stage="running",session_id="real",daemon_port=1)
        for _ in range(3): self.store.increment("LAP-24","blocker_attempts")
        class Daemon:
            def health(self): return {}
            def state(self): return {"pending_interrogative":{"question":"Still unresolved?"}}
            def events(self): return {"events":[]}
        class FakeJira:
            def __init__(self): self.status="In Progress"; self.transition_writes=[]; self.comments=[]
            def get_issue(self,key): return {"fields":{"status":{"name":self.status}}}
            def transitions(self,key): return {"transitions":[{"id":"b","name":"Block","to":{"name":"Blocked"}}]}
            def transition_to(self,key,dest,names): self.status=dest; self.transition_writes.append(dest); return {"name":"Block"}
            def verify_transition(self,key,dest): return self.status==dest
            def reconcile_comment(self,key,text,markers): self.comments.append(text); return {"id":"esc","created":"2999-01-01T00:00:00Z","body":text}
        old_client=dispatcher.DaemonClient; old_cred=__import__('launch')._credential; old_pending=__import__('launch').pending_interrogative
        dispatcher.DaemonClient=lambda *a,**k:Daemon(); __import__('launch')._credential=lambda *a,**k:"token"; __import__('launch').pending_interrogative=lambda d:d.state()["pending_interrogative"]
        try:
            jira=FakeJira(); self.assertEqual(supervise_once(jira,self.store,self.config()),[("LAP-24","blocked")])
            self.assertEqual(self.store.get("LAP-24")["stage"],"blocked"); self.assertEqual(self.store.get("LAP-24")["blocker_attempts"],4)
            # The cap must be visible on Jira: Blocked transition + escalation comment, sent once.
            self.assertEqual(jira.transition_writes,["Blocked"])
            self.assertEqual(len(jira.comments),1)
            self.assertIn("Dispatcher recovery escalation",jira.comments[0])
            later=supervise_once(jira,self.store,self.config())
            self.assertEqual(later,[])  # terminal blocked rows are not resupervised; still no duplicate writes
            self.assertEqual(jira.transition_writes,["Blocked"]); self.assertEqual(len(jira.comments),1)
        finally: dispatcher.DaemonClient=old_client; __import__('launch')._credential=old_cred; __import__('launch').pending_interrogative=old_pending

    def test_state_restart_keeps_completion_idempotent(self):
        self.store.claim("LAP-23",self.tmp.name,self.tmp.name); self.store.update("LAP-23",stage="running",session_id="real",daemon_port=1,launch_time=1)
        path=self.store.directory; self.store.close(); self.store=StateStore(path)
        class FakeDaemon:
            def health(self): return {}
            def state(self): return {}
            def events(self): return {"events":[]}
        class FakeJira:
            def __init__(self): self.status="In Progress"; self.writes=[]; self.cs=[{"id":"done","created":"2999-01-01T00:00:00Z","body":"## Delivery completion report\nWorker completion report\nBranch: b\nWorktree: w\nCommits: c\nChecks: passed\nReview: approved\nRemaining manual checks: none"}]
            def get_issue(self,key): return {"fields":{"status":{"name":self.status},"comment":{"comments":self.cs}}}
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
                GW.comments.append({"id":"done","created":"2999-01-01T00:00:05Z","body":"## Delivery completion report\nWorker completion report\nBranch: main\nWorktree: %s\nCommits: abc..def\nChecks: unit passed\nReview: approved\nRemaining manual checks: device run"%self.tmp.name})
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
            try: errors,warnings,verified=preflight(c,self.tmp.name)
            finally: dispatcher.subprocess.run=old_run
            self.assertEqual(errors,[],errors)
            self.assertEqual(len(warnings),12,warnings)
            self.assertIn("pending: no Story ticket in state In Progress to sample"," | ".join(warnings))
            self.assertTrue(PH.calls)
            for name in PH.calls: self.assertIn(name,("getAccessibleAtlassianResources","searchJiraIssuesUsingJql","getTransitionsForJiraIssue","getJiraProjectIssueTypesMetadata"),name)
        finally: ps.shutdown(); ps.server_close()

    def test_adf_recursive_text_and_newest_plan_mode(self):
        from workers import adf_text
        adf={"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"## Approved delivery plan"}]},{"type":"paragraph","content":[{"type":"text","text":"Git: main"},{"type":"text","text":"\nDelivery mode: queued\nReview panel: review"}]}]}
        self.assertIn("\nGit: main",adf_text(adf))
        comments=[{"body":"## Approved delivery plan\nGit: old\nDelivery mode: queued\nReview panel: review"},{"body":"## Approved delivery plan\nGit: new\nDelivery mode: interactive\nReview panel: review"}]
        self.assertIsNone(parse_approved_plan(comments))

    def test_completion_requires_positive_structured_worker_report(self):
        from workers import parse_completion_report
        base="## Delivery completion report\nWorker completion report\nBranch: b\nWorktree: w\nCommits: c\nChecks: tests passed\nReview: panel approved\nRemaining manual checks: none"
        def c(body): return {"id":"x","created":"2999-01-01T00:00:00Z","body":body}
        self.assertIsNone(parse_completion_report([c("Operator asks what is required for completion?"+base)],1))
        self.assertIsNone(parse_completion_report([c(base+"\ncompletion is not ready")],1))
        parsed=parse_completion_report([c(base)],1)
        self.assertEqual(parsed[1]["Checks"],"tests passed"); self.assertEqual(parsed[1]["Review"],"panel approved")

    def test_exact_session_key_rejects_prefix_collision(self):
        import launch
        old=launch.DaemonClient
        launch.DaemonClient=type("D",(),{"__init__":lambda self,*a:None,"health":lambda self:{}})
        path=os.path.join(self.tmp.name,"sid","credential.json"); os.makedirs(os.path.dirname(path)); open(path,"w").write('{"token":"t"}')
        try:
            session={"session_id":"sid","project_path":self.tmp.name,"state":"running","last_user_message_preview":"Work on LAP-260","port":1}
            self.assertIsNone(launch.reconcile_session("LAP-26",self.tmp.name,[session],self.tmp.name))
        finally: launch.DaemonClient=old

    def test_awaiting_human_done_retires_without_transition(self):
        self.store.claim("LAP-40",self.tmp.name,self.tmp.name); self.store.update("LAP-40",stage="awaiting")
        class J:
            def get_issue(self,key): return {"fields":{"status":{"name":"Done"}}}
            def transition_to(self,*a): raise AssertionError("must observe only")
        self.assertEqual(supervise_once(J(),self.store,self.config()),[("LAP-40","done")])
        self.assertEqual(self.store.get("LAP-40")["stage"],"done")

    def test_pending_operation_survives_store_reopen(self):
        self.store.claim("LAP-41",self.tmp.name,self.tmp.name)
        self.store.update("LAP-41",pending_operation={"stage":"launching","operation":"spawn","payload":{"facet":"quick-delivery"}})
        path=self.store.directory; self.store.close(); self.store=StateStore(path)
        self.assertIn('"operation": "spawn"',self.store.get("LAP-41")["pending_operation"])

    def test_transition_admission_rechecked_before_jira_write(self):
        class J:
            writes=0
            def transitions(self,key): self.writes+=1; return {"transitions":[]}
        self.store.set_control("stop","true")
        j=J()
        with self.assertRaisesRegex(RuntimeError,"paused/stopped"):
            dispatcher._transition(j,self.store,{"key":"LAP-50"},self.config(),"Blocked","block")
        self.assertEqual(j.writes,0)

    def test_reopen_ready_transition_pending_reconciles_then_spawns_once(self):
        self.store.claim("LAP-52",self.tmp.name,self.tmp.name)
        self.store.update("LAP-52",stage="ready_to_inprogress",pending_operation={"stage":"ready_to_inprogress","operation":"ready_transition","payload":{"destination":"In Progress"}})
        path=self.store.directory; self.store.close(); self.store=StateStore(path)
        class J:
            status="In Progress"; transitions_written=0
            def get_issue(self,key): return {"fields":{"status":{"name":self.status}}}
            def comments(self,key): return [{"id":"p","created":"2020-01-01T00:00:00Z","body":"## Approved delivery plan\nGit: b\nDelivery mode: queued\nReview panel: r"}]
            def verify_transition(self,key,dest): return self.status==dest
        old_live=dispatcher.live_sessions; old_launch=dispatcher.launch
        dispatcher.live_sessions=lambda *a,**k:[]
        spawned=[]
        def fake_launch(*a,**k):
            spawned.append(a[4]); self.store.update(a[4],stage="running",session_id="sid",daemon_port=1234,pending_operation=None)
        dispatcher.launch=fake_launch
        try:
            self.assertEqual(supervise_once(J(),self.store,self.config()),[("LAP-52","running")])
            self.assertEqual(spawned,["LAP-52"])
            self.assertEqual(self.store.get("LAP-52")["stage"],"running")
        finally: dispatcher.live_sessions=old_live; dispatcher.launch=old_launch

    def test_recovery_exhaustion_posts_visible_escalation_after_reopen(self):
        self.store.claim("LAP-53",self.tmp.name,self.tmp.name)
        self.store.update("LAP-53",stage="ready_to_inprogress",pending_operation={"stage":"ready_to_inprogress","operation":"ready_transition","payload":{}})
        path=self.store.directory; self.store.close(); self.store=StateStore(path)
        self.store.increment("LAP-53","launch_attempts"); self.store.increment("LAP-53","launch_attempts")
        class J:
            status="Ready"; writes=[]
            def get_issue(self,key): return {"fields":{"status":{"name":self.status}}}
            def verify_transition(self,key,dest): return self.status==dest
            def transitions(self,key): return {"transitions":[{"id":"b","name":"Block","to":{"name":"Blocked"}}]}
            def transition_to(self,key,dest,names): self.status=dest; self.writes.append(("transition",dest)); return {"name":"Block"}
            def reconcile_comment(self,key,text,markers): self.writes.append(("comment",text)); return {"id":"esc","body":text,"created":"2999-01-01T00:00:00Z"}
            def comments(self,key): return [{"id":"p","created":"2020-01-01T00:00:00Z","body":"## Approved delivery plan\nGit: b\nDelivery mode: queued\nReview panel: r"}]
        j=J(); old=dispatcher._transition
        def transition(jira,store,row,config,dest,hint):
            if dest=="In Progress" and (jira.status=="Ready"):
                raise RuntimeError("temporary transition failure")
            jira.status=dest; jira.writes.append(("transition",dest))
        dispatcher._transition=transition
        try:
            out=supervise_once(j,self.store,self.config())
            self.assertEqual(out,[("LAP-53","blocked")]); self.assertEqual(self.store.get("LAP-53")["stage"],"blocked")
            # From a Ready source the escalation is comment-only: no unauthorized transition.
            self.assertEqual([w[0] for w in j.writes],["comment"],j.writes)
            self.assertIn("Decision needed:",j.writes[-1][1])
        finally: dispatcher._transition=old

    def test_launch_rechecks_control_after_intent_before_spawn(self):
        from launch import launch, LaunchError
        self.store.claim("LAP-54",self.tmp.name,self.tmp.name); self.store.set_control("pause","true")
        old=dispatcher.subprocess.run; called=[]; dispatcher.subprocess.run=lambda *a,**k:called.append(a)
        try:
            with self.assertRaisesRegex(LaunchError,"paused/stopped"): launch(self.tmp.name,"quick-delivery","prompt",self.store,"LAP-54")
            self.assertEqual(called,[]); self.assertEqual(self.store.get("LAP-54")["pending_operation"] is not None,True)
        finally: dispatcher.subprocess.run=old

    def test_blocker_episode_persisted_before_comment_and_marked(self):
        self.store.claim("LAP-51",self.tmp.name,self.tmp.name)
        self.store.update("LAP-51",stage="running")
        episode_seen=[]
        class J:
            def get_issue(self,key): return {"fields":{"status":{"name":"Blocked"}}}
            def reconcile_comment(self,key,text,markers):
                row=self.store.get(key)
                episode_seen.append(row["blocker_episode_id"])
                episode_seen.append(row["blocker_episode_id"] in markers)
                return {"id":"episode-comment","created":"2999-01-01T00:00:00Z"}
        jira=J()
        jira.store=self.store
        row=self.store.get("LAP-51")
        old=dispatcher._preservation
        dispatcher._preservation=lambda _row:(True,"branch",self.tmp.name,"abc123")
        try:
            self.assertTrue(dispatcher._block(jira,self.store,row,self.config(),"reason","decision"))
        finally: dispatcher._preservation=old
        self.assertEqual(len(episode_seen),2)
        self.assertEqual(episode_seen[0],self.store.get("LAP-51")["blocker_episode_id"])
        self.assertTrue(episode_seen[1])

    def test_reopen_after_block_write_occurs_exactly_once(self):
        self.store.claim("LAP-60",self.tmp.name,self.tmp.name)
        self.store.update("LAP-60",stage="blocking",pending_operation={"stage":"blocking","operation":"block_transition","payload":{"episode":"ep1","reason":"Worker blocker report question","decision":"operator decision needed","worktree":self.tmp.name,"branch":"b","commits":"abc","checks":"passed","remaining":"rest"}},blocker_episode_id="ep1")
        path=self.store.directory; self.store.close(); self.store=StateStore(path)
        class J:
            status="In Progress"; comments_written=[]
            def get_issue(self,key): return {"fields":{"status":{"name":self.status}}}
            def transitions(self,key): return {"transitions":[{"id":"b","name":"Block","to":{"name":"Blocked"}}]}
            def transition_to(self,key,dest,names): self.status=dest; return {"name":"Block"}
            def verify_transition(self,key,dest): return self.status==dest
            def reconcile_comment(self,key,text,markers):
                if any(t["body"]==text for t in J.comments_written): return next(t for t in J.comments_written if t["body"]==text)
                c={"id":"c%d"%(len(J.comments_written)+1),"created":"2999-01-01T00:00:%02dZ"%(len(J.comments_written)+1),"body":text}
                J.comments_written.append(c); return c
        j=J()
        out=supervise_once(j,self.store,self.config())
        self.assertEqual(out,[("LAP-60","blocked")]); self.assertEqual(len(j.comments_written),1)
        path=self.store.directory; self.store.close(); self.store=StateStore(path)
        out=supervise_once(j,self.store,self.config())
        self.assertEqual(out,[]); self.assertEqual(len(j.comments_written),1)

    def test_reopen_after_acceptance_write_occurs_exactly_once(self):
        self.store.claim("LAP-61",self.tmp.name,self.tmp.name)
        self.store.update("LAP-61",stage="recovery_pending",pending_operation={"stage":"recovery_pending","operation":"acceptance_report","payload":{"comment_id":"done9","destination":"Awaiting Acceptance","report":"Delivery report\nDispatcher-observed facts:\nChecks: tests passed\nReview: panel approved\nBranch: b\nWorktree: %s\nCommits: abc\nRemaining manual checks: none"%self.tmp.name,"facts":{}}})
        path=self.store.directory; self.store.close(); self.store=StateStore(path)
        class J:
            status="In Progress"; comments_written=[]
            def get_issue(self,key): return {"fields":{"status":{"name":self.status}}}
            def transitions(self,key): return {"transitions":[{"id":"i","name":"Implementation Complete","to":{"name":"Awaiting Acceptance"}}]}
            def transition_to(self,key,dest,names): self.status=dest; return {"name":"Implementation Complete"}
            def verify_transition(self,key,dest): return self.status==dest
            def reconcile_comment(self,key,text,markers):
                if any(t["body"]==text for t in J.comments_written): return next(t for t in J.comments_written if t["body"]==text)
                c={"id":"c%d"%(len(J.comments_written)+1),"created":"2999-01-01T00:00:%02dZ"%(len(J.comments_written)+1),"body":text}
                J.comments_written.append(c); return c
        j=J()
        self.assertEqual(supervise_once(j,self.store,self.config()),[("LAP-61","awaiting")])
        self.assertEqual(len(j.comments_written),1)
        path=self.store.directory; self.store.close(); self.store=StateStore(path)
        self.assertEqual(supervise_once(j,self.store,self.config()),[])
        self.assertEqual(len(j.comments_written),1)

    def test_reopen_after_retirement_is_complete(self):
        self.store.claim("LAP-62",self.tmp.name,self.tmp.name)
        self.store.update("LAP-62",stage="awaiting")
        class J:
            def get_issue(self,key): return {"fields":{"status":{"name":"Done"}}}
        self.assertEqual(supervise_once(J(),self.store,self.config()),[("LAP-62","done")])
        path=self.store.directory; self.store.close(); self.store=StateStore(path)
        self.assertEqual(supervise_once(J(),self.store,self.config()),[])
        self.assertEqual(self.store.get("LAP-62")["stage"],"done")

    def test_stop_injected_before_block_transition(self):
        class J:
            status="In Progress"; comments=[]
            def get_issue(self,key): return {"fields":{"status":{"name":self.status}}}
            def transitions(self,key): return {"transitions":[{"id":"b","name":"Block","to":{"name":"Blocked"}}]}
            def transition_to(self,key,dest,names): self.status=dest; return {"name":"Block"}
            def verify_transition(self,key,dest): return self.status==dest
            def reconcile_comment(self,key,text,markers):
                c={"id":"c%d"%len(J.comments),"created":"2999-01-01T00:00:00Z","body":text}; J.comments.append(c); return c
        self.store.claim("LAP-63",self.tmp.name,self.tmp.name)
        # (a) stop before the block comment: pending op recorded, no Jira comment
        self.store.update("LAP-63",stage="running",session_id="kept",daemon_port=1,launch_time=1)
        self.store.set_control("stop","true")
        class D:
            def health(self): return {}
            def state(self): return {"pending_interrogative":{"question":"q"}}
            def events(self): return {"events":[]}
        old_client=dispatcher.DaemonClient; old_cred=__import__('launch')._credential; old_pending=__import__('launch').pending_interrogative
        dispatcher.DaemonClient=lambda *a,**k:D(); __import__('launch')._credential=lambda *a,**k:"t"; __import__('launch').pending_interrogative=lambda d:d.state()["pending_interrogative"]
        try:
            j=J()
            results=supervise_once(j,self.store,self.config())
            self.assertEqual(j.comments,[])
            self.assertNotIn("stage blocked",json.dumps(self.store.get("LAP-63")))
            self.store.set_control("stop","false")  # resume via operator semantics
            self.store.set_control("pause","false")
            self.assertEqual(supervise_once(j,self.store,self.config()),[("LAP-63","blocked")])
            self.assertEqual(self.store.get("LAP-63")["blocker_attempts"],1)
        finally:
            dispatcher.DaemonClient=old_client; __import__('launch')._credential=old_cred; __import__('launch').pending_interrogative=old_pending

    def test_two_blocker_episodes_each_require_their_own_reply(self):
        class J:
            status="In Progress"; ticket_comments=[]
            def get_issue(self,key): return {"fields":{"status":{"name":self.status},"issuetype":{"name":"Story"},"customfield_10043":"lappie"}}
            def transitions(self,key): return {"transitions":[{"id":"b","name":"Block","to":{"name":"Blocked"}}]}
            def transition_to(self,key,dest,names): type(self).status=dest; return {"name":"Block"}
            def verify_transition(self,key,dest): return self.status==dest
            def comments(self,key): return J.ticket_comments
            def search(self,jql=""): return []
        real_preservation=dispatcher._preservation
        old_resume_continue=dispatcher.resume_via_continue; old_launch=dispatcher.launch; old_live=dispatcher.live_sessions
        dispatcher._preservation=lambda row: (True,"b",self.tmp.name,"committed abc")
        def fresh_launch(*a,**k):
            self.store.update(a[4],stage="running",session_id="fresh",daemon_port=7,launch_time=100.0,pending_operation=None)
        def fail_continue(*a,**k): raise RuntimeError("continue unavailable")
        dispatcher.launch=fresh_launch; dispatcher.resume_via_continue=fail_continue
        dispatcher.live_sessions=lambda *a,**k:[{"session_id":"fresh","project_path":self.tmp.name,"termination_state":"running","port":7}]
        class D:
            def health(self): return {}
            def state(self): return {}
            def events(self): return {"events":[]}
        old_client=dispatcher.DaemonClient; old_cred=__import__('launch')._credential; old_pending=__import__('launch').pending_interrogative
        dispatcher.DaemonClient=lambda *a,**k:D(); __import__('launch')._credential=lambda *a,**k:"t"; __import__('launch').pending_interrogative=lambda d:None
        try:
            j=J()
            # Episode 1: worker reports a blocker -> supervisor blocks.
            self.store.claim("LAP-64",self.tmp.name,self.tmp.name,plan_excerpt="## Approved delivery plan\nGit: b\nDelivery mode: queued\nReview panel: r")
            self.store.update("LAP-64",stage="running",launch_time=1.0,session_id="fresh",daemon_port=7,pending_operation=None)
            J.ticket_comments.append({"id":"p","created":"2020-01-01T00:00:00Z","body":"## Approved delivery plan\nGit: b\nDelivery mode: queued\nReview panel: r"})
            J.ticket_comments.append({"id":"b1","created":"2999-01-01T00:00:05Z","body":"Worker blocker report\nReason: choose retry budget\nDecision needed: option"})
            def reconcile_comment(key,text,markers):
                if any(t["body"]==text for t in J.ticket_comments): return next(t for t in J.ticket_comments if t["body"]==text)
                c={"id":"c%d"%(len(J.ticket_comments)+1),"created":"2999-01-01T00:%02d:00Z"%(len(J.ticket_comments)+1),"body":text}
                J.ticket_comments.append(c); return c
            j.reconcile_comment=reconcile_comment
            self.assertEqual(supervise_once(j,self.store,self.config()),[("LAP-64","blocked")])
            row=self.store.get("LAP-64"); self.assertEqual(row["blocker_attempts"],1); ep1=row["blocker_episode_id"]; self.assertTrue(ep1)
            # Operator replies and moves to Ready: the reply authorizes a resume (fresh launch stub).
            J.ticket_comments.append({"id":"r1","created":"2999-01-01T00:05:00Z","body":"Answered: option A."})
            J.status="Ready"
            out=resume_candidates(j,self.store,dict(self.config(),max_global_active=2))
            self.assertEqual(out,[("LAP-64","resumed")])
            row=self.store.get("LAP-64"); self.assertEqual(row["stage"],"running"); self.assertEqual(row["blocker_attempts"],1)
            J.status="In Progress"
            # Episode 2: a NEW worker blocker after resume -> new episode; the old reply is already consumed.
            J.ticket_comments.append({"id":"b2","created":"2999-01-01T00:06:00Z","body":"Worker blocker report\nReason: second distinct blocker\nDecision needed: new decision"})
            self.assertEqual(supervise_once(j,self.store,self.config()),[("LAP-64","blocked")])
            row=self.store.get("LAP-64"); self.assertEqual(row["blocker_attempts"],2)
            self.assertNotEqual(row["blocker_episode_id"],ep1)
            # The episode-2 blocker time is later than the consumed reply time: r1 must not re-authorize.
            self.assertTrue(row["blocker_comment_time"] > dispatcher._when(next(c for c in J.ticket_comments if c["id"]=="r1")))
        finally:
            dispatcher._preservation=real_preservation; dispatcher.resume_via_continue=old_resume_continue; dispatcher.launch=old_launch; dispatcher.live_sessions=old_live
            dispatcher.DaemonClient=old_client; __import__('launch')._credential=old_cred; __import__('launch').pending_interrogative=old_pending

    def test_resume_claim_enforces_global_and_repo_limits(self):
        self.store.claim("LAP-65",self.tmp.name,self.tmp.name,global_limit=2)
        self.store.update("LAP-65",stage="running")  # occupies one of two slots
        self.store.claim("LAP-66",self.tmp.name+"X",self.tmp.name+"X",global_limit=2)
        self.store.update("LAP-66",stage="blocked")
        with self.assertRaisesRegex(RuntimeError,"global active limit reached"):
            self.store.resume_claim("LAP-66",{"reply_id":"r1"})
        self.store.update("LAP-65",stage="done")  # release
        # same-repo conflict: a running effort on the same repo blocks resumption
        self.store.claim("LAP-68",self.tmp.name,self.tmp.name,global_limit=2)
        self.store.update("LAP-68",stage="blocked")
        self.store.claim("LAP-67",self.tmp.name,self.tmp.name,global_limit=2)
        self.store.update("LAP-67",stage="running")
        with self.assertRaisesRegex(RuntimeError,"already owned"):
            self.store.resume_claim("LAP-68",{"reply_id":"r2"},repo=self.tmp.name,global_limit=2)
        # valid: only blocked row itself, no active others
        self.store.update("LAP-67",stage="done")
        self.store.resume_claim("LAP-68",{"reply_id":"r3"},global_limit=2)
        self.assertEqual(json.loads(self.store.get("LAP-68")["pending_operation"])["operation"],"resume")
        with self.assertRaises(RuntimeError):  # a second resume cannot exceed the single global slot held by the resume itself
            self.store.resume_claim("LAP-66",{"reply_id":"r4"},global_limit=1)

    def test_uncertain_spawn_intent_facet_mismatch_not_adopted(self):
        import launch
        old=launch.DaemonClient
        launch.DaemonClient=type("D",(),{"__init__":lambda self,*a:None,"health":lambda self:{}})
        path=os.path.join(self.tmp.name,"sid","credential.json"); os.makedirs(os.path.dirname(path)); open(path,"w").write('{"token":"t"}')
        try:
            stranger=[{"session_id":"sid","project_path":self.tmp.name,"state":"running","first_user_message_preview":"Work on LAP-70","facet":"project-manager","port":5}]
            self.assertIsNone(launch.reconcile_session("LAP-70",self.tmp.name,stranger,self.tmp.name,launch_intent={"facet":"quick-delivery","prompt":"x"}))
            match=[dict(stranger[0],facet="quick-delivery")]
            adopted=launch.reconcile_session("LAP-70",self.tmp.name,match,self.tmp.name,launch_intent={"facet":"quick-delivery","prompt":"x"})
            self.assertIsNotNone(adopted); self.assertEqual(adopted[0],"sid")
        finally: launch.DaemonClient=old

    def test_interrogative_reducer_resolved_clears_pending(self):
        import launch
        class D:
            def __init__(self): self.n=-1
            def state(self): return {}
            def events(self): return {"events":[{"type":"interrogative_pending","interrogative":{"id":"q1"}},{"type":"interrogative_answered","id":"q1"}]}
        self.assertIsNone(launch.pending_interrogative(D()))
        class D2(D):
            def events(self): return {"events":[{"type":"interrogative_pending","interrogative":{"id":"q1"}}]}
        self.assertIsNotNone(launch.pending_interrogative(D2()))

    def test_verify_comment_reads_adf_bodies(self):
        from workers import adf_text  # sanity: marker lives inside an ADF body
        jira=Jira(object(),'LAP',"customfield_10043")
        node={"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Dispatcher recovery escalation\nTicket: LAP-71\nDispatcher episode: ep9"}]}]}
        def fake_get_issue(key):
            return {"fields":{"comment":{"comments":[{"body":node}]}}}
        jira.get_issue=fake_get_issue
        self.assertTrue(jira.verify_comment("LAP-71",["Dispatcher recovery escalation","ep9"]))

    def test_delivery_report_recorded_signature_prevents_second_transition(self):
        self.store.claim("LAP-72",self.tmp.name,self.tmp.name)
        self.store.update("LAP-72",stage="awaiting")  # awaiting rows wait for human Done only
        class J:
            def get_issue(self,key): return {"fields":{"status":{"name":"Awaiting Acceptance"}}}
            def transition_to(self,*a,**k): raise AssertionError("no extra transition")
        self.assertEqual(supervise_once(J(),self.store,self.config()),[])

    def test_resume_replay_after_restart_with_persisted_intent(self):
        # Crash between claim+transition and reply delivery: the persisted resume
        # operation replays even though Jira is already In Progress.
        class FakeJira:
            def __init__(self): self.status="In Progress"
            def get_issue(self,key): return {"fields":{"status":{"name":self.status},"issuetype":{"name":"Story"},"customfield_10043":"lappie"}}
            def comments(self,key): return [{"id":"p","created":"2020-01-01T00:00:00Z","body":"## Approved delivery plan\nGit: feat/keep\nDelivery mode: queued\nReview panel: review"},{"id":"r","created":"2999-01-01T00:06:00Z","body":"Reply text."}]
            def search(self,jql=""): return []
            def transitions(self,key): return {"transitions":[{"id":"g","name":"Go","to":{"name":"In Progress"}}]}
            def transition_to(self,key,dest,names): self.status=dest; return {"name":"Go"}
            def verify_transition(self,key,dest): return self.status==dest
        self.store.claim("LAP-80",self.tmp.name,self.tmp.name)
        self.store.update("LAP-80",stage="recovery_pending",session_id="retained",daemon_port=11,
                          resume_intent={"prompt":"Resume LAP-80 with reply.","reply_id":"r","reply_text":"Reply text."},
                          pending_operation={"stage":"recovery_pending","operation":"resume","payload":{"reply_id":"r"}},
                          blocker_comment_time=100.0)
        path=self.store.directory; self.store.close(); self.store=StateStore(path)
        old_live=dispatcher.live_sessions; old_spawn=dispatcher.resume_via_continue; old_launch=dispatcher.launch
        dispatcher.live_sessions=lambda *a,**k:[]
        spawns=[]
        dispatcher.resume_via_continue=lambda *a,**k: spawns.append(a) or ("sid2",4242)
        def fake_launch(repo,facet,prompt,store,key,**kw): raise AssertionError("must not double launch")
        dispatcher.launch=fake_launch
        old_client=dispatcher.DaemonClient; old_cred=__import__('launch')._credential; old_pending=dispatcher.pending_interrogative
        class D:
            def __init__(self,*a,**k): pass
            def health(self): return {}
            def state(self): return {}
            def prompt(self,text): D.prompted=text
        D.prompted=None
        dispatcher.DaemonClient=D; __import__('launch')._credential=lambda *a,**k:"t"; dispatcher.pending_interrogative=lambda d:None
        try:
            out=resume_candidates(FakeJira(),self.store,self.config())
            self.assertEqual(out,[("LAP-80","resumed")],self.store.events("LAP-80")[-3:])
            self.assertEqual(spawns,[("retained","polytoken")],spawns)
            self.assertEqual(D.prompted,"Resume LAP-80 with reply.")
            row=self.store.get("LAP-80"); self.assertEqual(row["stage"],"running"); self.assertEqual(row["pending_operation"],None)
            self.assertEqual(row["consumed_reply_id"],"r")
        finally:
            dispatcher.live_sessions=old_live; dispatcher.resume_via_continue=old_spawn; dispatcher.launch=old_launch
            dispatcher.DaemonClient=old_client; __import__('launch')._credential=old_cred; dispatcher.pending_interrogative=old_pending

    def test_uncertain_continue_defers_fresh_launch(self):
        class FakeJira:
            def get_issue(self,key): return {"fields":{"status":{"name":"In Progress"},"issuetype":{"name":"Story"},"customfield_10043":"lappie"}}
            def comments(self,key): return [{"id":"p","created":"2020-01-01T00:00:00Z","body":"## Approved delivery plan\nGit: b\nDelivery mode: queued\nReview panel: r"},{"id":"r","created":"2999-01-01T00:06:00Z","body":"Reply."}]
            def search(self,jql=""): return []
        self.store.claim("LAP-81",self.tmp.name,self.tmp.name)
        self.store.update("LAP-81",stage="recovery_pending",session_id="retained",daemon_port=11,resume_intent={"prompt":"p","reply_id":"r","reply_text":"Reply."},pending_operation={"stage":"recovery_pending","operation":"resume","payload":{}})
        from launch import ContinueUncertain
        old_spawn=dispatcher.resume_via_continue; old_live=dispatcher.live_sessions; old_launch=dispatcher.launch
        dispatcher.resume_via_continue=lambda *a,**k: (_ for _ in ()).throw(ContinueUncertain("lost ack"))
        dispatcher.live_sessions=lambda *a,**k:[]
        def no_launch(*a,**k): raise AssertionError("fresh launch forbidden before reconcile")
        dispatcher.launch=no_launch
        old_client=dispatcher.DaemonClient; old_cred=__import__('launch')._credential; old_pending=dispatcher.pending_interrogative
        class D:
            def __init__(self,*a,**k): pass
            def health(self): return {}
            def state(self): return {}
        dispatcher.DaemonClient=D; __import__('launch')._credential=lambda *a,**k:"t"; dispatcher.pending_interrogative=lambda d:None
        try:
            out=resume_candidates(FakeJira(),self.store,self.config())
            self.assertEqual(out,[("LAP-81","recovery_pending")])
            self.assertEqual(self.store.get("LAP-81")["stage"],"recovery_pending")
        finally:
            dispatcher.resume_via_continue=old_spawn; dispatcher.live_sessions=old_live; dispatcher.launch=old_launch
            dispatcher.DaemonClient=old_client; __import__('launch')._credential=old_cred; dispatcher.pending_interrogative=old_pending

    def test_negative_completion_report_does_not_accept(self):
        class FakeDaemon:
            def health(self): return {}
            def state(self): return {}
            def events(self): return {"events":[]}
        class FakeJira:
            def __init__(self): self.status="In Progress"; self.writes=[]
            def get_issue(self,key): return {"fields":{"status":{"name":self.status},"comment":{"comments":self.comments_all}}}
            @property
            def comments_all(self): return self._comments
            def comments(self,key): return self._comments
            def transition_to(self,*a,**k): raise AssertionError("must not accept negative completion")
        j=FakeJira(); j._comments=[{"id":"n","created":"2999-01-01T00:00:00Z","body":"## Delivery completion report\nWorker completion report\nBranch: b\nWorktree: w\nCommits: c\nChecks: unit tests failed\nReview: panel approved\nRemaining manual checks: none"}]
        self.store.claim("LAP-82",self.tmp.name,self.tmp.name)
        self.store.update("LAP-82",stage="running",session_id="s",daemon_port=1,launch_time=1)
        old=dispatcher.DaemonClient; old_cred=__import__('launch')._credential; old_pending=dispatcher.pending_interrogative
        dispatcher.DaemonClient=lambda *a,**k:FakeDaemon(); __import__('launch')._credential=lambda *a,**k:"t"; dispatcher.pending_interrogative=lambda d:None
        try:
            out=supervise_once(j,self.store,self.config())
            self.assertEqual(self.store.get("LAP-82")["stage"],"running")
            self.assertEqual([w for w in j.writes],[])
        finally:
            dispatcher.DaemonClient=old; __import__('launch')._credential=old_cred; dispatcher.pending_interrogative=old_pending

    def test_persisted_interrogative_answered_via_respond(self):
        class FakeJira:
            def get_issue(self,key): return {"fields":{"status":{"name":"Ready"},"issuetype":{"name":"Story"},"customfield_10043":"lappie"}}
            def comments(self,key): return [{"id":"p","created":"2020-01-01T00:00:00Z","body":"## Approved delivery plan\nGit: b\nDelivery mode: queued\nReview panel: r"},{"id":"r","created":"2999-01-01T00:06:00Z","body":"The answer."}]
            def search(self,jql=""): return []
            def transitions(self,key): return {"transitions":[{"id":"g","name":"Go","to":{"name":"In Progress"}}]}
            def transition_to(self,key,dest,names): self.status=dest if hasattr(self,"status") else dest; return {"name":"Go"}
            def verify_transition(self,key,dest): return getattr(self,"status","In Progress")==dest
        self.store.claim("LAP-83",self.tmp.name,self.tmp.name)
        self.store.update("LAP-83",stage="blocked",session_id="retained",daemon_port=12,blocker_comment_time=100.0,
                          pending_interrogative={"id":"q9","question":"Which API?"})
        calls={"respond":[],"prompted":[]}
        old_spawn=dispatcher.resume_via_continue; old_live=dispatcher.live_sessions; old_launch=dispatcher.launch
        dispatcher.resume_via_continue=lambda *a,**k: ("sid",4243)
        dispatcher.live_sessions=lambda *a,**k:[]
        dispatcher.launch=lambda *a,**k: (_ for _ in ()).throw(AssertionError("retained continue should win"))
        class D:
            def __init__(self,*a,**k): pass
            def health(self): return {}
            def state(self): return {}
            def respond(self,qid,answer): calls["respond"].append((qid,answer)); return {}
            def prompt(self,text): calls["prompted"].append(text); return {}
        old_client=dispatcher.DaemonClient; old_cred=__import__('launch')._credential; old_pending=dispatcher.pending_interrogative
        dispatcher.DaemonClient=D; __import__('launch')._credential=lambda *a,**k:"t"; dispatcher.pending_interrogative=lambda d:None
        try:
            out=resume_candidates(FakeJira(),self.store,self.config())
            self.assertEqual(out,[("LAP-83","resumed")])
            self.assertEqual(calls["respond"],[("q9","The answer.")])
            self.assertEqual(len(calls["prompted"]),1)
            row=self.store.get("LAP-83"); self.assertEqual(row["pending_interrogative"],None)
            self.assertEqual(row["stage"],"running")
        finally:
            dispatcher.resume_via_continue=old_spawn; dispatcher.live_sessions=old_live; dispatcher.launch=old_launch
            dispatcher.DaemonClient=old_client; __import__('launch')._credential=old_cred; dispatcher.pending_interrogative=old_pending

    def test_escalation_and_block_write_refuse_non_in_progress_source(self):
        class J:
            status="Ready"; transitioned=[]; comments_written=[]
            def get_issue(self,key): return {"fields":{"status":{"name":self.status}}}
            def transitions(self,key): return {"transitions":[{"id":"b","name":"Block","to":{"name":"Blocked"}}]}
            def transition_to(self,key,dest,names): type(self).status=dest; self.transitioned.append(dest); return {"name":"Block"}
            def verify_transition(self,key,dest): return self.status==dest
            def reconcile_comment(self,key,text,markers):
                if any(t["body"]==text for t in J.comments_written): return next(t for t in J.comments_written if t["body"]==text)
                c={"id":"c%d"%(len(J.comments_written)+1),"created":"2999-01-01T00:00:%02dZ"%(len(J.comments_written)+1),"body":text}
                J.comments_written.append(c); return c
        # (a) exhaustion recovery from a Ready ticket: comment-only, NO status move.
        self.store.claim("LAP-84",self.tmp.name,self.tmp.name)
        self.store.update("LAP-84",stage="recovery_pending",pending_operation={"stage":"recovery_pending","operation":"escalation","payload":{"reason":"cap"}})
        j=J()
        self.assertEqual(supervise_once(j,self.store,self.config()),[("LAP-84","blocked")])
        self.assertEqual(j.transitioned,[])
        self.assertEqual(len(j.comments_written),1)
        self.assertIn("Dispatcher recovery escalation",j.comments_written[0]["body"])
        self.assertEqual(self.store.get("LAP-84")["stage"],"blocked")
        # (b) a block episode whose source status moved on (Ready) holds instead.
        self.store.claim("LAP-85",self.tmp.name,self.tmp.name,global_limit=2)
        self.store.update("LAP-85",stage="blocking",pending_operation={"stage":"blocking","operation":"block_transition","payload":{"episode":"e","reason":"r","decision":"d","worktree":self.tmp.name,"branch":"b","commits":"x","checks":"c","remaining":"m"}})
        self.assertEqual(supervise_once(j,self.store,self.config()),[("LAP-85","blocking")])
        self.assertEqual(j.transitioned,[])
        self.assertEqual(self.store.get("LAP-85")["stage"],"blocking")  # op retained; retry when In Progress

    def test_replay_rechecks_current_plan_before_transition_and_spawn(self):
        plan_old={"id":"c1","created":"2020-01-01T00:00:00Z","body":"## Approved delivery plan\nGit: b\nDelivery mode: queued\nReview panel: r"}
        plan_new={"id":"c2","created":"2999-01-01T00:00:00Z","body":"## Approved delivery plan\nGit: b2\nDelivery mode: interactive\nReview panel: r"}
        class J:
            status="Ready"; transitioned=[]
            def get_issue(self,key): return {"fields":{"status":{"name":self.status}}}
            def comments(self,key): return [plan_old, plan_new]
            def transitions(self,key): return {"transitions":[{"id":"g","name":"Go","to":{"name":"In Progress"}}]}
            def transition_to(self,key,dest,names): self.status=dest; self.transitioned.append(dest); return {"name":"Go"}
            def verify_transition(self,key,dest): return self.status==dest
        self.store.claim("LAP-86",self.tmp.name,self.tmp.name)
        self.store.update("LAP-86",stage="ready_to_inprogress",pending_operation={"stage":"ready_to_inprogress","operation":"ready_transition","payload":{}})
        j=J()
        old_live=dispatcher.live_sessions; dispatcher.live_sessions=lambda *a,**k:[]
        old_launch=dispatcher.launch
        def no_launch(*a,**k): raise AssertionError("must not spawn under a superseded interactive plan")
        dispatcher.launch=no_launch
        try:
            out=supervise_once(j,self.store,self.config())
            self.assertEqual(j.transitioned,[])
            self.assertEqual(self.store.get("LAP-86")["stage"],"recovery_pending")
        finally: dispatcher.live_sessions=old_live; dispatcher.launch=old_launch

suite=unittest.defaultTestLoader.loadTestsFromTestCase(DispatcherTests)
result=unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(0 if result.wasSuccessful() else 1)
PY
