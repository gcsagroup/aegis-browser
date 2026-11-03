import importlib.util
import json
from pathlib import Path
import unittest

FILE = Path(__file__).with_name('ios-delivery-plan.py')
spec = importlib.util.spec_from_file_location('ios_delivery_plan', FILE)
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)


class DeliveryPlanTests(unittest.TestCase):
    def plan(self, inputs=None, event='workflow_dispatch', ref='refs/heads/main'):
        return planner._normalize_stage(event, ref, inputs if inputs is not None else dict(version='1.0.0(33)'))

    def token(self, profile='alpha', state='100', attempt='1', digest='a'*64):
        return planner.receipt.encode(profile, '1.0.0', '33', '100', state, attempt, digest)

    def store(self, **changes):
        return dict(operation='upload', source=self.token()) | changes

    def test_default_package_needs_one_combined_version_and_never_uploads(self):
        plan = self.plan()
        self.assertEqual([plan[k] for k in ['operation', 'profile', 'destination', 'tag']],
                         ['package', 'alpha', 'artifacts', ''])
        self.assertFalse(any(plan[k] for k in ['package_run_id', 'upload_run_id', 'source_attempt', 'manifest_sha256']))

    def test_package_draft_and_store_routes_for_each_audience(self):
        for profile in ['alpha', 'beta', 'release']:
            for operation in ['package', 'draft']:
                plan = self.plan(dict(operation=operation, version='1.0.0(33)', product=profile))
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
        plan = self.plan(self.store(source=self.token('beta', state='123', attempt='3'), product='auto'))
        self.assertEqual([plan[k] for k in ['package_run_id', 'upload_run_id', 'source_attempt', 'manifest_sha256']],
                         ['100', '123', '3', 'a'*64])
        self.assertEqual(self.plan(self.store())['upload_run_id'], '')
        self.assertEqual(self.plan(self.store(product='alpha', version='1.0.0(33)'))['profile'], 'alpha')
        for changes in [dict(product='beta'), dict(version='2.0.0(33)'), dict(version='1.0.0(34)')]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.plan(self.store(**changes))

    def test_display_labels_and_operation_ids_have_identical_guards(self):
        for product, labels in planner.receipt.PRODUCT_LABELS.items():
            expected = 'alpha' if product == 'auto' else product
            for label in labels:
                self.assertEqual(self.plan(dict(version='1.0.0(33)', product=label))['profile'], expected)
        for operation, labels in planner.receipt.OPERATION_LABELS.items():
            inputs = dict(version='1.0.0(33)') if operation in {'package', 'draft'} else dict(source=self.token('beta', state='101'))
            if operation.startswith('distribute-'):
                inputs['groups'] = 'Aegis Early access'
            for label in labels:
                self.assertEqual(self.plan(dict(inputs, operation=label)), self.plan(dict(inputs, operation=operation)))
        for label in planner.receipt.OPERATION_LABELS['distribute-external']:
            with self.assertRaises(ValueError):
                self.plan(dict(operation=label, source=self.token(state='101'), groups='group'))

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
        for name in ['destination', 'tag', 'package_run_id', 'upload_run_id', 'source_attempt', 'manifest_sha256', 'profile', 'build', 'unknown']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.plan(self.store(**{name: 'x'}))

    def test_cross_route_inputs_and_unuploaded_later_mutations_are_rejected(self):
        cases = [dict(version='1.0.0(0)'), dict(version='1.0.0(33)\n'),
                 dict(version='1.0.0'), dict(version='1.0.0(33) ', operation='package'),
                 dict(version='1.0.0(33)', operation='submit'),
                 dict(version='1.0.0(33)', product='unknown'),
                 dict(version='1.0.0(33)', source=self.token()),
                 dict(version='1.0.0(33)', groups='group'),
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


class SimpleFullFormTests(unittest.TestCase):
    def token(self, profile='alpha', state='100', attempt='1', digest='a'*64):
        return planner.receipt.encode(profile, '1.0.0', '33', '100', state, attempt, digest)

    def form(self, mode='simple', **inputs):
        return planner.normalize('workflow_dispatch', 'refs/heads/main', inputs, mode)

    def test_status_uses_exact_version_build_without_any_package_provenance(self):
        for mode in ['simple', 'full']:
            for profile in ['Auto', 'Alpha', 'Beta', 'Release']:
                value = self.form(mode, operation='Status', version='1.0.0', build='35', product=profile)
                self.assertEqual((value['operation'], value['version'], value['build']), ('status-query', '1.0.0', '35'))
                for field in ['profile', 'package_run_id', 'upload_run_id', 'source_attempt', 'manifest_sha256']:
                    self.assertEqual(value[field], '', 'Status cannot invent package provenance')

    def test_simple_package_remains_package_only_with_explicit_product(self):
        for profile in ['alpha', 'beta', 'release']:
            value = self.form(operation='package', product=profile, version='1.0.0', build='36')
            self.assertEqual((value['operation'], value['profile'], value['destination']), ('package', profile, 'artifacts'))

    def test_new_package_upload_has_no_external_source_and_wait_is_read_only(self):
        for mode in ['simple', 'full']:
            value = self.form(mode, operation='package-upload', version='1.0.0', build='36', product='beta')
            self.assertEqual((value['operation'], value['profile'], value['destination']), ('package-upload', 'beta', 'testflight'))
            self.assertFalse(value['package_run_id'] or value['manifest_sha256'])
            wait = self.form(mode, operation='wait', version='1.0.0', build='35')
            self.assertEqual(wait['operation'], 'status-wait')
            for extra in [dict(source=self.token()), dict(groups='group'), dict(stage_input='{"x":1}')]:
                with self.assertRaises(ValueError):
                    self.form('full', operation='package-upload', version='1.0.0', build='36', **extra)

    def test_same_run_uploaded_receipt_keeps_completed_state_distinct_from_package_only(self):
        before = planner.receipt.encode('alpha', '1.0.0', '36', 100, 100, 1, 'a'*64)
        after = planner.receipt.encode('alpha', '1.0.0', '36', 100, 100, 1, 'a'*64, uploaded=True)
        self.assertEqual(planner.receipt.decode(before)['upload_run_id'], '')
        self.assertEqual(planner.receipt.decode(after)['upload_run_id'], '100')
        value = self.form('full', operation='metadata', source=after)
        self.assertEqual((value['package_run_id'], value['upload_run_id'], value['manifest_sha256']), ('100', '100', 'a'*64))
        for bad in [after.replace(':uploaded', ':unknown'), after.replace(':100:100:', ':100:101:'), after.replace(':uploaded', '')]:
            with self.assertRaises(ValueError):
                planner.receipt.decode(bad)

    def test_missing_or_malicious_identity_is_rejected_before_credentials(self):
        for changes in [dict(version=''), dict(build=''), dict(version='1.0.0(35)'), dict(version='1.0.0\n'),
                        dict(build='01'), dict(build='0'), dict(build='1;uname'), dict(version='$(id)'), dict(build='1'*11)]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.form(**(dict(operation='status', version='1.0.0', build='35') | changes))

    def test_version_build_never_authorizes_upload_or_later_mutation(self):
        for mode in ['simple', 'full']:
            for op in ['upload', 'metadata', 'compliance', 'distribute-internal', 'distribute-external']:
                with self.subTest(mode=mode, op=op), self.assertRaises(ValueError):
                    self.form(mode, operation=op, version='1.0.0', build='35')

    def test_full_mode_pins_original_package_and_state_for_all_mutations(self):
        for operation in ['upload', 'wait', 'metadata', 'compliance', 'distribute-internal', 'distribute-external']:
            fields = dict(operation=operation, source=self.token('beta', state='123', attempt='3'))
            if operation.startswith('distribute-'):
                fields['groups'] = 'Existing group'
            if operation in ['metadata', 'compliance']:
                fields['stage_input'] = '{"authorization":"reviewed"}'
            value = self.form('full', **fields)
            self.assertEqual([value[x] for x in ['package_run_id', 'upload_run_id', 'source_attempt', 'manifest_sha256']],
                             ['100', '123', '3', 'a'*64])
            with self.assertRaises(ValueError):
                self.form('full', **(fields | dict(build='34', version='1.0.0')))
        with self.assertRaises(ValueError):
            self.form('full', operation='distribute-external', source=self.token('alpha', state='123'), groups='group')

    def test_status_cannot_smuggle_state_or_stage_configuration(self):
        for extra in [dict(source=self.token()), dict(groups='group'), dict(stage_input='{"usesNonExemptEncryption":false}')]:
            with self.assertRaises(ValueError):
                self.form('full', operation='status', version='1.0.0', build='35', **extra)

    def test_full_json_and_both_entrypoint_boundaries_are_strict(self):
        for raw in ['[]', 'null', '{', '{"x":1,"x":2}', '{"x":NaN}', ' '*64001]:
            with self.assertRaises(ValueError):
                self.form('full', operation='metadata', source=self.token(state='123'), stage_input=raw)
        for mode in ['unknown', 'Simple']:
            with self.assertRaises(ValueError):
                self.form(mode, version='1.0.0', build='35')
        for event, ref in [('pull_request', 'refs/heads/main'), ('workflow_dispatch', 'refs/heads/foreign')]:
            with self.assertRaises(ValueError):
                planner.normalize(event, ref, dict(version='1.0.0', build='35'))
        for profile in ['alpha', 'beta', 'release']:
            value = planner.normalize('push', f'refs/tags/candidate/ios/1.0.0-{profile}.36', {})
            self.assertEqual((value['operation'], value['profile'], value['destination']), ('package', profile, 'github-draft'))
        with self.assertRaises(ValueError):
            planner.normalize('push', 'refs/tags/candidate/ios/1.0.0-alpha.36', {}, 'full')


if __name__ == '__main__':
    unittest.main()
