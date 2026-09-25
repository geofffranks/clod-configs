"""LAP-94 lexical source lint, not a prompt-policy simulator."""
import pathlib
import re
import subprocess
import sys
import tempfile

# Explicit root/file inventory; recursive entries include non-ignored new files.
GLOBAL = ('polytoken/AGENTS.md', 'polytoken/facets/', 'polytoken/subagents/',
          'home/CLAUDE.md', 'home/skills/', 'polytoken/hooks/container-awareness.sh')
TDC = ('AGENTS.md', 'AI-EXPERTS.md', '.polytoken/facet-templates/',
       '.polytoken/subagent-templates/', '.polytoken/skills/')
LEGACY = re.compile(r'github\s+projects?\b|\bgh\s+project\b|\bherdle\b|\bproject\s*#1\b', re.I)
# Exact line exceptions: changes require review, not a broad path/keyword bypass.
EXCEPTIONS = {
    ('global', 'polytoken/hooks/container-awareness.sh'):
        {"- The herdle lifecycle gatekeeper builds from source on first use (no prebuilt binary in the container). Lifecycle gates ARE enforced; the first gated tool call in a session takes a few seconds to compile, then the cached binary is near-instant.' \\"},
    ('global', 'home/skills/jira-workflow/SKILL.md'):
        {'The retained dcs-retribution herdle workflow is an explicit repository exception;'},
    # Reviewed TDC archive notices; exact wording denies live archive authority.
    ('tdc', 'AI-EXPERTS.md'):
        {'GitHub Project #1 is a frozen, read-only historical archive; Jira is authoritative.'},
    ('tdc', '.polytoken/skills/github-project-backlog/SKILL.md'):
        {'GitHub Project #1 is a frozen, read-only historical archive; Jira is authoritative.'},
}


def violations(kind, path, text):
    allowed = EXCEPTIONS.get((kind, path), set())
    return [(n, line) for n, line in enumerate(text.splitlines(), 1)
            if LEGACY.search(line) and line not in allowed]


def fixtures():
    # Test detection and narrow exception boundaries, not agent decisions.
    bad = ['GitHub Projects is current authority.', 'Plan with herdle.',
           'Use gh project item-create.', 'Sync Project #1.',
           'dcs-retribution exists; use herdle for every repository.',
           'Archive: GitHub Project is now the current authority.']
    for text in bad:
        if not violations('global', 'polytoken/facets/product-design.md', text):
            raise RuntimeError('negative fixture falsely passed: ' + text)
    for (kind, path), lines in EXCEPTIONS.items():
        for line in lines:
            if violations(kind, path, line):
                raise RuntimeError('positive fixture rejected: ' + line)
            if not violations(kind, path, line + ' Plan with herdle everywhere.'):
                raise RuntimeError('modified exception falsely passed')
            if not violations(kind, 'unreviewed.md', line):
                raise RuntimeError('exception leaked to another path')
    if violations('global', 'active.md', 'Jira is authoritative; GitHub PR review is separate.'):
        raise RuntimeError('unrelated GitHub fixture rejected')
    with tempfile.TemporaryDirectory(prefix='jira-source-lint-') as directory:
        root = pathlib.Path(directory)
        subprocess.run(['git', 'init', '--quiet', str(root)], check=True)
        source = root / '.polytoken/skills/new/SKILL.md'
        source.parent.mkdir(parents=True)
        source.write_text('GitHub Projects is current authority.\n')
        failures = scan(root, 'tdc', ('.polytoken/skills/',))
        if len(failures) != 1 or 'new/SKILL.md' not in failures[0]:
            raise RuntimeError('untracked policy source escaped inventory')
    print('PASS: negative, archive, runtime, dcs-retribution, exception-isolation and untracked-source fixtures')


def scan(root, kind, inventory):
    tracked = set(subprocess.check_output(
        ['git', '-C', str(root), 'ls-files', '--cached', '--others',
         '--exclude-standard', '-z'], text=True).split('\0'))
    selected = set()
    for entry in inventory:
        matches = {p for p in tracked if p.startswith(entry)} if entry.endswith('/') else {entry}
        if not matches or any(not (root / p).is_file() for p in matches):
            raise RuntimeError('missing inventory source: ' + str(root / entry))
        selected.update(matches)
    # New canonical skill is intentionally checked before it has been staged.
    if kind == 'global':
        selected.add('home/skills/jira-workflow/SKILL.md')
    failures = []
    for path in sorted(selected):
        for n, line in violations(kind, path, (root / path).read_text()):
            failures.append(f'{kind}:{path}:{n}: unreviewed legacy reference: {line}')
    print(f'{kind}: scanned {len(selected)} policy sources')
    return failures


def main():
    if len(sys.argv) not in (2, 3):
        raise RuntimeError('usage: test-jira-workflow-contracts.sh [TDC_ROOT]')
    fixtures()
    failures = scan(pathlib.Path(sys.argv[1]), 'global', GLOBAL)
    if len(sys.argv) == 3:
        failures += scan(pathlib.Path(sys.argv[2]), 'tdc', TDC)
    else:
        print('NOT RUN: TDC inventory (supply its worktree root for integrated check)')
    if failures:
        print('\n'.join(failures), file=sys.stderr)
        return 1
    print('PASS: source lint (not model adherence or runtime proof)')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        sys.exit(2)
