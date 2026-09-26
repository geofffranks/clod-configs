"""Offline validation support, NOT a production gateway or agent-policy engine.

RETIRED: the revision-3 decision adapter below is historical, not current policy
or the facet runtime. Its create-confirmation and digest gates are superseded by
jira-workflow. Do not use it as validation evidence; see jira-triage-validation.md.
No endpoint, network, process or filesystem interface exists in this module.
"""
from copy import deepcopy
from hashlib import sha256


class Pending(Exception):
    pass


class FakeGateway:
    def __init__(self):
        self.issues = {'LAP-1': {'status': 'Plannable', 'project': 'LAP',
                               'type': 'Process Friction', 'comments': []}}
        self.transitions = [('Plan Complete', 'Done')]
        self.inspected = set()
        self.calls = []
        self.writes = []
        self.fault = None
        self.matches = []
        self.records = {}

    def inspect(self, operation):
        self.inspected.add(operation)

    def call(self, operation, payload=None, authorized=False):
        payload = deepcopy(payload or {})
        write = operation in {'create', 'close', 'comment', 'edit', 'plan'}
        self.calls.append((operation, payload))
        if write:
            self.writes.append((operation, payload))
        if operation not in self.inspected or (write and not authorized):
            raise Pending('uninspected or unauthorized fake call')
        if self.fault == 'denied':
            raise Pending('denied')
        if operation == 'search':
            if self.fault == 'index-lag':
                raise Pending('incomplete index')
            return deepcopy(self.matches)
        if operation == 'fetch':
            if self.fault == 'partial':
                return {}
            return deepcopy(self.issues[payload['key']])
        if operation == 'transitions':
            return deepcopy(self.transitions)
        if operation == 'create':
            key = 'LAP-' + str(len(self.issues) + 1)
            self.issues[key] = dict(payload, status='Plannable', comments=[])
            answer = key
        elif operation == 'close':
            self.issues[payload['key']]['status'] = payload['transition'][1]
            answer = payload['key']
        elif operation == 'comment':
            self.issues[payload['key']]['comments'].append(payload['evidence'])
            answer = payload['key']
        elif operation == 'edit':
            self.issues[payload['key']].update(payload['fields'])
            answer = payload['key']
        elif operation == 'plan':
            self.records[payload['identity']] = payload['bytes']
            answer = payload['identity']
        elif operation == 'record':
            return self.records[payload['identity']]
        else:
            raise Pending('unknown fake operation')
        if self.fault == 'timeout':
            raise Pending('uncertain outcome after mutation')
        return answer


class DecisionAdapter:
    """Scripted fixture decisions; does not load or execute Markdown prompts."""
    def __init__(self, gateway):
        self.gateway = gateway
        self.active = True
        self.confirmation = None
        self.uncertain = False
        self.audit = []

    def confirm(self, proposal, response):
        self.confirmation = deepcopy(proposal) if response == 'confirm-exact' else None

    def triage(self, proposal):
        g = self.gateway
        if not self.active or self.uncertain:
            raise Pending('inactive or unreconciled')
        if proposal['project'] != 'LAP' or proposal['type'] != 'Process Friction':
            raise Pending('outside scope')
        op = proposal['operation']
        if op == 'create':
            matches = g.call('search')
            if matches:
                raise Pending('match requires evidence or human disposition')
        elif op == 'close':
            issue = g.call('fetch', {'key': proposal['key']})
            if any(issue.get(k) != proposal[k] for k in ('status', 'project', 'type')):
                raise Pending('stale state or scope')
            if (not proposal.get('verified_resolution') or
                    proposal['transition'] not in g.call('transitions') or
                    proposal['transition'][0] == 'Done'):
                raise Pending('missing intended path or resolution')
        else:
            raise Pending('unsupported triage operation')
        if not proposal.get('fresh') or self.confirmation != proposal:
            raise Pending('missing, stale or changed confirmation')
        self.confirmation = None
        self.audit.append(('consumed', deepcopy(proposal)))
        try:
            key = g.call(op, proposal, authorized=True)
            actual = g.call('fetch', {'key': key})
            expected = 'Plannable' if op == 'create' else proposal['transition'][1]
            if actual.get('status') != expected:
                raise Pending('partial readback')
            self.audit.append(('verified', key))
            return key
        except Pending:
            self.uncertain = True
            raise

    def evidence(self, key, evidence):
        if not self.active:
            raise Pending('inactive')
        issue = self.gateway.call('fetch', {'key': key})
        if issue.get('project') != 'LAP' or issue.get('type') != 'Process Friction':
            raise Pending('outside scope')
        if evidence not in issue['comments']:
            self.gateway.call('comment', {'key': key, 'evidence': evidence}, authorized=True)
        if evidence not in self.gateway.call('fetch', {'key': key}).get('comments', []):
            raise Pending('comment readback')


def lifecycle(destination, *, active=True, correct_state=True, plan=False,
              start=False, reviewed=False, validated=False, signoff=False, merged=False):
    return active and correct_state and {
        'Ready': plan, 'In Progress': plan and start,
        'Done': reviewed and validated and signoff and merged,
    }.get(destination, False)


def occurrence(records, identity, *, payload=False, serialized=False, history=False):
    if not all(identity) or not (payload and serialized and history):
        raise Pending('unsafe attribution/count update')
    return records | {identity}


def fetch_plan(gateway, identity, digest):
    data = gateway.call('record', {'identity': identity})
    if sha256(data).hexdigest() != digest:
        raise Pending('plan bytes changed')
    return data
