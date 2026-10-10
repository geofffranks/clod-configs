"""Jira lifecycle adapter over the configured MCP gateway."""
from mcp_client import MCPError, MCPRPCError
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from workers import adf_text, comment_history

SAFE_INSPECT_TOOLS = {
    "getAccessibleAtlassianResources",
    "searchJiraIssuesUsingJql",
    "getJiraIssue",
    "getTransitionsForJiraIssue",
    "getJiraProjectIssueTypesMetadata",
}

OFFLOAD_PROJECTIONS = {
    # On heavyweight upstream results the gateway stores the value and returns an
    # offload summary; a follow-up script re-projects only the fields we need while
    # PRESERVING the canonical response shape callers expect.
    "getJiraIssue": 'result({key=d.key, fields={status={name=d.fields.status.name}, comment=d.fields.comment, issuetype=d.fields.issuetype, summary=d.fields.summary, description=d.fields.description, customfield_10043=d.fields.customfield_10043}})',
    "searchJiraIssuesUsingJql": 'result({issues=d.issues, nextPageToken=d.nextPageToken})',
    "getJiraProjectIssueTypesMetadata": 'result({issueTypes=d.issueTypes})',
}

class UncertainOutcome(RuntimeError): pass
class WriteNotStarted(RuntimeError): pass

def _lua_escape(s):
    return '"%s"'%s.replace("\\","\\\\").replace('"','\\"').replace("\n","\\n").replace("\r","\\r")

def _lua(value):
    if value is None: return "nil"
    if isinstance(value,bool): return "true" if value else "false"
    if isinstance(value,(int,float)): return repr(value)
    if isinstance(value,str): return _lua_escape(value)
    if isinstance(value,dict):
        return "{"+",".join('["%s"]=%s'%(k,_lua(v)) for k,v in value.items())+"}"
    if isinstance(value,(list,tuple)):
        return "{"+",".join(_lua(v) for v in value)+"}"
    raise TypeError("cannot encode %r as Lua"%type(value))

