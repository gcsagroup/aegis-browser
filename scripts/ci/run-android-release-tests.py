"""Run the required Android release tests from the repository root."""

import sys
import unittest


class ReleaseTestResult(unittest.TextTestResult):
    def __init__(self, stream, descriptions, verbosity):
        super().__init__(stream, descriptions, verbosity)
        self.ran_active_test = False

    def addSuccess(self, test):
        super().addSuccess(test)
        self.ran_active_test = True

    def addExpectedFailure(self, test, err):
        super().addExpectedFailure(test, err)
        self.ran_active_test = True

    def addSubTest(self, test, subtest, err):
        super().addSubTest(test, subtest, err)
        # A successful subtest counts even if another subtest was skipped.
        if err is None:
            self.ran_active_test = True


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
