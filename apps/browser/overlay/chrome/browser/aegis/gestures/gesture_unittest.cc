// Copyright 2026 GCSA
#include <limits>

#include "chrome/browser/aegis/gestures/gesture_recognizer.h"
#include "chrome/browser/aegis/gestures/gesture_settings.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis {
TEST(AegisGestureRecognizerTest, ClickAndJitterDoNotBecomeGestures) {
  GestureRecognizer gesture;
  gesture.Start(200, 100, 16);
  gesture.Move(207, 106);
  gesture.Move(196, 98);
  EXPECT_FALSE(gesture.moved());
  EXPECT_TRUE(gesture.Match().empty());
}

TEST(AegisGestureRecognizerTest, ConsecutiveSegmentsAndNegativeCoordinates) {
  GestureRecognizer gesture;
  gesture.Start(-300, 10, 16);
  gesture.Move(-300, 50);
  gesture.Move(-300, 90);
  gesture.Move(-260, 90);
  EXPECT_EQ(gesture.Match(), "DR");
}

TEST(AegisGestureRecognizerTest, DiagonalDoesNotGuessDestructiveAction) {
  GestureRecognizer gesture;
  gesture.Start(0, 0, 16);
  gesture.Move(0, 50);
  gesture.Move(40, 90);
  EXPECT_TRUE(gesture.moved());
  EXPECT_EQ(gesture.directions(), "D");
  EXPECT_TRUE(gesture.Match().empty());
}

TEST(AegisGestureRecognizerTest, CancelSuppressesActionUntilNewPress) {
  GestureRecognizer gesture;
  gesture.Start(100, 100, 16);
  gesture.Move(0, 100);
  gesture.Cancel();
  gesture.Move(200, 100);
  EXPECT_TRUE(gesture.Match().empty());
  gesture.Start(0, 0, 16);
  gesture.Move(80, 0);
  EXPECT_EQ(gesture.Match(), "R");
}

TEST(AegisGestureRecognizerTest, RejectsLongAndNonFiniteInput) {
  GestureRecognizer gesture;
  gesture.Start(0, 0, 16);
  for (int i = 0; i < 9; ++i) {
    gesture.Move(i % 2 == 0 ? 30 : 0, 0);
  }
  EXPECT_TRUE(gesture.cancelled());
  EXPECT_TRUE(gesture.Match().empty());
  gesture.Start(0, 0, 16);
  gesture.Move(std::numeric_limits<float>::infinity(), 0);
  EXPECT_TRUE(gesture.cancelled());
}

TEST(AegisGestureSettingsTest, DefaultsRoundTripAndKeepPdfOptIn) {
  auto defaults = GestureSettings::Defaults();
  auto parsed = GestureSettings::Parse(defaults.ToValue());
  ASSERT_TRUE(parsed);
  EXPECT_EQ(parsed->bindings, defaults.bindings);
  EXPECT_EQ(parsed->ActionFor("DR"), "close_tab");
  EXPECT_TRUE(parsed->ActionFor("RD").empty());
  EXPECT_TRUE(FindGestureAction("pdf_next")->pdf_only);
  for (const auto& [pattern, action] : parsed->bindings) {
    EXPECT_FALSE(FindGestureAction(action)->pdf_only);
  }
}

TEST(AegisGestureSettingsTest, RejectsMalformedConfigAtomically) {
  auto config = GestureSettings::Defaults().ToValue();
  config.Set("threshold", 0);
  EXPECT_FALSE(GestureSettings::Parse(config));
  config.Set("threshold", 16);
  config.FindDict("bindings")->Set("RR", "reload");
  EXPECT_FALSE(GestureSettings::Parse(config));
  config.FindDict("bindings")->Remove("RR");
  config.FindDict("bindings")->Set("LR", "execute_javascript");
  EXPECT_FALSE(GestureSettings::Parse(config));
  config.FindDict("bindings")->Remove("LR");
  config.Set("hiddenOption", true);
  EXPECT_FALSE(GestureSettings::Parse(config));
}

TEST(AegisGestureSettingsTest, HostExclusionIsExactAndValidated) {
  auto config = GestureSettings::Defaults().ToValue();
  config.FindList("disabledSites")->Append("example.com");
  auto parsed = GestureSettings::Parse(config);
  ASSERT_TRUE(parsed);
  EXPECT_FALSE(parsed->EnabledFor(GURL("https://example.com/path")));
  EXPECT_TRUE(parsed->EnabledFor(GURL("https://sub.example.com/")));
  EXPECT_TRUE(parsed->EnabledFor(GURL("chrome://settings/")));
  parsed->enabled = false;
  EXPECT_FALSE(parsed->EnabledFor(GURL("https://other.test/")));
  config.FindList("disabledSites")->Append("user@example.com");
  EXPECT_FALSE(GestureSettings::Parse(config));
}

TEST(AegisGestureSettingsTest, PracticeBoundsExcludeOutsideArea) {
  GesturePracticeRegion area;
  area.x = .2;
  area.y = .3;
  area.width = .4;
  area.height = .2;
  EXPECT_TRUE(area.Contains(.4, .4));
  EXPECT_FALSE(area.Contains(.1, .4));
  EXPECT_FALSE(area.Contains(.4, .6));
  EXPECT_FALSE(area.Contains(std::numeric_limits<double>::quiet_NaN(), .4));
}
}  // namespace aegis
