#!/usr/bin/env python3
"""Named revision-3 offline scenarios: adapter evidence, never model adherence."""
import importlib.util
import pathlib
import unittest
from copy import deepcopy
from hashlib import sha256

spec = importlib.util.spec_from_file_location('fixture', pathlib.Path(__file__).with_name('jira-triage-fixture.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


@unittest.skip('Retired revision-3 policy simulator; use jira-triage-validation.md walkthroughs and effective facet checks')
class Base(unittest.TestCase):
    def setUp(self):
        self.g = m.FakeGateway()
        for op in ('search', 'fetch', 'transitions', 'create', 'close', 'comment', 'edit', 'plan', 'record'):
            self.g.inspect(op)
        self.a = m.DecisionAdapter(self.g)
        self.p = dict(operation='create', project='LAP', type='Process Friction',
                      friction_key='fixture--symptom', evidence='fixture evidence / session-real',
                      fields={'summary': 'Fixture only'}, fresh=True)

    def close(self):
        self.p.update(operation='close', key='LAP-1', status='Plannable',
                      transition=('Plan Complete', 'Done'), verified_resolution=True)

    def refused(self):
        before = deepcopy(self.g.issues)
        writes = len(self.g.writes)
        with self.assertRaises(m.Pending):
            self.a.triage(self.p)
        self.assertEqual(before, self.g.issues)
        self.assertEqual(writes, len(self.g.writes))


class FakeAdapterContract(Base):
    def test_uninspected_and_unauthorized_attempts_recorded(self):
        self.g.inspected.clear()
        for authorized in (False, True):
            with self.assertRaises(m.Pending):
                self.g.call('create', self.p, authorized=authorized)
        self.g.inspect('create')
        with self.assertRaises(m.Pending):
            self.g.call('create', self.p)
        self.assertEqual(3, len(self.g.writes))
        self.assertEqual(1, len(self.g.issues))

    def test_decline_and_no_endpoint_interface(self):
        self.a.confirm(self.p, 'decline')
        self.refused()
        with self.assertRaises(TypeError):
            m.FakeGateway(endpoint='https://production.invalid')


class TriageDedupeCases(Base):
    def test_open_resolved_distinct_and_ambiguous(self):
        for match in ('open-relevant', 'resolved-relevant', 'distinct-root-needs-human', 'ambiguous'):
            with self.subTest(match=match):
                self.g.matches = [match]
                self.a.confirm(self.p, 'confirm-exact')
                self.refused()

    def test_index_lag(self):
        self.g.fault = 'index-lag'
        self.a.confirm(self.p, 'confirm-exact')
        self.refused()

    def test_resolved_evidence_is_nonduplicative_and_preserved(self):
        self.g.issues['LAP-1']['status'] = 'Done'
        self.g.issues['LAP-1']['comments'] = ['old-session']
        self.a.evidence('LAP-1', self.p['evidence'])
        self.a.evidence('LAP-1', self.p['evidence'])
        self.assertEqual(1, len(self.g.writes))
        self.assertEqual(['old-session', self.p['evidence']], self.g.issues['LAP-1']['comments'])
        self.assertEqual('Done', self.g.issues['LAP-1']['status'])


class TriageCreateAuthorizationCases(Base):
    def test_confirm_and_direct_fetch(self):
        self.a.confirm(self.p, 'confirm-exact')
        key = self.a.triage(self.p)
        self.assertEqual('LAP-2', key)
        self.assertEqual(('fetch', {'key': key}), self.g.calls[-1])
        self.refused()

    def test_decline_generic_stale_wrong_scope_changed_fields(self):
        for response in ('decline', 'approve-plan', 'earlier-consent', ''):
            self.a.confirm(self.p, response)
            self.refused()
        for field, value in [('fresh', False), ('project', 'OTHER'), ('type', 'Bug'),
                             ('fields', {'summary': 'changed'})]:
            original = deepcopy(self.p)
            self.a.confirm(self.p, 'confirm-exact')
            self.p[field] = value
            self.refused()
            self.p = original

    def test_timeout_consumes_and_blocks_retry(self):
        self.a.confirm(self.p, 'confirm-exact')
        self.g.fault = 'timeout'
        with self.assertRaises(m.Pending):
            self.a.triage(self.p)
        self.assertEqual(1, len(self.g.writes))
        self.assertEqual(2, len(self.g.issues))
        self.assertIsNone(self.a.confirmation)
        self.g.fault = None
        self.a.confirm(self.p, 'confirm-exact')
        self.refused()

    def test_denied_and_partial_readback_not_success(self):
        for fault in ('denied', 'partial'):
            self.setUp()
            self.a.confirm(self.p, 'confirm-exact')
            self.g.fault = fault
            with self.assertRaises(m.Pending):
                self.a.triage(self.p)
            self.assertFalse(any(event[0] == 'verified' for event in self.a.audit))


class TriageCloseAuthorizationCases(Base):
    def test_confirm_close_and_reuse(self):
        self.close()
        self.a.confirm(self.p, 'confirm-exact')
        self.assertEqual('LAP-1', self.a.triage(self.p))
        self.assertEqual('Done', self.g.issues['LAP-1']['status'])
        self.refused()

    def test_decline_stale_missing_path_unverified_global_done(self):
        for mode in ('decline', 'stale', 'missing', 'unverified', 'global'):
            self.setUp()
            self.close()
            if mode == 'unverified':
                self.p['verified_resolution'] = False
            if mode == 'global':
                self.p['transition'] = ('Done', 'Done')
                self.g.transitions = [('Done', 'Done')]
            self.a.confirm(self.p, 'confirm-exact' if mode != 'decline' else 'decline')
            if mode == 'stale':
                self.g.issues['LAP-1']['status'] = 'Ready'
            if mode == 'missing':
                self.g.transitions = []
            self.refused()


class LifecycleGateCases(Base):
    def test_gates(self):
        self.assertFalse(m.lifecycle('Ready'))
        self.assertTrue(m.lifecycle('Ready', plan=True))
        self.assertFalse(m.lifecycle('Ready', plan=True, correct_state=False))
        self.assertFalse(m.lifecycle('In Progress', plan=True))
        self.assertTrue(m.lifecycle('In Progress', plan=True, start=True))
        evidence = dict(reviewed=True, validated=True, signoff=True, merged=True)
        self.assertTrue(m.lifecycle('Done', **evidence))
        for field in evidence:
            self.assertFalse(m.lifecycle('Done', **dict(evidence, **{field: False})))
        self.assertFalse(m.lifecycle('Ready', plan=True, active=False))
        self.a.active = False
        self.a.confirm(self.p, 'confirm-exact')
        self.refused()


class OccurrenceIdentityCases(Base):
    def test_retry_and_two_events_one_session(self):
        safe = dict(payload=True, serialized=True, history=True)
        first = ('friction-key', 'actual-session', 'event-1')
        second = ('friction-key', 'actual-session', 'event-2')
        records = m.occurrence(set(), first, **safe)
        self.assertEqual(records, m.occurrence(records, first, **safe))
        self.assertEqual(2, len(m.occurrence(records, second, **safe)))


class UnsafeFieldPendingCases(Base):
    def test_unknown_payload_history_concurrency_or_identity(self):
        safe = dict(payload=True, serialized=True, history=True)
        for field in safe:
            with self.assertRaises(m.Pending):
                m.occurrence(set(), ('key', 'session', 'event'), **dict(safe, **{field: False}))
        with self.assertRaises(m.Pending):
            m.occurrence(set(), ('key', '', 'event'), **safe)
        self.assertEqual([], self.g.writes)


class PlanRoundTripCases(Base):
    def test_exact_bytes_fresh_reader_and_failures(self):
        identity = ('LAP-1', 'scope', 'main', 'source-sha', 3)
        data = 'Exact bytes\r\nUnicode: café\n'.encode()
        digest = sha256(data).hexdigest()
        self.g.call('plan', {'identity': identity, 'bytes': data}, authorized=True)
        self.assertEqual(data, m.fetch_plan(self.g, identity, digest))
        with self.assertRaises(KeyError):
            m.fetch_plan(self.g, identity[:-1] + (2,), digest)
        self.g.records[identity] += b'changed'
        with self.assertRaises(m.Pending):
            m.fetch_plan(self.g, identity, digest)
        self.g.fault = 'denied'
        with self.assertRaises(m.Pending):
            m.fetch_plan(self.g, identity, digest)


class TriageNegativeMutationCase(Base):
    def test_unconfirmed_create_close_zero_attempts(self):
        self.refused()
        self.close()
        self.refused()
        self.assertEqual([], self.g.writes)
        self.assertEqual('Plannable', self.g.issues['LAP-1']['status'])
        print('TriageNegativeMutationCase: attempted writes=0; state unchanged')


if __name__ == '__main__':
    unittest.main(verbosity=2)
