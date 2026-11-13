"""Keep live panel selection distinct from explicitly provisioned offline data."""

from contextlib import redirect_stderr
from io import StringIO
import os
import sys
import unittest
from unittest.mock import patch

from services.access_account import server
from services.access_account.panel import Panel


class SourceSelectionTest(unittest.TestCase):
    def argv(self, *source):
        return ["access-account", "--database", "controlled.sqlite", "--port", "0", *source]

    def test_empty_panel_url_fails_before_listening_with_or_without_token(self):
        for token in (None, "controlled_panel_token"):
            with self.subTest(token_present=token is not None):
                environment = {} if token is None else {"AEGIS_3XUI_TOKEN": token}
                errors = StringIO()
                with patch.object(sys, "argv", self.argv("--panel-url", "")), \
                        patch.dict(os.environ, environment, clear=True), \
                        patch.object(server, "create_server") as listen, redirect_stderr(errors):
                    with self.assertRaises(SystemExit) as stopped:
                        server.main()
                self.assertEqual(stopped.exception.code, 2)
                self.assertIn("invalid panel configuration", errors.getvalue())
                listen.assert_not_called()

    def test_stored_snapshots_explicitly_selects_offline_data(self):
        with patch.object(sys, "argv", self.argv("--stored-snapshots")), \
                patch.dict(os.environ, {}, clear=True), \
                patch.object(server, "create_server") as listen:
            server.main()
        self.assertIsNone(listen.call_args.kwargs["panel"])
        listen.return_value.__enter__.return_value.serve_forever.assert_called_once_with()

    def test_valid_panel_url_selects_live_data(self):
        with patch.object(sys, "argv", self.argv("--panel-url", "https://panel.example.test/prefix")), \
                patch.dict(os.environ, {"AEGIS_3XUI_TOKEN": "controlled_panel_token"}, clear=True), \
                patch.object(server, "create_server") as listen:
            server.main()
        panel = listen.call_args.kwargs["panel"]
        self.assertIsInstance(panel, Panel)
        self.assertEqual((panel.host, panel.prefix),
                         ("panel.example.test", "/prefix/panel/api/clients/"))
        listen.return_value.__enter__.return_value.serve_forever.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
