// Copyright 2026 GCSA
#import "chrome/browser/aegis/access/access_account_mac.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <charconv>
#include <cmath>
#include <memory>
#include <optional>
#include <string_view>

namespace {
typedef NSString* (^AegisAccountBindingChange)(void);
constexpr NSUInteger kMaxBody = 64 * 1024;
NSDictionary* State(NSString* state) { return @{@"state" : state}; }

bool Nonempty(id value) {
  return [value isKindOfClass:NSString.class] && [value length] > 0;
}

NSURL* Endpoint(id value) {
  if (!Nonempty(value)) return nil;
  NSURLComponents* c = [NSURLComponents componentsWithString:value];
  const bool loopback = [c.host isEqual:@"127.0.0.1"] || [c.host isEqual:@"::1"] ||
                        [c.host isEqual:@"[::1]"];
  if (!c.host.length || c.user || c.password || c.query || c.fragment ||
      (c.path.length && ![c.path isEqual:@"/"]) ||
      !([c.scheme.lowercaseString isEqual:@"https"] ||
        (loopback && [c.scheme.lowercaseString isEqual:@"http"]))) return nil;
  c.path = @"/v1/me/entitlement";
  return c.URL;
}

NSDictionary* ReadBinding(NSString* path, bool* missing, AegisAccountBindingChange* change) {
  *missing = false;
  int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) {
    *missing = errno == ENOENT;
    if (*missing) {
      *change = ^NSString* {
        struct stat current;
        if (lstat(path.fileSystemRepresentation, &current) == 0) return @"superseded";
        return errno == ENOENT ? nil : @"unavailable";
      };
    }
    return nil;
  }
  NSFileHandle* file = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
  struct stat statbuf;
  if (fstat(fd, &statbuf) || !S_ISREG(statbuf.st_mode) ||
      statbuf.st_uid != geteuid() || (statbuf.st_mode & 0777) != 0600 ||
      statbuf.st_size <= 0 || statbuf.st_size > 8192) return nil;
  NSData* data = [file readDataUpToLength:8193 error:nil];
  if (!data || data.length != static_cast<NSUInteger>(statbuf.st_size)) return nil;
  id b = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![b isKindOfClass:NSDictionary.class] || !Nonempty(b[@"accountId"]) ||
      !Nonempty(b[@"generation"]) || ![[NSUUID alloc] initWithUUIDString:b[@"generation"]] ||
      !Nonempty(b[@"token"]) || [b[@"token"] length] > 256 || !Endpoint(b[@"origin"])) return nil;
  NSString* token = b[@"token"];
  NSCharacterSet* allowed = [NSCharacterSet characterSetWithCharactersInString:
      @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
  if ([token rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
  // The retained open descriptor prevents inode reuse. Atomic replacements
  // therefore cannot regain this identity, even on an A → B → A switch.
  // ctime also covers modifying the open file or restoring it via a hard link.
  *change = ^NSString* {
    struct stat current;
    if (lstat(path.fileSystemRepresentation, &current))
      return errno == ENOENT ? @"signed_out" : @"unavailable";
    if (file.fileDescriptor < 0 || current.st_dev != statbuf.st_dev ||
        current.st_ino != statbuf.st_ino || current.st_ctimespec.tv_sec != statbuf.st_ctimespec.tv_sec ||
        current.st_ctimespec.tv_nsec != statbuf.st_ctimespec.tv_nsec) return @"superseded";
    return nil;
  };
  return b;
}

std::optional<uint64_t> Bytes(id value) {
  if (!Nonempty(value)) return std::nullopt;
  NSString* string = value;
  const char* utf8 = string.UTF8String;
  if (!utf8) return std::nullopt;
  std::string_view text(utf8, [string lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
  if (text.size() > 1 && text.front() == '0') return std::nullopt;
  uint64_t result;
  const char* end = std::to_address(text.end());
  auto parsed = std::from_chars(text.data(), end, result);
  if (parsed.ec != std::errc{} || parsed.ptr != end) return std::nullopt;
  return result;
}

std::optional<int64_t> Time(id value) {
  if (![value isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return std::nullopt;
  double t = [value doubleValue];
  if (!(t >= 0 && t <= 9007199254740991.0 && std::floor(t) == t)) return std::nullopt;
  return static_cast<int64_t>(t);
}

NSString* Freshness(int64_t age) {
  if (age <= 5000) return @"current";
  if (age <= 15000) return @"delayed";
  return @"unavailable";
}

NSDictionary* Entitlement(NSData* data, NSString* account, int64_t* evaluatedAt) {
  id body = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![body isKindOfClass:NSDictionary.class] ||
      ![body[@"entitlementAccountId"] isEqual:account]) return nil;
  NSArray* fields = @[@"planId", @"periodId", @"periodStart", @"periodEnd", @"expiresAt",
      @"uploadedBytes", @"downloadedBytes", @"usedBytes", @"quotaBytes", @"remainingBytes",
      @"measuredAt", @"receivedAt", @"snapshotAgeMs", @"freshness"];
  NSString* status = body[@"status"];
  bool subscribed = ![status isEqual:@"not_subscribed"];
  NSMutableDictionary* out = [@{@"entitlementAccountId": account} mutableCopy];
  for (NSString* field in fields) {
    id value = body[field];
    if (!value || (!subscribed && value != NSNull.null)) return nil;
    out[field] = value;
  }
  if (subscribed) {
    auto start = Time(out[@"periodStart"]), end = Time(out[@"periodEnd"]),
         expiry = Time(out[@"expiresAt"]), received = Time(out[@"receivedAt"]);
    auto quota = Bytes(out[@"quotaBytes"]), up = Bytes(out[@"uploadedBytes"]),
         down = Bytes(out[@"downloadedBytes"]), used = Bytes(out[@"usedBytes"]),
         remaining = Bytes(out[@"remainingBytes"]);
    if (!Nonempty(out[@"planId"]) || !Nonempty(out[@"periodId"]) ||
        !start || !end || !expiry || !*expiry || !received || *end <= *start ||
        *received < *start || !quota || !up || !down || !used || !remaining ||
        *up > INT64_MAX || *down > INT64_MAX || *quota > INT64_MAX ||
        *up + *down != *used || *remaining != (*used < *quota ? *quota - *used : 0)) return nil;
    auto now = *received;
    NSString* freshness = @"unavailable";
    if (out[@"measuredAt"] == NSNull.null) {
      auto evaluated = Time(body[@"evaluatedAt"]);
      if (out[@"snapshotAgeMs"] != NSNull.null || !evaluated || *evaluated < *received) return nil;
      now = *evaluated;
    } else {
      auto measured = Time(out[@"measuredAt"]), age = Time(out[@"snapshotAgeMs"]);
      if (!measured || !age || *measured < *start || *measured > *received ||
          *age < *received - *measured || *age > 9007199254740991LL - *measured) return nil;
      now = *measured + *age;
      freshness = Freshness(*age);
    }
    if (![freshness isEqual:out[@"freshness"]]) return nil;
    *evaluatedAt = now;
    bool expired = now >= std::min(*end, *expiry);
    if ([status isEqual:@"expired"]) {
      if (!expired) return nil;
    } else if (expired || ![status isEqual:(*used >= *quota ? @"exhausted" : @"active")]) {
      return nil;
    }
  }
  out[@"status"] = status;
  return @{@"state": @"available", @"entitlement": out};
}

AegisAccountReply PrepareReply(NSDictionary* result, AegisAccountBindingChange change,
                               uint64_t receiptNanos, int64_t evaluatedAt) {
  return ^NSDictionary* {
    NSString* state = change ? change() : nil;
    if (state) return State(state);
    NSDictionary* entitlement = result[@"entitlement"];
    if (!entitlement || [entitlement[@"status"] isEqual:@"not_subscribed"]) return result;

    int64_t elapsed = (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - receiptNanos) / NSEC_PER_MSEC;
    if (!elapsed) return result;
    NSMutableDictionary* updated = [entitlement mutableCopy];
    int64_t now = evaluatedAt + elapsed;
    if (entitlement[@"snapshotAgeMs"] != NSNull.null) {
      int64_t measured = [entitlement[@"measuredAt"] longLongValue];
      int64_t age = std::min<int64_t>(9007199254740991LL - measured,
                                     [entitlement[@"snapshotAgeMs"] longLongValue] + elapsed);
      updated[@"snapshotAgeMs"] = @(age);
      updated[@"freshness"] = Freshness(age);
    }
    if (now >= std::min([entitlement[@"periodEnd"] longLongValue],
                        [entitlement[@"expiresAt"] longLongValue])) {
      updated[@"status"] = @"expired";
    }
    return @{@"state": @"available", @"entitlement": updated};
  };
}
}  // namespace

@interface AegisAccountTransfer : NSObject <NSURLSessionDataDelegate>
@property(nonatomic, copy) AegisAccountBindingChange bindingChange;
@property(nonatomic, copy) NSDictionary* binding;
@property(nonatomic, copy) AegisAccountCompletion completion;
@property(nonatomic, strong) NSMutableData* body;
@end

@implementation AegisAccountTransfer
@synthesize bindingChange = _bindingChange;
@synthesize binding = _binding;
@synthesize completion = _completion;
@synthesize body = _body;
- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task
    willPerformHTTPRedirection:(NSHTTPURLResponse*)response newRequest:(NSURLRequest*)request
    completionHandler:(void (^)(NSURLRequest*))completion {
  completion(nil);
}
- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task
    didReceiveChallenge:(NSURLAuthenticationChallenge*)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential*))completion {
  BOOL trust = [challenge.protectionSpace.authenticationMethod isEqual:NSURLAuthenticationMethodServerTrust];
  completion(trust ? NSURLSessionAuthChallengePerformDefaultHandling
                   : NSURLSessionAuthChallengeRejectProtectionSpace, nil);
}
- (void)URLSession:(NSURLSession*)session dataTask:(NSURLSessionDataTask*)task
    didReceiveData:(NSData*)data {
  if (data.length > kMaxBody - self.body.length) {
    [task cancel];
    return;
  }
  [self.body appendData:data];
}
- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task
    didCompleteWithError:(NSError*)error {
  uint64_t received = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
  [session finishTasksAndInvalidate];
  NSDictionary* result = nil;
  int64_t evaluatedAt = 0;
  if (!error && [task.response isKindOfClass:NSHTTPURLResponse.class]) {
    NSInteger status = ((NSHTTPURLResponse*)task.response).statusCode;
    if (status == 401) result = State(@"signed_out");
    if (status == 200) result = Entitlement(self.body, self.binding[@"accountId"], &evaluatedAt);
  }
  self.completion(PrepareReply(result ?: State(@"unavailable"), self.bindingChange, received, evaluatedAt));
}
@end

void AegisQueryAccessAccount(NSString* profileDirectory, AegisAccountCompletion completion) {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSString* path = [profileDirectory stringByAppendingPathComponent:@"AegisAccessAccount.json"];
    bool missing;
    AegisAccountBindingChange change = nil;
    NSDictionary* binding = ReadBinding(path, &missing, &change);
    if (!binding) {
      completion(PrepareReply(State(missing ? @"signed_out" : @"unavailable"), change, 0, 0));
      return;
    }
    AegisAccountTransfer* transfer = [[AegisAccountTransfer alloc] init];
    transfer.bindingChange = change;
    transfer.binding = binding;
    transfer.completion = completion;
    transfer.body = [NSMutableData data];
    NSURLSessionConfiguration* configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.HTTPCookieStorage = nil;
    configuration.HTTPShouldSetCookies = NO;
    configuration.URLCredentialStorage = nil;
    configuration.URLCache = nil;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.timeoutIntervalForRequest = 5;
    configuration.timeoutIntervalForResource = 8;
    NSURLSession* session = [NSURLSession sessionWithConfiguration:configuration
                                                          delegate:transfer delegateQueue:nil];
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:Endpoint(binding[@"origin"])];
    [request setValue:[@"Bearer " stringByAppendingString:binding[@"token"]]
        forHTTPHeaderField:@"Authorization"];
    [[session dataTaskWithRequest:request] resume];
  });
}
