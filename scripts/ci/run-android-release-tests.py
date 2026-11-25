"""Run the required Android release tests from the repository root."""

import sys
import unittest


class ReleaseTestResult(unittest.TextTestResult):
    def __init__(self, stream, descriptions, verbosity):
        super().__init__(stream, descriptions, verbosity)
        self.has_successful_case = False

    def addSuccess(self, test):
        super().addSuccess(test)
        self.has_successful_case = True


def main():
    suite = unittest.defaultTestLoader.discover("scripts/release", pattern="test_android*.py")
    if suite.countTestCases() == 0:
        print("No Android release tests discovered in scripts/release (test_android*.py)", file=sys.stderr)
        return 1

    result = unittest.TextTestRunner(resultclass=ReleaseTestResult).run(suite)
    if not result.wasSuccessful():
        return 1
    if not result.has_successful_case:
        print("No complete Android release tests passed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
