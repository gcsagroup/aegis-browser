// Copyright 2026 GCSA

#include "chrome/common/aegis/features.h"

#include "base/test/scoped_feature_list.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::features {
namespace {

bool EvaluateFingerprintGuard(bool master, bool subfeature, bool pref) {
  base::test::ScopedFeatureList scoped_features;
  if (master && subfeature) {
    scoped_features.InitWithFeatures({kAegisEnabled, kAegisFingerprintGuard},
                                     {});
  } else if (master) {
    scoped_features.InitWithFeatures({kAegisEnabled}, {kAegisFingerprintGuard});
  } else if (subfeature) {
    scoped_features.InitWithFeatures({kAegisFingerprintGuard}, {kAegisEnabled});
  } else {
    scoped_features.InitWithFeatures({},
                                     {kAegisEnabled, kAegisFingerprintGuard});
  }
  return IsFingerprintGuardGloballyEnabled(pref);
}

TEST(AegisFeaturesTest, FingerprintGuardRequiresEveryGate) {
  for (bool master : {false, true}) {
    for (bool subfeature : {false, true}) {
      for (bool pref : {false, true}) {
        SCOPED_TRACE(testing::Message() << "master=" << master << " subfeature="
                                        << subfeature << " pref=" << pref);
        EXPECT_EQ(master && subfeature && pref,
                  EvaluateFingerprintGuard(master, subfeature, pref));
      }
    }
  }
}

bool EvaluateMinerGuard(bool master, bool subfeature, bool pref) {
  base::test::ScopedFeatureList scoped_features;
  if (master && subfeature) {
    scoped_features.InitWithFeatures({kAegisEnabled, kAegisMinerGuard}, {});
  } else if (master) {
    scoped_features.InitWithFeatures({kAegisEnabled}, {kAegisMinerGuard});
  } else if (subfeature) {
    scoped_features.InitWithFeatures({kAegisMinerGuard}, {kAegisEnabled});
  } else {
    scoped_features.InitWithFeatures({}, {kAegisEnabled, kAegisMinerGuard});
  }
  return IsMinerGuardGloballyEnabled(pref);
}

TEST(AegisFeaturesTest, MinerGuardRequiresEveryGlobalGate) {
  for (bool master : {false, true}) {
    for (bool subfeature : {false, true}) {
      for (bool pref : {false, true}) {
        SCOPED_TRACE(testing::Message() << "master=" << master << " subfeature="
                                        << subfeature << " pref=" << pref);
        EXPECT_EQ(master && subfeature && pref,
                  EvaluateMinerGuard(master, subfeature, pref));
      }
    }
  }
}

TEST(AegisFeaturesTest, BytecodeShadowIsDefaultOffAndRequiresMasterGate) {
  EXPECT_FALSE(IsBytecodeShadowGloballyEnabled());
  {
    base::test::ScopedFeatureList scoped_features;
    scoped_features.InitWithFeatures({kAegisEnabled, kAegisBytecodeShadow}, {});
    EXPECT_TRUE(IsBytecodeShadowGloballyEnabled());
  }
  {
    base::test::ScopedFeatureList scoped_features;
    scoped_features.InitWithFeatures({kAegisBytecodeShadow}, {kAegisEnabled});
    EXPECT_FALSE(IsBytecodeShadowGloballyEnabled());
  }
}

}  // namespace
}  // namespace aegis::features
