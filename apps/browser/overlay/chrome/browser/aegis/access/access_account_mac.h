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

// Browser-process only. The private binding is independently authorized in
// memory; private mode never looks up the regular profile binding. The lease
// and revoke block must never be serialized to WebUI, prefs, or diagnostics.
typedef void (^AegisNodeRevoke)(void);
typedef void (^AegisNodeRenew)(void (^done)(int64_t expiresAt));
typedef void (^AegisNodeCompletion)(NSDictionary* lease, AegisAccountBindingChange change,
                                    AegisNodeRevoke revoke, AegisNodeRenew renew);
void AegisIssueNode(NSString* directory, NSString* context, bool isPrivate,
                    NSDictionary* privateBinding, AegisNodeCompletion completion);

#endif
