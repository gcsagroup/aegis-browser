"""验证开发包默认来源，以及测试、正式包对空地址和非 HTTPS 来源的拒绝。"""
import importlib.util
from pathlib import Path
import unittest

config = Path(__file__).resolve().parents[1] / "overlay/chrome/browser/ui/webui/aegis/link_environment.py"
spec = importlib.util.spec_from_file_location("link_environment", config)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PortalBuildTest(unittest.TestCase):
    def test_development(self):
        self.assertEqual(module.portal_origin("development", ""), "http://localhost:5176")
        with self.assertRaises(ValueError):
            module.portal_origin("development", "https://portal.example.test")

    def test_distributable_packages(self):
        for environment in ("testing", "production"):
            origin = "https://portal.example.test:443"
            self.assertEqual(module.portal_origin(environment, origin), origin)
            for bad in ("", "http://portal.example.test", "https://localhost",
                        "https://127.0.0.1", "https://127.1", origin + "/login",
                        "https://name@portal.example.test", origin + "#account"):
                with self.subTest(environment=environment, address=bad), self.assertRaises(ValueError):
                    module.portal_origin(environment, bad)


if __name__ == "__main__":
    unittest.main()
