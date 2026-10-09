#!/usr/bin/env python3
"""Controlled Bash startup fixtures; no real Polytoken session is launched."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

launcher = Path(__file__).resolve().with_name("polytoken-native.sh")
with tempfile.TemporaryDirectory(prefix="polytoken-native-") as root:
    home = Path(root)
    work = home / "project with spaces"
    work.mkdir()
    bin_dir = home / "bin"
    bin_dir.mkdir()
    cli = bin_dir / "polytoken"
    cli.write_text("#!/usr/bin/env python3\nimport json,os,sys\nprint(json.dumps({'cwd':os.getcwd(),'args':sys.argv[1:],'rc':os.environ.get('RC_COUNT'),'login':os.environ.get('LOGIN_OK')}))\n")
    cli.chmod(0o755)
    (home / ".bashrc").write_text('export RC_COUNT=$(( ${RC_COUNT:-0} + 1 ))\nexport PATH="$HOME/bin:$PATH"\ncd /\n')
    args = ["--prompt", "spaces ' quotes $literal;", "", "*.md"]
    for sources_rc in (False, True):
        profile = 'shopt -q login_shell && export LOGIN_OK=yes\nset -- startup changed args\ncd /\n'
        if sources_rc:
            profile += 'source "$HOME/.bashrc"\n'
        (home / ".bash_profile").write_text(profile)
        for headless in (False, True):
            env = dict(os.environ, HOME=str(home), POLY_SPAWN_HEADLESS="1" if headless else "0")
            env.pop("RC_COUNT", None)
            proc = subprocess.run([str(launcher), *args], cwd=work, env=env, text=True, capture_output=True)
            assert proc.returncode == 0, proc.stderr
            observed = json.loads(proc.stdout)
            assert observed == {"cwd": str(work), "args": (["new", "--no-attach"] if headless else []) + args, "rc": "1", "login": "yes"}, observed
            assert not proc.stderr, proc.stderr
    # Bash reads only the first available user login profile.
    (home / ".bash_profile").unlink()
    for name in (".bash_login", ".profile"):
        (home / name).write_text('shopt -q login_shell && export LOGIN_OK=yes\n')
        proc = subprocess.run([str(launcher), *args], cwd=work, env=env, text=True, capture_output=True)
        assert proc.returncode == 0, proc.stderr
        observed = json.loads(proc.stdout)
        assert observed["login"] == "yes" and observed["rc"] == "1", observed
        (home / name).unlink()
    cli.write_text("#!/usr/bin/env bash\nexit 37\n")
    proc = subprocess.run([str(launcher)], cwd=work, env=env, capture_output=True)
    assert proc.returncode == 37, proc.returncode
print("PASS: login state, rc once, cwd, exact argv, manual/headless dispatch and exit status")
