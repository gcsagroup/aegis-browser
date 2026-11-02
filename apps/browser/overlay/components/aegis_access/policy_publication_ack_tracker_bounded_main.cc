// Copyright 2026 GCSA
#include "base/functional/bind.h"
#include "base/test/launcher/unit_test_launcher.h"
#include "base/test/test_suite.h"
#include "tools/aegis/current151_tracker/bounded_runtime.h"

int main(int argc, char** argv) {
  if (!aegis_access::bounded::Enter(&argc, argv))
    return 126;
  base::TestSuite suite(argc, argv);
  return base::LaunchUnitTests(
      argc, argv, base::BindOnce(&base::TestSuite::Run, base::Unretained(&suite)));
}