class Jira:
    def __init__(self, client, project="LAP", custom_project_field="customfield_10043", upstream="atlassian", page_size=10, agent_sessions_field="customfield_10048", store=None):
        self.client=client; self.project=project; self.custom_project_field=custom_project_field; self.upstream=upstream
        self.cloud_id=None; self.surface=None; self._inspected=set(); self.page_size=page_size
        self.agent_sessions_field=agent_sessions_field; self.store=store; self._comment_ops={}

    def _detect_surface(self):
        """Ratatoskr exposes upstream tools behind tool-details/execute; direct names otherwise."""
        try: tools=self.client.tools_list()
        except Exception: tools={}
        names=set()
        if isinstance(tools,dict):
            for t in tools.get("tools",[]) or []: names.add(t.get("name"))
        self.surface="execute" if "execute" in names else "direct"
        return self.surface

    def _ensure_inspected(self,name):
        if name in self._inspected: return
        response=self.client.tools_call("tool-details",{"luaServerName":self.upstream,"luaToolName":name})
        self._payload(response)  # tool/API errors do not count as successful inspection
        self._inspected.add(name)

    @staticmethod
    def _offload_identifier(text):
        for token in reversed(text.replace(","," ").replace(";"," ").replace("\n"," ").split()):
            if len(token)>=8 and all(c.isalnum() or c=="-" for c in token) and any(c.isalpha() for c in token):
                return token
        return None

    def _payload(self,result,projection=None):
        """Decode an MCP tool result: structured content, the text JSON, or an offload summary."""
        if isinstance(result,dict):
            if result.get("isError"):
                blocks=result.get("content") or []
                detail="; ".join(b.get("text","") for b in blocks if isinstance(b,dict)) or "MCP tool error"
                raise MCPError("gateway tool error: %s"%detail[:500])
            structured=result.get("structuredContent")
            if structured is not None: return self._payload(structured)
            if result.get("error") or result.get("errors") or result.get("errorMessages"):
                raise MCPError("Jira API error: %s"%str(result)[:500])
            for block in result.get("content",[]) or []:
                if isinstance(block,dict) and block.get("type")=="text":
                    text=block.get("text","")
                    if "Execution ID:" in text:
                        identifier=self._offload_identifier(text)
                        if identifier and projection:
                            follow='local d=_gateway.get_result({id=%s})\n%s'%(_lua_escape(identifier),projection)
                            return self.tools_execute_script(follow)
                        if identifier:
                            raise MCPError("offloaded gateway result is too large to project; page_size or fields need reduction")
                    try: return self._payload(json.loads(text))
                    except ValueError: return text
        return result

    def tools_execute_script(self,script,timeout=None):
        if self.surface is None: self._detect_surface()
        if self.surface!="execute": raise MCPError("gateway execute surface unavailable")
        result=self.client.tools_call("execute",{"script":script},timeout=timeout)
        return self._payload(result)

    def _gateway_execute(self,name,args):
        self._ensure_inspected(name)
        writes={"transitionJiraIssue","addCommentToJiraIssue","editJiraIssue"}
        if name in writes:
            script="local response=%s.%s(%s)\nresult(response)"%(self.upstream,name,_lua(args))
            self._write_admitted()
            try:
                response=self._payload(self.client.tools_call("execute",{"script":script}))
                if response is None or isinstance(response,dict) and response.get("content")==[]:
                    raise UncertainOutcome("write script returned no result")
                return response
            except Exception as exc:
                raise UncertainOutcome("write request outcome unknown: %s"%exc) from exc
        script=(
            "local response=%s.%s(%s)\n"
            "if type(response) == \"table\" and response.isError then result(response) else\n"
            "local v=_gateway.unwrap_content(response)\n"
            "if type(v) == \"string\" and string.match(v,\"Execution ID:\") then\n"
            "  local ident=string.match(v,\"Execution ID: ([%%w%%-]+)\")\n"
            "  v=_gateway.get_result({id=ident})\n"
            "end\n"
            "if type(v) == \"string\" and string.match(v,\"^%%s*[%%{%%[]\") then v=_gateway.json_decode(v) end\n"
            "result(v) end"
        )%(self.upstream,name,_lua(args))
        projection=OFFLOAD_PROJECTIONS.get(name)
        if name=="getJiraIssue":
            # Preserve the canonical issue shape, keeping the configured Project field id dynamic.
            field=self.custom_project_field
            projection=('result({key=d.key, fields={status={name=d.fields.status.name}, '
                        'comment=d.fields.comment, issuetype=d.fields.issuetype, summary=d.fields.summary, '
                        'description=d.fields.description, ["%s"]=d.fields["%s"], ["%s"]=d.fields["%s"]}})')%(field,field,self.agent_sessions_field,self.agent_sessions_field)
        if self.surface is None: self._detect_surface()
        result=self.client.tools_call("execute",{"script":script})
        return self._payload(result,projection=projection)

    def _tool(self,name,args):
        if self.surface is None: self._detect_surface()
        if self.surface=="execute":
            try:
                return self._gateway_execute(name,args)
            except (MCPError,MCPRPCError):
                if name in SAFE_INSPECT_TOOLS:
                    # Read-only fallback: one inspected probe call is safe for these tools.
                    try:
                        probe=self.client.tools_call("inspect-tool-response",{"luaServerName":self.upstream,"luaToolName":name,"arguments":args})
                        self._inspected.add(name)
                        return self._payload(probe)
                    except MCPRPCError as exc:
                        if "NotInspected" not in str(exc): raise
                raise
        else:
            if name in ("transitionJiraIssue","addCommentToJiraIssue","editJiraIssue"): self._write_admitted()
            try:
                result=self.client.tools_call(name,args)
            except (MCPError, OSError, TimeoutError) as exc:
                if name in ("transitionJiraIssue","addCommentToJiraIssue","editJiraIssue"): raise UncertainOutcome(str(exc)) from exc
                raise
            return self._payload(result)

    def discover_cloud_id(self):
        resources=self._tool("getAccessibleAtlassianResources",{})
        if not resources: raise RuntimeError("no accessible Atlassian resources")
        self.cloud_id=resources[0].get("id") or resources[0].get("cloudId")
        if not self.cloud_id: raise RuntimeError("Atlassian resource omitted cloud id")
        return self.cloud_id

    def search(self, extra_jql="", page_size=None):
        """Rank-ordered issue search; keep pages small so comment-heavy pages stay readable."""
        if not self.cloud_id: self.discover_cloud_id()
        jql='project = "%s"'%self.project
        if extra_jql: jql += " AND ("+extra_jql+")"
        jql += " ORDER BY Rank"
        fields=["summary","issuetype","status",self.custom_project_field]
        token=None
        while True:
            args={"cloudId":self.cloud_id,"jql":jql,"maxResults":page_size or self.page_size,"fields":fields}
            if token: args["nextPageToken"]=token
            result=self._tool("searchJiraIssuesUsingJql",args)
            issues=result.get("issues",[]) if isinstance(result,dict) else []
            for issue in issues: yield issue
            token=result.get("nextPageToken") if isinstance(result,dict) else None
            if not token: break

    def get_issue(self,key):
        if not self.cloud_id: self.discover_cloud_id()
        return self._tool("getJiraIssue",{"cloudId":self.cloud_id,"issueIdOrKey":key,"fields":["summary","description","issuetype","status",self.custom_project_field,self.agent_sessions_field,"comment"],"responseContentFormat":"markdown"})

    def transitions(self,key):
        if not self.cloud_id: self.discover_cloud_id()
        return self._tool("getTransitionsForJiraIssue",{"cloudId":self.cloud_id,"issueIdOrKey":key})

    @staticmethod
    def select_transition(transitions,name,destination):
        values=transitions.get("transitions",transitions) if isinstance(transitions,dict) else transitions
        for item in values or []:
            to=item.get("to") or {}
            if item.get("name")==name and to.get("name")==destination: return item
        raise LookupError("no transition %r to %r"%(name,destination))

    @staticmethod
    def select_destination_transition(transitions,destination,names=()):
        values=transitions.get("transitions",transitions) if isinstance(transitions,dict) else transitions
        for hint in names or ():
            for item in values or []:
                if item.get("name")==hint and (item.get("to") or {}).get("name")==destination: return item
        for item in values or []:
            if (item.get("to") or {}).get("name")==destination: return item
        raise LookupError("no transition to %r"%destination)

    def transition(self,key,name,destination,fields=None):
        transition=self.select_transition(self.transitions(key),name,destination)
        args={"cloudId":self.cloud_id,"issueIdOrKey":key,"transition":{"id":transition["id"]}}
        if fields: args["fields"]=fields
        return self._tool("transitionJiraIssue",args)

    def transition_to(self,key,destination,names=()):
        transition=self.select_destination_transition(self.transitions(key),destination,names)
        self._tool("transitionJiraIssue",{"cloudId":self.cloud_id,"issueIdOrKey":key,"transition":{"id":transition["id"]}})
        return transition

    def comment(self,key,text):
        if not self.cloud_id: self.discover_cloud_id()
        return self._tool("addCommentToJiraIssue",{"cloudId":self.cloud_id,"issueIdOrKey":key,"commentBody":text,"contentFormat":"markdown","responseContentFormat":"markdown"})

    def verify_transition(self,key,status):
        issue=self.get_issue(key); fields=issue.get("fields",{})
        return (fields.get("status") or {}).get("name")==status

    def verify_comment(self,key,markers):
        comments=self.comments(key)
        return [c for c in comments if all(m in adf_text(c.get("body")) for m in markers)]

    def issue_types(self):
        if not self.cloud_id: self.discover_cloud_id()
        metadata=self._tool("getJiraProjectIssueTypesMetadata",{"cloudId":self.cloud_id,"projectIdOrKey":self.project})
        if isinstance(metadata,dict): return metadata.get("issueTypes",[])
        return metadata or []

    def reconcile_transition(self,key,name,destination,fields=None):
        try:
            self.transition(key,name,destination,fields)
        except UncertainOutcome:
            if self.verify_transition(key,destination): return True
            raise
        if not self.verify_transition(key,destination): raise UncertainOutcome("transition response received but status not verified")
        return True

    def _preflight_write(self,name):
        if self.surface is None: self._detect_surface()
        if self.surface=="execute": self._ensure_inspected(name)

    def _write_admitted(self):
        if self.store and (self.store.get_control("pause","false")=="true" or self.store.get_control("stop","false")=="true"):
            raise WriteNotStarted("dispatcher paused/stopped before new Jira write")

    def _comment_operation(self,key,markers,text=None,state=None,comment_id=None):
        if self.store: return self.store.comment_operation(key,markers,text,state,comment_id)
        token=(key,tuple(markers))
        if state: self._comment_ops[token]={"state":state,"comment_id":comment_id,"body":text}
        return self._comment_ops.get(token)

    def reconcile_comment(self,key,text,markers):
        """Positive evidence reconciles; even complete absence cannot settle an in-flight write."""
        # Retain compatibility with caller-owned adapters that already prove positive evidence.
        existing=self.verify_comment(key,markers)
        if existing:
            if hasattr(self,"_comment_operation"):
                self._comment_operation(key,markers,text,"observed",str(existing[0].get("id","")))
            return existing[0]
        op=self._comment_operation(key,markers)
        if op and op["state"]!="not_committed":
            raise UncertainOutcome("original comment request remains pending; negative read does not prove non-commit")
        history=self.comments(key)
        if not history.complete: raise UncertainOutcome("comment coverage unknown/incomplete; no write authorized")
        self._preflight_write("addCommentToJiraIssue")  # failure here proves no request was dispatched
        self._write_admitted()
        self._comment_operation(key,markers,text,"pending")  # persist before remote side effect
        try:
            response=self.comment(key,text)
            cid=response.get("id") if isinstance(response,dict) else None
            self._comment_operation(key,markers,text,"pending",str(cid) if cid else None)
        except WriteNotStarted:
            self._comment_operation(key,markers,text,"not_committed")
            raise
        except Exception:
            existing=self.verify_comment(key,markers)
            if existing:
                self._comment_operation(key,markers,text,"observed",str(existing[0].get("id","")))
                return existing[0]
            raise
        existing=self.verify_comment(key,markers)
        if existing:
            self._comment_operation(key,markers,text,"observed",str(existing[0].get("id","")))
            return existing[0]
        raise UncertainOutcome("comment acknowledgment received but publication not observed")

    def comments(self,key):
        return comment_history(self.get_issue(key))

    def sync_attribution(self,store):
        """Independent best-effort sync; failures never alter lifecycle or launch authority."""
        self.store=store
        for event in store.associations():
            key=event["key"]; sid=event["session_id"]; stage=event["stage"]
            marker="Agent session association: %s / %s / %s"%(key,sid,stage)
            body="## Agent session attribution\n%s\nStage: %s\nSession id: %s"%(marker,stage,sid)
            if event.get("predecessor"): body+="\nPredecessor session: "+event["predecessor"]
            if not event.get("comment_id"):
                try:
                    comment=self.reconcile_comment(key,body,[marker])
                    store.association_update(key,sid,stage,comment_id=str(comment["id"]))
                except Exception as exc: store.journal(key,"attribution_comment_pending",str(exc))
            if event["aggregate_observed"]: continue
            try:
                fields=self.get_issue(key).get("fields",{})
                if self.agent_sessions_field not in fields: raise UncertainOutcome("Agent Sessions omitted; value unknown")
                value=fields[self.agent_sessions_field]
                # Null/omission semantics have not been demonstrated by the live field test.
                if not isinstance(value,str): raise UncertainOutcome("Agent Sessions is not a text value")
                if sid in [x.strip() for x in value.split(",")]:
                    store.association_update(key,sid,stage,aggregate_observed=1,aggregate_pending=None)
                    continue
                if event["aggregate_pending"]=="uncertain":
                    raise UncertainOutcome("original field request unresolved; no replacement write")
                if event["aggregate_attempts"]>=2: raise UncertainOutcome("two aggregate edit attempts exhausted")
                merged=value+("" if not value else ", ")+sid
                self._preflight_write("editJiraIssue")
                self._write_admitted()
                store.association_update(key,sid,stage,aggregate_attempts=event["aggregate_attempts"]+1,aggregate_pending="uncertain")
                try:
                    self._tool("editJiraIssue",{"cloudId":self.cloud_id,"issueIdOrKey":key,"fields":{self.agent_sessions_field:merged},"contentFormat":"markdown"})
                    store.association_update(key,sid,stage,aggregate_pending="readback")
                except WriteNotStarted:
                    store.association_update(key,sid,stage,aggregate_attempts=event["aggregate_attempts"],aggregate_pending=event["aggregate_pending"])
                    raise
                finally:
                    fields=self.get_issue(key).get("fields",{})
                    seen=fields.get(self.agent_sessions_field)
                    if isinstance(seen,str) and sid in [x.strip() for x in seen.split(",")]:
                        store.association_update(key,sid,stage,aggregate_observed=1,aggregate_pending=None)
            except Exception as exc: store.journal(key,"attribution_aggregate_pending",str(exc))
