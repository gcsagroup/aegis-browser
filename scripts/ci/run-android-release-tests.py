"""Run the required Android release tests from the repository root."""

import sys
import unittest
from contextlib import ExitStack
from unittest.mock import patch


class ReleaseTestResult(unittest.TextTestResult):
    def __init__(self, stream, descriptions, verbosity):
        super().__init__(stream, descriptions, verbosity)
        self.ran_active_test = False
        self._current_test = None
        self._in_test_method = False
        self._test_method_patch = ExitStack()

    def startTest(self, test):
        super().startTest(test)
        self._current_test = test
        self._case_has_successful_subtest = False
        self._case_skipped = False

        call_test_method = test._callTestMethod

        def track_test_method(method):
            self._in_test_method = True
            try:
                return call_test_method(method)
            finally:
                self._in_test_method = False

        # Python 3.11.9 dispatches only the test body through _callTestMethod.
        # TestCase.run calls stopTest in a finally block to restore the patch.
        self._test_method_patch.enter_context(patch.object(test, "_callTestMethod", track_test_method))

    def stopTest(self, test):
        self._test_method_patch.close()
        if self._case_has_successful_subtest and not self._case_skipped:
            self.ran_active_test = True
        self._current_test = None
        super().stopTest(test)

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        if test is self._current_test:
            self._case_skipped = True

    def addSuccess(self, test):
        super().addSuccess(test)
        self.ran_active_test = True

    def addExpectedFailure(self, test, err):
        super().addExpectedFailure(test, err)
        self.ran_active_test = True

    def addSubTest(self, test, subtest, err):
        super().addSubTest(test, subtest, err)
        if test is self._current_test and self._in_test_method and err is None:
            self._case_has_successful_subtest = True


def main():
    suite = unittest.defaultTestLoader.discover("scripts/release", pattern="test_android*.py")
    if suite.countTestCases() == 0:
        print("No Android release tests discovered in scripts/release (test_android*.py)", file=sys.stderr)
        return 1

    result = unittest.TextTestRunner(resultclass=ReleaseTestResult).run(suite)
    if not result.wasSuccessful():
        return 1
    if not result.ran_active_test:
        print("No active Android release tests ran", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
