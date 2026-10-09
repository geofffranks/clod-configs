#!/usr/bin/env python3
"""Offline native launcher behavior without real Polytoken sessions."""
import json, os, pathlib, subprocess, tempfile
launcher=pathlib.Path(__file__).resolve().with_name('polytoken-native.sh')
with tempfile.TemporaryDirectory(prefix='native launcher ') as td:
 root=pathlib.Path(td); home=root/'home'; home.mkdir(); project=root/'project with spaces'; project.mkdir()
 bin_dir=root/'bin'; bin_dir.mkdir(); binary=bin_dir/'polytoken'; capture=root/'capture.json'
 binary.write_text('#!'+os.sys.executable+'\nimport json,os,sys\nprint(json.dumps({"argv":sys.argv[1:],"cwd":os.getcwd(),"secret":os.environ.get("DISCORD_BOT_TOKEN"),"ambient":os.environ.get("POLYTOKEN_SESSION_ID"),"bin":os.environ.get("BRIDGE_POLYTOKEN_BIN"),"sessions":os.environ.get("BRIDGE_SESSIONS_DIR"),"config":os.environ.get("BRIDGE_CONNECTOR_CONFIG"),"xdg":os.environ.get("XDG_CONFIG_HOME"),"data":os.environ.get("XDG_DATA_HOME")}))\n')
 binary.chmod(0o755)
 (home/'.bash_profile').write_text('touch "$HOME/profile-loaded"\n')
 (home/'.bashrc').write_text('touch "$HOME/rc-loaded"\n')
 env=dict(os.environ,HOME=str(home),POLY_SPAWN_HEADLESS='1',BRIDGE_POLYTOKEN_BIN=str(binary),BRIDGE_SESSIONS_DIR=str(root/'sessions'),BRIDGE_WORKSPACE_ROOT=str(root),DISCORD_BOT_TOKEN='must-not-leak',POLYTOKEN_SESSION_ID='ambient-session')
 result=subprocess.run([str(launcher),'--prompt','spaces $literal;',''],cwd=project,env=env,text=True,capture_output=True)
 assert result.returncode==0,result.stderr
 data=json.loads(result.stdout)
 assert data=={'argv':['new','--sessions-dir',str(root/'sessions'),'--no-attach','--prompt','spaces $literal;',''],'cwd':str(project),'secret':None,'ambient':None,'bin':str(binary),'sessions':str(root/'sessions'),'config':None,'xdg':str(home/'.config'),'data':str(home/'.local/share')},data
 assert result.stderr==''
 assert not (home/'profile-loaded').exists() and not (home/'rc-loaded').exists()
 # Missing trusted roots fails closed before launching anything.
 bad=dict(env); bad.pop('BRIDGE_SESSIONS_DIR'); bad.pop('POLYTOKEN_SESSIONS_DIR',None)
 result=subprocess.run([str(launcher)],cwd=project,env=bad,text=True,capture_output=True)
 assert result.returncode!=0
 # Interactive path retains profile loading and existing polytoken argv semantics.
 env2=dict(os.environ,HOME=str(home),PATH=f'{bin_dir}:'+os.environ.get('PATH',''),POLY_SPAWN_HEADLESS='0')
 result=subprocess.run([str(launcher),'--interactive'],cwd=project,env=env2,text=True,capture_output=True)
 assert result.returncode==0,result.stderr
 data=json.loads(result.stdout)
 assert data['argv']==['--interactive'] and (home/'profile-loaded').exists()
print('PASS: profile-free headless, trusted roots, secret/env scrubbing, exact argv, interactive profiles')
