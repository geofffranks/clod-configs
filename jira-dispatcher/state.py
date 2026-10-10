"""Transactional local state for dispatcher efforts."""
import json
import os
import sqlite3
import threading
import time
import uuid

ACTIVE_STAGES = ("selected", "ready_to_inprogress", "launching", "running", "blocking", "awaiting", "recovery_pending")
STAGES = set(ACTIVE_STAGES) | {"blocked", "done"}

class StateStore:
    def __init__(self, directory):
        self.directory = os.path.abspath(os.path.expanduser(directory))
        os.makedirs(self.directory, mode=0o700, exist_ok=True)
        self.path = os.path.join(self.directory, "state.sqlite3")
        self.db = sqlite3.connect(self.path, timeout=30, isolation_level=None, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.executescript("""
          CREATE TABLE IF NOT EXISTS efforts (
            id TEXT PRIMARY KEY, key TEXT NOT NULL UNIQUE, repo TEXT NOT NULL, canonical_repo TEXT NOT NULL,
            stage TEXT NOT NULL, session_id TEXT, worktree_path TEXT, branch TEXT, plan_comment_ref TEXT,
            plan_excerpt TEXT, launch_attempts INTEGER NOT NULL DEFAULT 0, blocker_attempts INTEGER NOT NULL DEFAULT 0,
            launch_intent TEXT, pending_interrogative TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL,
            last_reconcile_notes TEXT, daemon_port INTEGER, launch_time REAL, blocker_comment_id TEXT,
            blocker_comment_time REAL, completion_comment_id TEXT, last_completion_signature TEXT,
            pending_operation TEXT, blocker_episode_id TEXT, blocker_epoch INTEGER NOT NULL DEFAULT 0,
            resume_intent TEXT, event_cursor INTEGER NOT NULL DEFAULT 0,
            consumed_reply_id TEXT, resume_reply_time REAL
          );
          CREATE TABLE IF NOT EXISTS journal (id INTEGER PRIMARY KEY AUTOINCREMENT, effort_id TEXT, event TEXT NOT NULL, detail TEXT, created_at REAL NOT NULL);
          CREATE TABLE IF NOT EXISTS controls (name TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at REAL NOT NULL);
          CREATE TABLE IF NOT EXISTS session_associations (
            key TEXT NOT NULL, session_id TEXT NOT NULL, stage TEXT NOT NULL,
            predecessor TEXT, created_at REAL NOT NULL, comment_id TEXT,
            aggregate_attempts INTEGER NOT NULL DEFAULT 0, aggregate_observed INTEGER NOT NULL DEFAULT 0,
            aggregate_pending TEXT, PRIMARY KEY(key,session_id,stage)
          );
          CREATE TABLE IF NOT EXISTS comment_operations (
            key TEXT NOT NULL, markers TEXT NOT NULL, body TEXT NOT NULL,
            state TEXT NOT NULL, comment_id TEXT, PRIMARY KEY(key,markers)
          );
        """)
        columns={r[1] for r in self.db.execute("PRAGMA table_info(efforts)")}
        for name,kind in (("daemon_port","INTEGER"),("launch_time","REAL"),("blocker_comment_id","TEXT"),("blocker_comment_time","REAL"),("completion_comment_id","TEXT"),("last_completion_signature","TEXT"),("pending_operation","TEXT"),("blocker_episode_id","TEXT"),("blocker_epoch","INTEGER NOT NULL DEFAULT 0"),("resume_intent","TEXT"),("event_cursor","INTEGER NOT NULL DEFAULT 0"),("consumed_reply_id","TEXT"),("resume_reply_time","REAL")):
            if name not in columns: self.db.execute("ALTER TABLE efforts ADD COLUMN %s %s"%(name,kind))

    def close(self): self.db.close()

    def associate(self,key,session_id,stage,predecessor=None):
        if not session_id: raise ValueError("actual session identity required")
        with self.lock:
            self.db.execute("INSERT OR IGNORE INTO session_associations(key,session_id,stage,predecessor,created_at) VALUES(?,?,?,?,?)",(key,session_id,stage,predecessor,time.time()))

    def associations(self,key=None):
        with self.lock:
            query="SELECT * FROM session_associations"+(" WHERE key=?" if key else "")+" ORDER BY created_at"
            return [dict(r) for r in self.db.execute(query,(key,) if key else ())]

    def association_update(self,key,sid,stage,**fields):
        allowed={"comment_id","aggregate_attempts","aggregate_observed","aggregate_pending"}
        if not fields or not set(fields)<=allowed: raise ValueError("invalid association update")
        with self.lock:
            self.db.execute("UPDATE session_associations SET "+",".join(k+"=?" for k in fields)+" WHERE key=? AND session_id=? AND stage=?",list(fields.values())+[key,sid,stage])

    def comment_operation(self,key,markers,body=None,state=None,comment_id=None):
        token=json.dumps(markers)
        with self.lock:
            if state:
                self.db.execute("INSERT INTO comment_operations(key,markers,body,state,comment_id) VALUES(?,?,?,?,?) ON CONFLICT(key,markers) DO UPDATE SET state=excluded.state,comment_id=excluded.comment_id",(key,token,body or "",state,comment_id))
            row=self.db.execute("SELECT * FROM comment_operations WHERE key=? AND markers=?",(key,token)).fetchone()
            return dict(row) if row else None

    def _row(self, row):
        if row is None: return None
        data=dict(row)
        for column in ("launch_intent","pending_interrogative","pending_operation","resume_intent"):
            if data.get(column)=="null": data[column]=None
        return data

    def get(self, key):
        with self.lock: return self._row(self.db.execute("SELECT * FROM efforts WHERE key=?", (key,)).fetchone())

    def list_efforts(self):
        with self.lock: return [dict(r) for r in self.db.execute("SELECT * FROM efforts ORDER BY created_at")]

    def active_count(self):
        with self.lock: return self.db.execute("SELECT count(*) FROM efforts WHERE stage IN (%s)" % ",".join("?"*len(ACTIVE_STAGES)), ACTIVE_STAGES).fetchone()[0]

    def claim(self, key, repo, canonical_repo, global_limit=1, plan_comment_ref=None, plan_excerpt=None):
        now=time.time(); eid=uuid.uuid4().hex
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                existing=self.db.execute("SELECT * FROM efforts WHERE key=?",(key,)).fetchone()
                if existing:
                    if existing["stage"] != "done": raise RuntimeError("ticket already claimed: %s" % key)
                    self.db.execute("DELETE FROM efforts WHERE key=?",(key,))
                count=self.db.execute("SELECT count(*) FROM efforts WHERE stage IN (%s)" % ",".join("?"*len(ACTIVE_STAGES)),ACTIVE_STAGES).fetchone()[0]
                if count >= global_limit: raise RuntimeError("global active limit reached")
                same=self.db.execute("SELECT key FROM efforts WHERE canonical_repo=? AND stage IN (%s)" % ",".join("?"*len(ACTIVE_STAGES)),(canonical_repo,)+ACTIVE_STAGES).fetchone()
                if same: raise RuntimeError("repository already owned by %s" % same[0])
                self.db.execute("INSERT INTO efforts(id,key,repo,canonical_repo,stage,plan_comment_ref,plan_excerpt,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)",(eid,key,repo,canonical_repo,"selected",plan_comment_ref,plan_excerpt,now,now))
                self.db.execute("INSERT INTO journal(effort_id,event,detail,created_at) VALUES(?,?,?,?)",(eid,"claimed",key,now))
                self.db.execute("COMMIT")
                return self.get(key)
            except Exception:
                self.db.execute("ROLLBACK"); raise

    def update(self, key, event=None, detail=None, **fields):
        fields["updated_at"]=time.time()
        if "stage" in fields and fields["stage"] not in STAGES: raise ValueError("invalid stage")
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                if fields:
                    cols=",".join("%s=?"%k for k in fields)
                    vals=[]
                    for k, v in fields.items(): vals.append(json.dumps(v) if k in ("launch_intent", "pending_interrogative", "pending_operation", "resume_intent") and not isinstance(v,str) else v)
                    self.db.execute("UPDATE efforts SET %s WHERE key=?"%cols,vals+[key])
                row=self.db.execute("SELECT id FROM efforts WHERE key=?",(key,)).fetchone()
                if not row: raise KeyError(key)
                if fields.get("session_id"):
                    sid=fields["session_id"]
                    prior=self.db.execute("SELECT session_id FROM session_associations WHERE key=? ORDER BY created_at DESC LIMIT 1",(key,)).fetchone()
                    predecessor=prior[0] if prior and prior[0]!=sid else None
                    stage="recovery" if predecessor else "delivery"
                    known=self.db.execute("SELECT 1 FROM session_associations WHERE key=? AND session_id=?",(key,sid)).fetchone()
                    if not known:
                        self.db.execute("INSERT INTO session_associations(key,session_id,stage,predecessor,created_at) VALUES(?,?,?,?,?)",(key,sid,stage,predecessor,time.time()))
                if event: self.db.execute("INSERT INTO journal(effort_id,event,detail,created_at) VALUES(?,?,?,?)",(row[0],event,detail,time.time()))
                self.db.execute("COMMIT")
            except Exception:
                self.db.execute("ROLLBACK"); raise
        return self.get(key)

    def increment(self,key,counter,event=None,detail=None):
        if counter not in ("launch_attempts","blocker_attempts"): raise ValueError(counter)
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                self.db.execute("UPDATE efforts SET %s=%s+1,updated_at=? WHERE key=?"%(counter,counter),(time.time(),key))
                row=self.db.execute("SELECT id,%s FROM efforts WHERE key=?"%counter,(key,)).fetchone()
                if not row: raise KeyError(key)
                self.db.execute("INSERT INTO journal(effort_id,event,detail,created_at) VALUES(?,?,?,?)",(row[0],event or (counter+"_incremented"),detail,time.time()))
                self.db.execute("COMMIT"); return row[1]
            except Exception: self.db.execute("ROLLBACK"); raise

    def journal(self,key,event,detail=None):
        row=self.get(key)
        with self.lock: self.db.execute("INSERT INTO journal(effort_id,event,detail,created_at) VALUES(?,?,?,?)",(row["id"] if row else None,event,detail,time.time()))

    def resume_claim(self,key,payload,repo=None,global_limit=1):
        """Exclusive, idempotent resume claim; re-applies global + per-repo limits transactionally.

        The claimed stage is `recovery_pending` (an ACTIVE stage) carrying the
        resume operation, so concurrent claims on other tickets observe capacity.
        """
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                row=self.db.execute("SELECT * FROM efforts WHERE key=?",(key,)).fetchone()
                if not row: raise KeyError(key)
                op=row["pending_operation"]
                if isinstance(op,str):
                    try: op=json.loads(op)
                    except ValueError: op=None
                if isinstance(op,dict) and op.get("operation")=="resume" and row["stage"] in ACTIVE_STAGES:
                    self.db.execute("COMMIT"); return self.get(key)
                if row["stage"] not in ("blocked","blocking","recovery_pending","awaiting"):
                    raise RuntimeError("effort %s not resumable from stage %s"%(key,row["stage"]))
                repo=repo or row["canonical_repo"]
                active_rows=self.db.execute("SELECT key,canonical_repo,stage FROM efforts WHERE key!=? AND stage IN (%s)"%",".join("?"*len(ACTIVE_STAGES)),(key,)+ACTIVE_STAGES).fetchall()
                if len(active_rows)>=global_limit:
                    raise RuntimeError("global active limit reached")
                for other in active_rows:
                    if other["canonical_repo"]==repo:
                        raise RuntimeError("repository %s already owned by %s"%(repo,other["key"]))
                pending={"stage":"recovery_pending","operation":"resume","payload":payload}
                now=time.time()
                self.db.execute("UPDATE efforts SET stage='recovery_pending',pending_operation=?,updated_at=? WHERE key=?",(json.dumps(pending),now,key))
                self.db.execute("INSERT INTO journal(effort_id,event,detail,created_at) VALUES((SELECT id FROM efforts WHERE key=?),'resume_claimed',?,?)",(key,str(payload),now))
                self.db.execute("COMMIT")
                return self.get(key)
            except Exception:
                self.db.execute("ROLLBACK"); raise

    def events(self,key=None):
        query="SELECT * FROM journal"; args=()
        if key: query+=" WHERE effort_id=(SELECT id FROM efforts WHERE key=?)"; args=(key,)
        query+=" ORDER BY id"
        with self.lock: return [dict(r) for r in self.db.execute(query,args)]

    def set_control(self,name,value):
        with self.lock: self.db.execute("INSERT INTO controls(name,value,updated_at) VALUES(?,?,?) ON CONFLICT(name) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at",(name,str(value),time.time()))
    def get_control(self,name,default=None):
        with self.lock:
            r=self.db.execute("SELECT value FROM controls WHERE name=?",(name,)).fetchone(); return r[0] if r else default
