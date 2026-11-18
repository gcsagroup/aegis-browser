// Copyright 2026 GCSA
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>

#include <string>

#include "base/strings/sys_string_conversions.h"

namespace aegis {

std::string RecognizeCaptureWithVision(std::string png) {
  @autoreleasepool {
    NSData* data = [NSData dataWithBytes:png.data() length:png.size()];
    VNRecognizeTextRequest* request = [[VNRecognizeTextRequest alloc] init];
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    NSArray<NSString*>* supported =
        [request supportedRecognitionLanguagesAndReturnError:nullptr];
    NSMutableArray<NSString*>* languages = [NSMutableArray array];
    for (NSString* language in @[ @"zh-Hans", @"zh-Hant", @"en-US" ]) {
      if ([supported containsObject:language]) {
        [languages addObject:language];
      }
    }
    if (languages.count) {
      request.recognitionLanguages = languages;
    }
    VNImageRequestHandler* handler =
        [[VNImageRequestHandler alloc] initWithData:data options:@{}];
    if (![handler performRequests:@[ request ] error:nullptr]) {
      return {};
    }
    NSMutableArray<NSString*>* lines = [NSMutableArray array];
    for (VNRecognizedTextObservation* line in request.results) {
      NSString* text = [line topCandidates:1].firstObject.string;
      if (text.length) {
        [lines addObject:text];
      }
    }
    return base::SysNSStringToUTF8([lines componentsJoinedByString:@"\n"]);
  }
}

}  // namespace aegis
