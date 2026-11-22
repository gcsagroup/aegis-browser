"""Run the required Android release tests from the repository root."""

import asyncio
import inspect
import sys
import unittest
from contextlib import ExitStack
from contextvars import ContextVar
from functools import wraps
from unittest.mock import patch


class ReleaseTestResult(unittest.TextTestResult):
    def __init__(self, stream, descriptions, verbosity):
        super().__init__(stream, descriptions, verbosity)
        self.ran_active_test = False
        self._current_test = None
        self._test_method_owner = ContextVar("test_method_owner", default=(None, None))
        self._test_method_patch = ExitStack()

    def startTest(self, test):
        super().startTest(test)
        self._current_test = test
        self._case_has_successful_subtest = False
        self._case_skipped = False

        call_test_method = test._callTestMethod

        def track_test_method(method):
            @wraps(method)
            def sync_body():
                token = self._test_method_owner.set((test, None))
                try:
                    return method()
                finally:
                    self._test_method_owner.reset(token)

            @wraps(method)
            async def async_body():
                token = self._test_method_owner.set((test, asyncio.current_task()))
                try:
                    return await method()
                finally:
                    self._test_method_owner.reset(token)

            return call_test_method(async_body if inspect.iscoroutinefunction(method) else sync_body)

        # The async dispatcher can run setup tasks before the wrapped body starts.
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
        owner_test, owner_task = self._test_method_owner.get()
        if err is not None or test is not self._current_test or test is not owner_test:
            return
        if owner_task is not None:
            try:
                if asyncio.current_task() is not owner_task:
                    return
            except RuntimeError:
                return
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
