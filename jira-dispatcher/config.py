"""Configuration for the local Jira dispatcher."""
import copy
import json
import os

DEFAULTS = {
    "active": False,
    "gateway_url": "http://127.0.0.1:8910/mcp",
    "jira_project": "LAP",
    "custom_project_field": "customfield_10043",
    "agent_sessions_field": "customfield_10048",
    "repo_mappings": {
        "lappie": {"repo_path": "/Users/gfranks/workspace/lappie"},
        "appium-mcp": {"repo_path": "/Users/gfranks/workspace/appium-mcp"},
    },
    "allowed_types": ["Story", "Bug", "Task", "AI Workflow"],
    "max_global_active": 1,
    "launch_poll_interval_seconds": 300,
    "launch_timeout_seconds": 3600,
    "transient_retry_cap": 3,
    "max_blocker_attempts": 3,
    "question_grace_polls": 0,
    "transition_names": {
        "plannable_to_ready": ["Approve Plan"],
        "plannable_to_inprogress": ["Approve + Start Interactive Implementation"],
        "ready_to_inprogress": [],
        "block": ["Block"],
        "blocker_to_ready": ["Unblock"],
        "inprogress_to_awaiting": ["Implementation Complete"],
    },
}
_FORBIDDEN = {"Process Friction", "Epic", "Subtask"}

class ConfigError(ValueError):
    pass

def validate(config, check_paths=True):
    if not isinstance(config, dict): raise ConfigError("configuration must be a JSON object")
    result = copy.deepcopy(DEFAULTS)
    result.update(config)
    if "transition_names" in config:
        if not isinstance(config["transition_names"], dict): raise ConfigError("transition_names must be an object")
        result["transition_names"].update(config["transition_names"])
    if not isinstance(result["active"], bool): raise ConfigError("active must be boolean")
    for key in ("gateway_url", "jira_project", "custom_project_field", "agent_sessions_field"):
        if not isinstance(result[key], str) or not result[key]: raise ConfigError("%s must be a non-empty string" % key)
    for key in ("max_global_active", "launch_poll_interval_seconds", "launch_timeout_seconds", "transient_retry_cap", "max_blocker_attempts"):
        if not isinstance(result[key], int) or isinstance(result[key], bool) or result[key] < 1: raise ConfigError("%s must be a positive integer" % key)
    if not isinstance(result["question_grace_polls"], int) or isinstance(result["question_grace_polls"], bool) or result["question_grace_polls"] < 0: raise ConfigError("question_grace_polls must be a non-negative integer")
    names=result["transition_names"]
    required=set(DEFAULTS["transition_names"])
    if set(names) != required or any(not isinstance(v,list) or any(not isinstance(x,str) or not x for x in v) for v in names.values()): raise ConfigError("transition_names must map each lifecycle path to a list of non-empty names")
    types=result.get("allowed_types")
    if not isinstance(types,list) or not types or any(not isinstance(t,str) for t in types): raise ConfigError("allowed_types must be a non-empty list of names")
    if _FORBIDDEN.intersection(types): raise ConfigError("forbidden issue types cannot be allowed")
    if any(t not in ("Story", "Bug", "Task", "AI Workflow") for t in types): raise ConfigError("allowed_types contains an unsupported issue type")
    mappings=result.get("repo_mappings")
    if not isinstance(mappings,dict) or not mappings: raise ConfigError("repo_mappings must be a non-empty object")
    for name,item in mappings.items():
        if not isinstance(item,dict) or not isinstance(item.get("repo_path"),str): raise ConfigError("repo mapping %r requires repo_path" % name)
        path=os.path.realpath(os.path.expanduser(item["repo_path"]))
        if check_paths and not os.path.isdir(path): raise ConfigError("repository path does not exist: %s" % path)
        item["repo_path"]=path
    return result

def load(path, check_paths=True):
    try:
        with open(path, encoding="utf-8") as f: data=json.load(f)
    except (OSError, ValueError) as exc: raise ConfigError("cannot load config %s: %s" % (path, exc)) from exc
    return validate(data, check_paths=check_paths)

def write_default(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "x", encoding="utf-8") as f: json.dump(DEFAULTS, f, indent=2); f.write("\n")
    return path
