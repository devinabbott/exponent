// Copyright 2015-present 650 Industries. All rights reserved.

#import "EXAppState.h"
#import "EXConstants.h"
#import "EXDisabledDevLoadingView.h"
#import "EXDisabledDevMenu.h"
#import "EXDisabledRedBox.h"
#import "EXFileSystem.h"
#import "EXFrameExceptionsManager.h"
#import "EXLinkingManager.h"
#import "EXNotifications.h"
#import "EXVersionManager.h"

#import "RCTAssert.h"
#import "RCTDevMenu+Device.h"
#import "RCTLog.h"
#import "RCTUtils.h"

#import <objc/message.h>

typedef NSMutableDictionary <NSString *, NSMutableArray<NSValue *> *> EXClassPointerMap;

static EXClassPointerMap *EXVersionedOnceTokens;
EXClassPointerMap *EXGetVersionedOnceTokens(void);
EXClassPointerMap *EXGetVersionedOnceTokens(void)
{
  return EXVersionedOnceTokens;
}

void EXSetInstanceMethod(Class cls, SEL original, SEL replacement)
{
  Method originalMethod = class_getInstanceMethod(cls, original);
  
  Method replacementMethod = class_getInstanceMethod(cls, replacement);
  IMP replacementImplementation = method_getImplementation(replacementMethod);
  const char *replacementArgTypes = method_getTypeEncoding(replacementMethod);
  
  if (!class_addMethod(cls, original, replacementImplementation, replacementArgTypes)) {
    method_setImplementation(originalMethod, replacementImplementation);
  }
}

@interface EXVersionManager ()

// is this the first time this ABI has been touched at runtime?
@property (nonatomic, assign) BOOL isFirstLoad;

@end

@implementation EXVersionManager

- (instancetype)initWithFatalHandler:(void (^)(NSError *))fatalHandler
                         logFunction:(void (^)(NSInteger, NSInteger, NSString *, NSNumber *, NSString *))logFunction
                        logThreshold:(NSInteger)threshold
{
  if (self = [super init]) {
    [self configureABIWithFatalHandler:fatalHandler logFunction:logFunction logThreshold:threshold];
  }
  return self;
}

- (void)bridgeWillStartLoading:(id)bridge
{
  // manually send a "start loading" notif, since the real one happened uselessly inside the RCTBatchedBridge constructor
  [[NSNotificationCenter defaultCenter]
   postNotificationName:RCTJavaScriptWillStartLoadingNotification object:bridge];
}

- (void)bridgeFinishedLoading
{

}

- (void)bridgeDidForeground
{
  if (_isFirstLoad) {
    // reverse the RCT-triggered first swap, so the RCT implementation is back in its original place
    [self swapSystemMethods];
    _isFirstLoad = NO; // in case the same VersionManager instance is used between multiple bridge loads
  }
  // now modify system behavior with no swap
  [self setSystemMethods];
}

- (void)bridgeDidBackground
{
  
}

- (void)invalidate
{
  [self resetOnceTokens];
}

+ (void)registerOnceToken:(dispatch_once_t *)token forClass:(NSString *)someClass
{
  EXClassPointerMap *onceTokens = EXGetVersionedOnceTokens();
  if (!onceTokens[someClass]) {
    [onceTokens setObject:[NSMutableArray array] forKey:someClass];
  }
  NSMutableArray<NSValue *> *tokensForClass = onceTokens[someClass];
  for (NSValue *val in tokensForClass) {
    dispatch_once_t *existing = [val pointerValue];
    if (existing == token)
      return;
  }
  [tokensForClass addObject:[NSValue valueWithPointer:token]];
}


#pragma mark - internal

- (void)configureABIWithFatalHandler:(void (^)(NSError *))fatalHandler
                         logFunction:(void (^)(NSInteger, NSInteger, NSString *, NSNumber *, NSString *))logFunction
                        logThreshold:(NSInteger)threshold
{
  if (EXVersionedOnceTokens == nil) {
    // first time initializing this RN version at runtime
    _isFirstLoad = YES;
  }
  EXVersionedOnceTokens = [NSMutableDictionary dictionary];
  RCTSetFatalHandler(fatalHandler);
  RCTSetLogThreshold(threshold);
  RCTSetLogFunction(logFunction);
}

