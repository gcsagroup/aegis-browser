import importlib.util
from pathlib import Path
import unittest

FILE = Path(__file__).with_name('ios-delivery-plan.py')


class DeliveryPlanTests(unittest.TestCase):
    def plan(self, inputs=None, event='workflow_dispatch', ref='refs/heads/main'):
        self.assertTrue(FILE.exists(), 'unified delivery planner missing')
        spec = importlib.util.spec_from_file_location('ios_delivery_plan', FILE)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.normalize(event, ref, inputs if inputs is not None else dict(version='1.0.0', build='29'))

    def store(self, **changes):
        return dict(operation='upload', version='1.0.0', build='29', package_run_id='100',
                    source_attempt='1', manifest_sha256='a'*64) | changes

    def test_default_package_is_alpha_artifact_without_store_state(self):
        plan = self.plan()
        self.assertEqual([plan[k] for k in ['operation', 'profile', 'destination', 'tag']],
                         ['package', 'alpha', 'artifacts', ''])
        self.assertEqual(plan['package_run_id'], '')

    def test_package_and_store_routes_for_each_audience(self):
        for profile in ['alpha', 'beta', 'release']:
            for destination in ['artifacts', 'github-draft']:
                inputs = dict(version='1.0.0', build='29', profile=profile, destination=destination)
                if destination == 'github-draft':
                    inputs['tag'] = 'candidate/ios/1.0.0-'+profile+'.29'
                self.assertEqual(self.plan(inputs)['destination'], destination)
            for stage in ['upload', 'status', 'wait', 'metadata', 'compliance']:
                inputs = self.store(profile=profile)
                inputs['operation'] = stage
                if stage in ['metadata', 'compliance']:
                    inputs['upload_run_id'] = '101'
                self.assertEqual(self.plan(inputs)['destination'], 'testflight')
            for destination in ['testflight-internal', 'testflight-external']:
                inputs = self.store(profile=profile, destination=destination, groups='Aegis Early access', upload_run_id='101')
                inputs['operation'] = 'distribute'
                if profile == 'alpha' and destination == 'testflight-external':
                    with self.assertRaises(ValueError):
                        self.plan(inputs)
                else:
                    self.assertEqual(self.plan(inputs)['groups'], 'Aegis Early access')

    def test_tag_derives_exact_identity_and_only_packages_private_draft(self):
        for profile in ['alpha', 'beta', 'release']:
            plan = self.plan({}, event='push', ref='refs/tags/candidate/ios/1.0.0-'+profile+'.29')
            self.assertEqual([plan[k] for k in ['operation', 'profile', 'version', 'build', 'destination']],
                             ['package', profile, '1.0.0', '29', 'github-draft'])
        for ref in ['refs/heads/main', 'refs/tags/v1.0.0', 'refs/tags/candidate/ios/1.0.0-release.0',
                    'refs/tags/candidate/ios/1.0.0-release.29\n', 'refs/tags/candidate/ios/'+('1'*100)+'.0-alpha.29']:
            with self.assertRaises(ValueError):
                self.plan({}, event='push', ref=ref)

    def test_bad_identity_and_cross_route_inputs_are_rejected(self):
        cases = [dict(version='1.0.0', build='0'), dict(version='1.0.0\n', build='29'),
                 dict(version='1.0.0', build='29', operation='submit'),
                 dict(version='1.0.0', build='29', profile='unknown'),
                 dict(version='1.0.0', build='29', destination='testflight'),
                 dict(version='1.0.0', build='29', manifest_sha256='a'*64),
                 dict(version='1.0.0', build='29', destination='github-draft', tag='candidate/ios/1.0.0-beta.29'),
                 self.store(destination='artifacts'), self.store(source_attempt='0'), self.store(manifest_sha256='A'*64),
                 self.store(package_run_id='100\nx=bad'), self.store(groups='group'),
                 self.store(stage_input='{"x":true}'), self.store(tag='candidate/ios/1.0.0-alpha.29'),
                 self.store(unknown='value')]
        for inputs in cases:
            with self.subTest(inputs=inputs), self.assertRaises(ValueError):
                self.plan(inputs)
        for changes in [dict(destination='testflight', groups='group'),
                        dict(destination='testflight-internal', groups=''),
                        dict(destination='testflight-internal', groups='group,group')]:
            inputs = self.store(upload_run_id='101', **changes)
            inputs['operation'] = 'distribute'
            with self.assertRaises(ValueError):
                self.plan(inputs)

    def test_metadata_json_is_bounded_object_and_cannot_inject_outputs(self):
        inputs = self.store(upload_run_id='101')
        inputs['operation'] = 'metadata'
        inputs['stage_input'] = '{"text":"line1\\nline2"}'
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
