// Copyright 2015-present 650 Industries. All rights reserved.

#import "ABI6_0_0EXDisabledRedBox.h"

@implementation ABI6_0_0EXDisabledRedBox

+ (NSString *)moduleName { return @"ABI6_0_0RCTRedBox"; }

- (void)showError:(NSError *)message {}
- (void)showErrorMessage:(NSString *)message {}
- (void)showErrorMessage:(NSString *)message withDetails:(NSString *)details {}
- (void)showErrorMessage:(NSString *)message withStack:(NSArray<NSDictionary *> *)stack {}
- (void)updateErrorMessage:(NSString *)message withStack:(NSArray<NSDictionary *> *)stack {}
- (void)showErrorMessage:(NSString *)message withStack:(NSArray<NSDictionary *> *)stack showIfHidden:(BOOL)shouldShow {}
- (void)dismiss {}

@end
