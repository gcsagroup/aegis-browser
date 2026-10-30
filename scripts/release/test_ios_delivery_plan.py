import importlib.util
from pathlib import Path
import unittest

FILE = Path(__file__).with_name('ios-delivery-plan.py')
spec = importlib.util.spec_from_file_location('ios_delivery_plan', FILE)
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)


class DeliveryPlanTests(unittest.TestCase):
    def plan(self, inputs=None, event='workflow_dispatch', ref='refs/heads/main'):
        return planner.normalize(event, ref, inputs if inputs is not None else dict(version='1.0.0', build='33'))

    def token(self, profile='alpha', state='100', attempt='1', digest='a'*64):
        return planner.receipt.encode(profile, '1.0.0', '33', '100', state, attempt, digest)

    def store(self, **changes):
        return dict(operation='upload', source=self.token()) | changes

    def test_default_package_needs_only_version_and_build_and_never_uploads(self):
        plan = self.plan()
        self.assertEqual([plan[k] for k in ['operation', 'profile', 'destination', 'tag']],
                         ['package', 'alpha', 'artifacts', ''])
        self.assertFalse(any(plan[k] for k in ['package_run_id', 'upload_run_id', 'source_attempt', 'manifest_sha256']))

    def test_package_draft_and_store_routes_for_each_audience(self):
        for profile in ['alpha', 'beta', 'release']:
            for operation in ['package', 'draft']:
                plan = self.plan(dict(operation=operation, version='1.0.0', build='33', profile=profile))
                self.assertEqual(plan['operation'], 'package')
                self.assertEqual(plan['destination'], 'github-draft' if operation == 'draft' else 'artifacts')
                self.assertEqual(plan['tag'], 'candidate/ios/1.0.0-'+profile+'.33' if operation == 'draft' else '')
            for stage in ['upload', 'wait', 'status', 'metadata', 'compliance']:
                plan = self.plan(dict(operation=stage, source=self.token(profile, state='101')))
                self.assertEqual([plan[k] for k in ['profile', 'version', 'build', 'destination']],
                                 [profile, '1.0.0', '33', 'testflight'])
            for route in ['internal', 'external']:
                inputs = dict(operation='distribute-'+route, source=self.token(profile, state='101'), groups='Aegis Early access')
                if profile == 'alpha' and route == 'external':
                    with self.assertRaises(ValueError):
                        self.plan(inputs)
                else:
                    plan = self.plan(inputs)
                    self.assertEqual([plan[k] for k in ['operation', 'destination', 'groups']],
                                     ['distribute', 'testflight-'+route, 'Aegis Early access'])

    def test_receipt_keeps_independent_digest_original_run_and_exact_state_attempt(self):
        plan = self.plan(self.store(source=self.token('beta', state='123', attempt='3'), profile='auto'))
        self.assertEqual([plan[k] for k in ['package_run_id', 'upload_run_id', 'source_attempt', 'manifest_sha256']],
                         ['100', '123', '3', 'a'*64])
        self.assertEqual(self.plan(self.store())['upload_run_id'], '')
        self.assertEqual(self.plan(self.store(profile='alpha', version='1.0.0', build='33'))['profile'], 'alpha')
        for changes in [dict(profile='beta'), dict(version='2.0.0'), dict(build='34')]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.plan(self.store(**changes))

    def test_tag_derives_identity_and_only_packages_private_draft(self):
        for profile in ['alpha', 'beta', 'release']:
            plan = self.plan({}, event='push', ref='refs/tags/candidate/ios/1.0.0-'+profile+'.33')
            self.assertEqual([plan[k] for k in ['operation', 'profile', 'version', 'build', 'destination']],
                             ['package', profile, '1.0.0', '33', 'github-draft'])
        for ref in ['refs/heads/main', 'refs/tags/v1.0.0', 'refs/tags/candidate/ios/1.0.0-release.0',
                    'refs/tags/candidate/ios/1.0.0-release.33\n', 'refs/tags/candidate/ios/'+('1'*100)+'.0-alpha.33']:
            with self.assertRaises(ValueError):
                self.plan({}, event='push', ref=ref)
        with self.assertRaises(ValueError):
            self.plan({'profile': 'beta'}, event='push', ref='refs/tags/candidate/ios/1.0.0-alpha.33')

    def test_malformed_receipts_and_legacy_partial_fields_fail_before_protected_jobs(self):
        token = self.token()
        cases = ['', token+'\n', token+' ', token.upper(), token.replace(':100:', ':0:', 1),
                 token.replace(':100:', ':01:', 1), token.replace(':1:', ':0:', 1), token[:-1],
                 token.replace('aegis-ios-v1', 'aegis-ios-v2'), 'x'*257, token+':extra',
                 token.replace(':alpha:', ':unknown:'), token.replace(':1.0.0:', ':1.0.0.0:')]
        for source in cases:
            with self.subTest(source=source), self.assertRaises(ValueError):
                self.plan(self.store(source=source))
        for name in ['destination', 'tag', 'package_run_id', 'upload_run_id', 'source_attempt', 'manifest_sha256', 'unknown']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.plan(self.store(**{name: 'x'}))

    def test_cross_route_inputs_and_unuploaded_later_mutations_are_rejected(self):
        cases = [dict(version='1.0.0', build='0'), dict(version='1.0.0\n', build='33'),
                 dict(version='1.0.0', build='33', operation='submit'),
                 dict(version='1.0.0', build='33', profile='unknown'),
                 dict(version='1.0.0', build='33', source=self.token()),
                 dict(version='1.0.0', build='33', groups='group'),
                 self.store(groups='group'), self.store(stage_input='{"x":true}')]
        for stage in ['metadata', 'compliance', 'distribute-internal']:
            cases.append(self.store(operation=stage))
        for inputs in cases:
            with self.subTest(inputs=inputs), self.assertRaises(ValueError):
                self.plan(inputs)
        for groups in ['', 'group,group', 'group\nx', 'x'*101]:
            with self.assertRaises(ValueError):
                self.plan(dict(operation='distribute-internal', source=self.token(state='101'), groups=groups))

    def test_metadata_json_is_bounded_object_and_cannot_inject_outputs(self):
        inputs = self.store(operation='metadata', source=self.token(state='101'), stage_input='{"text":"line1\\nline2"}')
        self.assertNotIn('\n', self.plan(inputs)['stage_input'])
        for value in ['[]', 'null', '{', '{"text":"'+('x'*64001)+'"}']:
            inputs['stage_input'] = value
            with self.assertRaises(ValueError):
                self.plan(inputs)
        with self.assertRaises(ValueError):
            self.plan(event='pull_request')
        with self.assertRaises(ValueError):
            self.plan(ref='refs/heads/foreign')


if __name__ == '__main__':
    unittest.main()
