import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from private_test_subscription import install


class SubscriptionPackagingTests(unittest.TestCase):
    def test_channel_gate_binding_and_removal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, node, output = [root / name for name in ('input.json', 'node', 'output')]
            node.write_text('vless://fixture@example.invalid:443\n')
            source.write_text(json.dumps(dict(subscriptionInfoURL='https://example.invalid/sub/test?format=info',
                                             allowedTestClient='fixture', expectedQuotaBytes=10_000_000_000,
                                             trafficReset='daily', ignored='must not ship')))
            for channel in ('dev', 'alpha', 'beta'):
                install(channel, str(source), str(node), output)
                result = json.loads(output.read_text())
                self.assertEqual(result['nodeSHA256'], hashlib.sha256(node.read_bytes().strip()).hexdigest())
                self.assertNotIn('ignored', result)
                install(channel, '/dev/null', str(node), output)
                self.assertFalse(output.exists())
            for channel in ('release', 'prod', '', None):
                output.write_text('stale secret')
                install(channel, str(source), str(node), output)
                self.assertFalse(output.exists())
            for url in ('http://example.invalid/s?format=info', 'https://user:pass@example.invalid/s?format=info',
                        'https://example.invalid/s', 'https://example.invalid/s?format=info&token=x'):
                data = json.loads(source.read_text()); data['subscriptionInfoURL'] = url
                source.write_text(json.dumps(data)); output.write_text('stale secret')
                with self.assertRaises(ValueError):
                    install('alpha', str(source), str(node), output)
                self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
