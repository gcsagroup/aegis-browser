"""Security regression for GRIT fixture input parsing; uses grit-test-requirements.txt."""

import importlib.util
import io
from pathlib import Path
import unittest

from defusedxml.common import DefusedXmlException


spec = importlib.util.spec_from_file_location(
    "grit_password_locales", Path(__file__).with_name("grit-password-locales_test.py"),
)
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class SourceXmlSecurityTest(unittest.TestCase):
    def test_preserves_translation_and_placeholder(self):
        root = fixture.parse_source(io.StringIO(
            '<grit><message name="title">匯入密碼至 '
            '<ph name="PRODUCT">Aegis Browser</ph></message></grit>'
        ))
        message = root.find("message")
        self.assertEqual(message.text, "匯入密碼至 ")
        self.assertEqual(message.find("ph").attrib, {"name": "PRODUCT"})
        self.assertEqual(message.find("ph").text, "Aegis Browser")

    def test_rejects_document_type(self):
        with self.assertRaises(DefusedXmlException):
            fixture.parse_source(io.StringIO('<!DOCTYPE grit><grit/>'))

    def test_rejects_entity_expansion(self):
        with self.assertRaises(DefusedXmlException):
            fixture.parse_source(io.StringIO(
                '<!DOCTYPE grit [<!ENTITY repeat "expanded">]><grit>&repeat;</grit>'
            ))

    def test_rejects_external_reference(self):
        with self.assertRaises(DefusedXmlException):
            fixture.parse_source(io.StringIO(
                '<!DOCTYPE grit SYSTEM "https://example.invalid/external.dtd"><grit/>'
            ))


if __name__ == "__main__":
    unittest.main()
