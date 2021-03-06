/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import <UIKit/UIKit.h>

#import "ABI5_0_0RCTFrameUpdate.h"

@class ABI5_0_0RCTBridge;

@interface ABI5_0_0RCTNavigator : UIView <ABI5_0_0RCTFrameUpdateObserver>

@property (nonatomic, strong) UIView *ReactABI5_0_0NavSuperviewLink;
@property (nonatomic, assign) NSInteger requestedTopOfStack;

- (instancetype)initWithBridge:(ABI5_0_0RCTBridge *)bridge NS_DESIGNATED_INITIALIZER;

/**
 * Schedules a JavaScript navigation and prevents `UIKit` from navigating until
 * JavaScript has sent its scheduled navigation.
 *
 * @returns Whether or not a JavaScript driven navigation could be
 * scheduled/reserved. If returning `NO`, JavaScript should usually just do
 * nothing at all.
 */
- (BOOL)requestSchedulingJavaScriptNavigation;

@end
