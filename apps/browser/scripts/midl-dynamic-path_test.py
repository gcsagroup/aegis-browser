"""覆盖真实故障路径、CRLF 和不得被归一化掩盖的接口差异。"""
from pathlib import Path
import importlib.util
import tempfile
import sys
import unittest

path = Path(__file__).resolve().parents[1] / 'overlay/build/toolchain/win/midl.py'
spec = importlib.util.spec_from_file_location('aegis_midl', path)
midl = importlib.util.module_from_spec(spec)
# 防止测试在发布用覆盖目录生成缓存文件。
sys.dont_write_bytecode = True
spec.loader.exec_module(midl)


class DynamicIdlCommentTest(unittest.TestCase):
    def normalize(self, contents, generated='gen/chrome/service.idl', original='../../chrome/service.idl'):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'service.h'
            path.write_bytes(contents)
            midl.normalize_dynamic_idl_comment(path, generated, original)
            return path.read_bytes()

    def test_both_service_paths_and_line_endings(self):
        for service in ('elevation_service/elevation_service_idl', 'windows_services/elevated_tracing_service/tracing_service_idl'):
            for newline in (b'\n', b'\r\n'):
                generated = 'gen/chrome/' + service + '.idl'
                original = '../../chrome/' + service + '.idl'
                prefix = b'/* header */' + newline + b'/* Compiler settings for '
                suffix = b':' + newline + b'    Oicf, W1' + newline + b'IID body unchanged'
                self.assertEqual(self.normalize(prefix + generated.encode() + suffix, generated, original), prefix + original.encode() + suffix)

    def test_other_paths_still_differ(self):
        content = b'/* Compiler settings for gen/chrome/other.idl:\nIID changed'
        self.assertEqual(self.normalize(content), content)

    def test_body_changes_survive_normalization(self):
        prefix = b'/* Compiler settings for gen/chrome/service.idl:\n'
        old = self.normalize(prefix + b'IID old')
        new = self.normalize(prefix + b'IID new')
        self.assertNotEqual(old, new)
        self.assertTrue(new.endswith(b'IID new'))

    def test_path_references_outside_comment_are_preserved(self):
        content = b'const char* name = "gen/chrome/service.idl";\n'
        self.assertEqual(self.normalize(content), content)


if __name__ == '__main__':
    unittest.main()
