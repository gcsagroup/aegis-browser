// Copyright 2026 GCSA
#import "chrome/browser/aegis/access/access_account_mac.h"

#include <cstdio>
#include <string_view>

// Exercise the production transport and Profile-bound credential reader.
int main(int argc, char** argv) {
  @autoreleasepool {
    const bool hold = argc == 3 && std::string_view(argv[2]) == "--hold-delivery";
    if (argc == 3 && std::string_view(argv[2]).starts_with("--node-")) {
      bool otr = std::string_view(argv[2]) == "--node-private";
      NSDictionary* binding = nil;
      if (otr) {
        NSData* bytes = [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
        if (bytes.length) binding = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
      }
      dispatch_semaphore_t done = dispatch_semaphore_create(0);
      AegisIssueNode([NSString stringWithUTF8String:argv[1]], NSUUID.UUID.UUIDString.lowercaseString,
                     otr, binding, ^(NSDictionary* lease, AegisAccountBindingChange change, AegisNodeRevoke revoke, AegisNodeRenew) {
        puts(lease && (!change || !change()) ? "assigned" : "unavailable");
        if (revoke) revoke();
        dispatch_semaphore_signal(done);
      });
      return dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC)) != 0;
    }
    if (argc != 2 && !hold) return 1;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    AegisQueryAccessAccount([NSString stringWithUTF8String:argv[1]], ^(NSDictionary* result, AegisAccountBindingChange change) {
      if (hold) {
        puts("queued");
        fflush(stdout);
        (void)getchar();
      }
      NSString* state = change ? change() : nil;
      if (state) result = @{@"state" : state};
      NSData* json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
      fwrite(json.bytes, 1, json.length, stdout);
      dispatch_semaphore_signal(done);
    });
    return dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC)) != 0;
  }
}
