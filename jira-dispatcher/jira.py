"""Jira lifecycle adapter over the configured MCP gateway."""
from mcp_client import MCPError, MCPRPCError

class UncertainOutcome(RuntimeError): pass

class Jira:
    def __init__(self, client, project="LAP", custom_project_field="customfield_10043"):
        self.client=client; self.project=project; self.custom_project_field=custom_project_field; self.cloud_id=None

    def _tool(self,name,args):
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

    def search(self, extra_jql="", page_size=50):
        if not self.cloud_id: self.discover_cloud_id()
        jql='project = "%s"'%self.project
        if extra_jql: jql += " AND ("+extra_jql+")"
        jql += " ORDER BY Rank"
        fields=["summary","issuetype","status","assignee",self.custom_project_field,"comment","issuelinks"]
        token=None
        while True:
            args={"cloudId":self.cloud_id,"jql":jql,"maxResults":page_size,"fields":fields}
            if token: args["nextPageToken"]=token
            result=self._tool("searchJiraIssuesUsingJql",args)
            issues=result.get("issues",[]) if isinstance(result,dict) else []
            for issue in issues: yield issue
            token=result.get("nextPageToken") if isinstance(result,dict) else None
            if not token: break

    def get_issue(self,key):
        if not self.cloud_id: self.discover_cloud_id()
        return self._tool("getJiraIssue",{"cloudId":self.cloud_id,"issueIdOrKey":key,"fields":["summary","description","issuetype","status","assignee",self.custom_project_field,"comment","issuelinks"]})

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
        return [c for c in comments if all(m in str(c.get("body","")) for m in markers)]

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
