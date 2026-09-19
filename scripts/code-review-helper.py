#!/usr/bin/env python3
"""Read-only deterministic code-review acquisition contract helper."""
import argparse, hashlib, json, os, sys
from pathlib import Path
MAX_ATTEMPTS, MAX_RECHECKS, MAX_PAGES, MAX_SNAPSHOT_BYTES = 3, 2, 100, 10 * 1024 * 1024

def blocked(reason):
    print(json.dumps({"status":"blocked", "reason":str(reason)}, sort_keys=True)); raise SystemExit(2)
def load(path):
    try:
        with open(path, encoding="utf-8") as f: return json.load(f)
    except Exception as e: blocked(f"invalid input: {e}")
def canon(obj): return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
def guard(root, path):
    r, p = Path(root).resolve(), Path(path).resolve()
    if r != p and r not in p.parents: blocked("state root escape")
def pages(data):
    if len(data.get("pages", [])) > MAX_PAGES or not data.get("pagination_complete", False): blocked("pagination incomplete or page limit exceeded")
def hash_snapshot(manifest, artifacts):
    m = dict(manifest); m.pop("snapshot_digest", None); h = hashlib.sha256(canon(m))
    for name in sorted(artifacts): h.update(name.encode()); h.update(artifacts[name])
    return h.hexdigest()
def preflight(d):
    if not d.get("authenticated") or not d.get("read_capable") or d.get("write_capable"): blocked("gh read-only preflight failed")
    pages(d); print(json.dumps({"status":"ready","max_pages":MAX_PAGES}, sort_keys=True))
def snapshot(d, root):
    pages(d); attempts, rechecks = int(d.get("acquisition_attempts",1)), int(d.get("rechecks",1))
    if not 1 <= attempts <= MAX_ATTEMPTS or not 1 <= rechecks <= MAX_RECHECKS: blocked("acquisition bounds exceeded")
    if not d.get("stable_identity",False): blocked("moving identity")
    run, scope = d.get("review_run_id"), d.get("scope_id")
    if not run or not scope: blocked("missing scope or run ID")
    out=Path(root)/"snapshot"/run; guard(root,out)
    if out.exists(): blocked("run collision or partial state")
    inventory=[]; artifacts={}
    for path,spec in sorted(d.get("files",{}).items()):
        raw_parts=path.split("/") if isinstance(path,str) else []
        if (not isinstance(path,str) or not path or path.startswith("/") or "\\" in path
                or any(not part or part in (".", "..") for part in raw_parts)):
            blocked("invalid inventory path")
        Path(path)  # Construct only after validating the original slash-separated string.
        if not isinstance(spec,dict): blocked("invalid file record")
        marker={k:spec.get(k) for k in ("excluded","binary","lfs","submodule","generated") if k in spec}
        entry={"path":path,"mode":spec.get("mode"),"base_blob":spec.get("base_blob"),"head_blob":spec.get("head_blob"),"markers":marker}
        inventory.append(entry)
        if any(marker.values()): continue
        for side in ("base","head"):
            content=spec.get(side)
            if content is None: blocked(f"missing {side} content: {path}")
            b=content.encode();
            if len(b)>MAX_SNAPSHOT_BYTES: blocked("snapshot byte limit exceeded")
            artifacts[f"files/{side}/{path}"]=b
    manifest={k:d[k] for k in sorted(d) if k not in ("files","snapshot_digest")}
    manifest.update({"schema_version":1,"scope_id":scope,"review_run_id":run,"digest_algorithm":"sha-256","canonical_ordering":"manifest canonical JSON sorted keys, then artifacts lexicographic path","files_inventory":inventory,"artifact_order":sorted(artifacts),"max_snapshot_bytes":MAX_SNAPSHOT_BYTES,"base_head_recheck":d.get("base_head_recheck",True)})
    if len(canon(manifest))+sum(len(k.encode())+len(v) for k,v in artifacts.items())>MAX_SNAPSHOT_BYTES: blocked("snapshot byte limit exceeded")
    manifest["snapshot_digest"]=hash_snapshot(manifest,artifacts); out.mkdir(parents=True)
    for name,b in artifacts.items(): p=out/name; guard(root,p); p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes(b)
    (out/"manifest.json").write_bytes(canon(manifest)+b"\n")
    print(json.dumps({"status":"captured","snapshot":str(out),"snapshot_digest":manifest["snapshot_digest"]},sort_keys=True))
