// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_ACCOUNT_MAC_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_ACCOUNT_MAC_H_

#import <Foundation/Foundation.h>

// A non-nil state supersedes the prepared reply. Run this check immediately
// before delivering it on the consumer sequence. It reads only file metadata.
typedef NSString* (^AegisAccountBindingChange)(void);
typedef void (^AegisAccountCompletion)(NSDictionary*, AegisAccountBindingChange);

// The caller supplies its own regular Profile directory, never a renderer path.
// Completion runs off the UI sequence. No response or session is cached.
void AegisQueryAccessAccount(NSString* profileDirectory,
                             AegisAccountCompletion completion);

#endif
