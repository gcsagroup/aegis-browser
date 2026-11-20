import importlib.util
from pathlib import Path
import unittest


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


plan = load('android_delivery_plan', 'android-delivery-plan.py')
receipt = load('android_delivery_receipt', 'android-delivery-receipt.py')
SHA = 'a' * 40


class PlanTests(unittest.TestCase):
    def simple(self, **inputs):
        base = {'operation': '查询状态 / Status', 'product': 'Alpha · 仅内测 / Internal only',
                'version': '7.2.0.339', 'build': '2007000339'}
        base.update(inputs)
        return plan.normalize('workflow_dispatch', 'refs/heads/main', base, source_sha=SHA)

    def test_labels_and_version_binding(self):
        status = self.simple()
        self.assertEqual(status['operation'], 'status-query')
        self.assertEqual(status['destination'], 'play-internal')
        self.assertEqual(self.simple(operation='发布核对 / Release Wait')['operation'], 'status-release-wait')
        self.assertEqual(self.simple(operation='Release Wait', product='Release')['operation'], 'status-release-wait')
        uploaded = self.simple(operation='打包并上传 / Package and upload', product='Release · 通用 / Universal')
        self.assertEqual((uploaded['destination'], uploaded['track']), ('play-draft', 'internal'))
        older = self.simple(version='6.1.0.266', build='2006000266', operation='仅打包 / Package')
        self.assertEqual(older['destination'], 'artifacts')
        self.assertEqual(receipt.require_version_code('6.1.0.266', '2006000266'), 2006000266)

    def test_rejections(self):
        with self.assertRaises(ValueError):
            self.simple(operation='打包并上传 / Package and upload', product='Release', build='2007000340')
        with self.assertRaises(ValueError):
            plan.normalize('workflow_dispatch', 'refs/heads/main',
                           {'operation': '仅打包 / Package', 'product': '自动 / Auto', 'target': '7.2.0.339(2007000339)',
                            'advanced': '{}'}, mode='full', source_sha=SHA)
        with self.assertRaises(ValueError):
            plan.normalize('workflow_dispatch', 'refs/heads/main',
                           {'operation': '完整模式 / Full', 'product': 'Release', 'target': '7.2.0.339(2007000339)',
                            'advanced': '{"operation":"package-upload"}'}, mode='full', source_sha=SHA)
        with self.assertRaises(ValueError):
            plan.normalize('workflow_dispatch', 'refs/heads/main',
                           {'operation': '打包并上传 / Package and upload', 'product': 'Release',
                            'version': '7.2.0.339', 'build': '2007000339'}, attempt='2')
        with self.assertRaises(ValueError):
            self.simple(approved_source_sha='b' * 40)
        with self.assertRaises(ValueError):
            plan.normalize('workflow_dispatch', 'refs/heads/main',
                           {'operation': '完整模式 / Full', 'product': 'Release',
                            'target': receipt.encode('release', '7.2.0.339', '2007000339', 9, 9, 1, 'ab' * 32),
                            'advanced': '{"operation":"distribute","track":"internal","userFraction":"0.10"}'},
                           mode='full', source_sha=SHA)
        distributed = plan.normalize('workflow_dispatch', 'refs/heads/main',
                                     {'operation': '完整模式 / Full', 'product': 'Auto',
                                      'target': receipt.encode('beta', '7.2.0.339', '2007000339', 9, 8, 1, 'ab' * 32),
                                      'advanced': '{"operation":"distribute","track":"beta","userFraction":"0.1"}'},
                                     mode='full', source_sha=SHA)
        self.assertEqual(distributed['user_fraction'], '0.1')
        self.assertEqual(distributed['destination'], 'play-beta')


if __name__ == '__main__':
    unittest.main()