def verify(d,root):
    p=Path(d.get("snapshot","")); guard(root,p); mf=p/"manifest.json"
    if not mf.exists(): blocked("missing manifest")
    try: m=json.loads(mf.read_text()); artifacts={n.relative_to(p).as_posix():n.read_bytes() for n in p.rglob("*") if n.is_file() and n != mf}
    except Exception as e: blocked(f"corrupt snapshot: {e}")
    if m.get("snapshot_digest") != hash_snapshot(m,artifacts): blocked("snapshot digest mismatch")
    if m.get("artifact_order") != sorted(artifacts): blocked("artifact ordering mismatch")
    print(json.dumps({"status":"verified","snapshot_digest":m["snapshot_digest"]},sort_keys=True))
def valid_journal_record(record):
    return (isinstance(record,dict) and isinstance(record.get("review_run_id"),str)
            and bool(record["review_run_id"].strip()))
def journal(d,path,root):
    guard(root,path); p=Path(path)
    if p.exists():
        raw=p.read_bytes()
        if raw and not raw.endswith(b"\n"): blocked("truncated journal tail")
        for i,line in enumerate(raw.splitlines(),1):
            try: record=json.loads(line)
            except Exception: blocked(f"corrupt journal record {i}")
            if not valid_journal_record(record): blocked(f"invalid journal record {i}")
    event=d.get("event");
    if not valid_journal_record(event): blocked("journal event missing review_run_id")
    p.parent.mkdir(parents=True,exist_ok=True); line=canon(event)+b"\n"; fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_APPEND,0o600)
    try:
        pos=0
        while pos<len(line): pos += os.write(fd,line[pos:])
    finally: os.close(fd)
    print(json.dumps({"status":"appended"},sort_keys=True))
def follow(d):
    a,b=d.get("prior",{}),d.get("current",{})
    for k in ("repository","base_sha","merge_base_sha"):
        if a.get(k)!=b.get(k): blocked(f"follow-up {k} changed")
    if b.get("force_pushed") or b.get("history_mappable") is False: blocked("force-push or unmappable history")
    print(json.dumps({"status":"targeted","paths":sorted(set(d.get("unresolved_paths",[]))|set(b.get("changed_paths",[]))),"full_review":False},sort_keys=True))
def candidate(d):
    for k in ("head_sha","snapshot_digest","scope_id","review_run_id"):
        if d.get("candidate",{}).get(k)!=d.get("expected",{}).get(k): blocked(f"candidate {k} mismatch")
    print(json.dumps({"status":"accepted"},sort_keys=True))
def resolve(d):
    helper=Path(d.get("helper_path","")); checkout=Path(d.get("target_checkout","")).resolve()
    if not helper.is_file() or checkout in helper.resolve().parents or helper.resolve()==checkout: blocked("trusted helper missing or inside target checkout")
    print(json.dumps({"status":"trusted","helper":str(helper.resolve())},sort_keys=True))
def main():
    ap=argparse.ArgumentParser(); sp=ap.add_subparsers(dest="cmd",required=True)
    for n in ("preflight","snapshot","verify","followup","candidate","resolve"): sp.add_parser(n).add_argument("input")
    j=sp.add_parser("journal"); j.add_argument("input"); j.add_argument("path"); j.add_argument("root")
    a=ap.parse_args(); d=load(a.input); root=os.environ.get("CODE_REVIEW_STATE_ROOT",d.get("state_root","."))
    if a.cmd=="preflight": preflight(d)
    elif a.cmd=="snapshot": snapshot(d,root)
    elif a.cmd=="verify": verify(d,root)
    elif a.cmd=="journal": journal(d,a.path,a.root)
    elif a.cmd=="followup": follow(d)
    elif a.cmd=="candidate": candidate(d)
    else: resolve(d)
if __name__=="__main__":
    try: main()
    except SystemExit: raise
    except Exception as e: blocked(f"helper failure: {e}")
