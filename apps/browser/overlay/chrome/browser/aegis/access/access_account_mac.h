// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_ACCOUNT_MAC_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_ACCOUNT_MAC_H_

#import <Foundation/Foundation.h>

// Resolve on the consumer sequence immediately before presenting the reply.
typedef NSDictionary* (^AegisAccountReply)(void);
typedef void (^AegisAccountCompletion)(AegisAccountReply);

// The caller supplies its own regular Profile directory, never a renderer path.
// Completion runs off the UI sequence. No response or session is cached.
void AegisQueryAccessAccount(NSString* profileDirectory,
                             AegisAccountCompletion completion);

#endif
