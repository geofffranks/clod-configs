"""Small non-LLM Streamable HTTP MCP client; never retries a tool call."""
import http.client
import json
import urllib.parse

class MCPError(RuntimeError):
    pass
class MCPRPCError(MCPError):
    def __init__(self, error):
        self.error=error
        super().__init__("JSON-RPC error: %s" % error)
class MCPSessionLost(MCPError):
    pass

class MCPClient:
    def __init__(self, endpoint="http://127.0.0.1:8910/mcp", timeout=30):
        self.endpoint=endpoint; self.timeout=timeout; self.session_id=None; self.protocol_version="2024-11-05"; self._id=0
        u=urllib.parse.urlsplit(endpoint)
        if u.scheme not in ("http","https"): raise ValueError("MCP endpoint must use HTTP(S)")
        self.scheme=u.scheme; self.host=u.hostname; self.port=u.port; self.path=u.path or "/"

    def _request(self, method, params=None, timeout=None):
        self._id+=1
        payload={"jsonrpc":"2.0","id":self._id,"method":method}
        if params is not None: payload["params"]=params
        headers={"Content-Type":"application/json","Accept":"application/json, text/event-stream"}
        if self.session_id: headers["Mcp-Session-Id"]=self.session_id
        conn=(http.client.HTTPSConnection if self.scheme=="https" else http.client.HTTPConnection)(self.host,self.port,timeout=timeout or self.timeout)
        try:
            conn.request("POST",self.path,body=json.dumps(payload).encode(),headers=headers)
            response=conn.getresponse(); body=response.read(); sid=response.getheader("Mcp-Session-Id")
            if sid: self.session_id=sid
            if response.status in (400,404,410) and self.session_id:
                self.session_id=None; raise MCPSessionLost("MCP session lost (%s)"%response.status)
            if response.status<200 or response.status>=300: raise MCPError("MCP HTTP %s: %s"%(response.status,body[:500].decode("utf-8","replace")))
            ctype=(response.getheader("Content-Type") or "").split(";",1)[0].strip().lower()
            if ctype=="text/event-stream":
                parsed=[]
                for frame in body.decode("utf-8","replace").replace("\r\n","\n").split("\n\n"):
                    lines=[line[5:].lstrip() for line in frame.splitlines() if line.startswith("data:")]
                    text="\n".join(line for line in lines if line.strip())
                    if not text or text=="[DONE]": continue
                    parsed.append(json.loads(text))
                if not parsed: raise MCPError("empty MCP event stream")
                message=next((p for p in parsed if p.get("id")==payload["id"]),parsed[-1])
            else: message=json.loads(body.decode("utf-8"))
            if message.get("error") is not None: raise MCPRPCError(message["error"])
            return message.get("result")
        except (OSError, http.client.HTTPException, TimeoutError) as exc:
            raise MCPError("MCP transport uncertain: %s"%exc) from exc
        finally: conn.close()

    def initialize(self, timeout=None):
        result=self._request("initialize",{"protocolVersion":self.protocol_version,"capabilities":{},"clientInfo":{"name":"jira-dispatcher","version":"1.0"}},timeout)
        if isinstance(result,dict) and result.get("protocolVersion"): self.protocol_version=result["protocolVersion"]
        # MCP initialized notification is deliberately best-effort: no side effect to duplicate.
        self._notification("notifications/initialized")
        return result

    def _notification(self, method):
        payload={"jsonrpc":"2.0","method":method}; headers={"Content-Type":"application/json","Accept":"application/json, text/event-stream"}
        if self.session_id: headers["Mcp-Session-Id"]=self.session_id
        conn=(http.client.HTTPSConnection if self.scheme=="https" else http.client.HTTPConnection)(self.host,self.port,timeout=self.timeout)
        try: conn.request("POST",self.path,body=json.dumps(payload).encode(),headers=headers); r=conn.getresponse(); r.read()
        except (OSError,http.client.HTTPException): pass
        finally: conn.close()

    def call(self, method, params=None, timeout=None):
        try: return self._request(method,params,timeout)
        except MCPSessionLost as exc:
            self.initialize(timeout=timeout)
            raise MCPError("MCP session reinitialized; request outcome must be reconciled") from exc

    def tools_list(self, timeout=None): return self.call("tools/list",{},timeout)
    def tools_call(self, name, arguments=None, timeout=None):
        return self.call("tools/call",{"name":name,"arguments":arguments or {}},timeout)