- (void)resetOnceTokens
{
  EXClassPointerMap *onceTokens = EXGetVersionedOnceTokens();
  [onceTokens enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull className, NSMutableArray<NSValue *> * _Nonnull tokensForClass, BOOL * _Nonnull stop) {
    for (NSValue *val in tokensForClass) {
      dispatch_once_t *existing = [val pointerValue];
      *existing = 0;
    }
  }];
}

- (void)swapSystemMethods
{
#if RCT_DEV
  // key commands
  SEL RCTCommandsSelector = NSSelectorFromString(@"RCT_keyCommands");
  SEL RCTSendActionSelector = NSSelectorFromString(@"RCT_sendAction:to:from:forEvent:");
  if ([UIDevice currentDevice].systemVersion.floatValue < 9) {
    RCTSwapInstanceMethods([UIApplication class],
                           @selector(keyCommands),
                           RCTCommandsSelector);
    
    RCTSwapInstanceMethods([UIApplication class],
                           @selector(sendAction:to:from:forEvent:),
                           RCTSendActionSelector);
  } else {
    RCTSwapInstanceMethods([UIResponder class],
                           @selector(keyCommands),
                           RCTCommandsSelector);
  }
  
  // shake gesture
  SEL RCTMotionSelector = NSSelectorFromString(@"RCT_motionEnded:withEvent:");
  RCTSwapInstanceMethods([UIWindow class], @selector(motionEnded:withEvent:), RCTMotionSelector);
#endif
}

- (void)setSystemMethods
{
#if RCT_DEV
  // key commands
  SEL RCTCommandsSelector = NSSelectorFromString(@"RCT_keyCommands");
  if ([UIDevice currentDevice].systemVersion.floatValue < 9) {
    EXSetInstanceMethod([UIApplication class],
                           @selector(keyCommands),
                           RCTCommandsSelector);
    
    // don't support this set on iOS 8.x -- results in a recursive call.
    // in this case people will just need to live without key commands.

    /* EXSetInstanceMethod([UIApplication class],
                           @selector(sendAction:to:from:forEvent:),
                           RCTSendActionSelector); */
  } else {
    EXSetInstanceMethod([UIResponder class],
                           @selector(keyCommands),
                           RCTCommandsSelector);
  }
  
  // shake gesture
  SEL RCTMotionSelector = NSSelectorFromString(@"RCT_motionEnded:withEvent:");
  EXSetInstanceMethod([UIWindow class], @selector(motionEnded:withEvent:), RCTMotionSelector);
#endif
}

/**
 *  Expected params:
 *    EXFrame *frame
 *    NSDictionary *manifest
 *    NSDictionary *constants
 *    NSURL *initialUri
 *    @BOOL isDeveloper
 */
- (NSArray *)extraModulesWithParams:(NSDictionary *)params
{
  id frame = params[@"frame"];
  NSDictionary *manifest = params[@"manifest"];
  NSURL *initialUri = params[@"initialUri"];
  NSDictionary *constants = params[@"constants"];
  BOOL isDeveloper = [params[@"isDeveloper"] boolValue];
  NSString *experienceId = [manifest objectForKey:@"id"];

  NSMutableArray *extraModules = [NSMutableArray arrayWithArray:
                                  @[
                                    [[EXAppState alloc] init],
                                    [[EXConstants alloc] initWithProperties:constants],
                                    [[EXDisabledDevLoadingView alloc] init],
                                    [[EXFileSystem alloc] initWithExperienceId:experienceId],
                                    [[EXFrameExceptionsManager alloc] initWithDelegate:frame],
                                    [[EXLinkingManager alloc] initWithInitialUrl:initialUri],
                                    [[EXNotifications alloc] initWithExperienceId:experienceId],
                                    ]];

  if (!isDeveloper) {
    // user-facing (not debugging).
    // additionally disable RCTRedBox and RCTDevMenu
    [extraModules addObjectsFromArray:@[
                                        [[EXDisabledDevMenu alloc] init],
                                        [[EXDisabledRedBox alloc] init],
                                        ]];
  }
  return extraModules;
};

+ (NSString *)escapedResourceName:(NSString *)name
{
  NSString *charactersToEscape = @"!*'();:@&=+$,/?%#[]";
  NSCharacterSet *allowedCharacters = [[NSCharacterSet characterSetWithCharactersInString:charactersToEscape] invertedSet];
  return [name stringByAddingPercentEncodingWithAllowedCharacters:allowedCharacters];
}

@end
