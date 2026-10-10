"""Jira lifecycle adapter over the configured MCP gateway."""
from mcp_client import MCPError, MCPRPCError
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from workers import adf_text

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
    def __init__(self, client, project="LAP", custom_project_field="customfield_10043", upstream="atlassian", page_size=10):
        self.client=client; self.project=project; self.custom_project_field=custom_project_field; self.upstream=upstream
        self.cloud_id=None; self.surface=None; self._inspected=set(); self.page_size=page_size

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
        try:
            self.client.tools_call("tool-details",{"luaServerName":self.upstream,"luaToolName":name})
        except (MCPError,MCPRPCError):
            pass  # inspection is advisory; execute surfaces a NotInspected error otherwise
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
            if structured is not None: return structured
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
                    try: return json.loads(text)
                    except ValueError: return text
        return result

    def tools_execute_script(self,script,timeout=None):
        if self.surface is None: self._detect_surface()
        if self.surface!="execute": raise MCPError("gateway execute surface unavailable")
        result=self.client.tools_call("execute",{"script":script},timeout=timeout)
        return self._payload(result)

    def _gateway_execute(self,name,args):
        self._ensure_inspected(name)
        script=(
            "local v=_gateway.unwrap_content(%s.%s(%s))\n"
            "if type(v) == \"string\" and string.match(v,\"Execution ID:\") then\n"
            "  local ident=string.match(v,\"Execution ID: ([%%w%%-]+)\")\n"
            "  v=_gateway.get_result({id=ident})\n"
            "end\n"
            "if type(v) == \"string\" then v=_gateway.json_decode(v) end\n"
            "result(v)"
        )%(self.upstream,name,_lua(args))
        projection=OFFLOAD_PROJECTIONS.get(name)
        if name=="getJiraIssue":
            # Preserve the canonical issue shape, keeping the configured Project field id dynamic.
            field=self.custom_project_field
            projection=('result({key=d.key, fields={status={name=d.fields.status.name}, '
                        'comment=d.fields.comment, issuetype=d.fields.issuetype, summary=d.fields.summary, '
                        'description=d.fields.description, ["%s"]=d.fields["%s"]}})')%(field,field)
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
            try:
                result=self.client.tools_call(name,args)
            except (MCPError, OSError, TimeoutError) as exc:
                if name in ("transitionJiraIssue","addCommentToJiraIssue"): raise UncertainOutcome(str(exc)) from exc
                raise
            if isinstance(result,dict) and result.get("isError"): raise MCPRPCError(result)
            return result.get("structuredContent",result) if isinstance(result,dict) else result

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
        return self._tool("getJiraIssue",{"cloudId":self.cloud_id,"issueIdOrKey":key,"fields":["summary","description","issuetype","status",self.custom_project_field,"comment"]})

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
        return self._tool("addCommentToJiraIssue",{"cloudId":self.cloud_id,"issueIdOrKey":key,"comment":{"body":text}})

    def verify_transition(self,key,status):
        issue=self.get_issue(key); fields=issue.get("fields",{})
        return (fields.get("status") or {}).get("name")==status

    def verify_comment(self,key,markers):
        issue=self.get_issue(key); comments=((issue.get("fields",{}).get("comment") or {}).get("comments") or [])
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

    def reconcile_comment(self,key,text,markers):
        """Look for same-type/key markers before adding, including after a lost acknowledgment."""
        existing=self.verify_comment(key,markers)
        if existing: return existing[0]
        try:
            self.comment(key,text)
        except UncertainOutcome:
            existing=self.verify_comment(key,markers)
            if existing: return existing[0]
            raise
        existing=self.verify_comment(key,markers)
        if existing: return existing[0]
        raise UncertainOutcome("comment response received but marker not verified")

    def comments(self,key):
        issue=self.get_issue(key)
        return ((issue.get("fields",{}).get("comment") or {}).get("comments") or [])
