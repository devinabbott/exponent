/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "ABI5_0_0RCTBridge+Private.h"

#import <objc/runtime.h>

#import "ABI5_0_0RCTConvert.h"
#import "ABI5_0_0RCTEventDispatcher.h"
#import "ABI5_0_0RCTKeyCommands.h"
#import "ABI5_0_0RCTLog.h"
#import "ABI5_0_0RCTModuleData.h"
#import "ABI5_0_0RCTPerformanceLogger.h"
#import "ABI5_0_0RCTUtils.h"

NSString *const ABI5_0_0RCTReloadNotification = @"ABI5_0_0RCTReloadNotification";
NSString *const ABI5_0_0RCTJavaScriptWillStartLoadingNotification = @"ABI5_0_0RCTJavaScriptWillStartLoadingNotification";
NSString *const ABI5_0_0RCTJavaScriptDidLoadNotification = @"ABI5_0_0RCTJavaScriptDidLoadNotification";
NSString *const ABI5_0_0RCTJavaScriptDidFailToLoadNotification = @"ABI5_0_0RCTJavaScriptDidFailToLoadNotification";
NSString *const ABI5_0_0RCTDidInitializeModuleNotification = @"ABI5_0_0RCTDidInitializeModuleNotification";

static NSMutableArray<Class> *ABI5_0_0RCTModuleClasses;
NSArray<Class> *ABI5_0_0RCTGetModuleClasses(void);
NSArray<Class> *ABI5_0_0RCTGetModuleClasses(void)
{
  return ABI5_0_0RCTModuleClasses;
}

/**
 * Register the given class as a bridge module. All modules must be registered
 * prior to the first bridge initialization.
 */
void ABI5_0_0RCTRegisterModule(Class);
void ABI5_0_0RCTRegisterModule(Class moduleClass)
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    ABI5_0_0RCTModuleClasses = [NSMutableArray new];
  });

  ABI5_0_0RCTAssert([moduleClass conformsToProtocol:@protocol(ABI5_0_0RCTBridgeModule)],
            @"%@ does not conform to the ABI5_0_0RCTBridgeModule protocol",
            moduleClass);

  // Register module
  [ABI5_0_0RCTModuleClasses addObject:moduleClass];
}

/**
 * This function returns the module name for a given class.
 */
NSString *ABI5_0_0RCTBridgeModuleNameForClass(Class cls)
{
#if ABI5_0_0RCT_DEV
  ABI5_0_0RCTAssert([cls conformsToProtocol:@protocol(ABI5_0_0RCTBridgeModule)],
            @"Bridge module `%@` does not conform to ABI5_0_0RCTBridgeModule", cls);
#endif

  NSString *name = [cls moduleName];
  if (name.length == 0) {
    name = NSStringFromClass(cls);
  }
  if ([name hasPrefix:@"RK"]) {
    name = [name stringByReplacingCharactersInRange:(NSRange){0,@"RK".length} withString:@"RCT"];
  }
  return ABI5_0_0EX_REMOVE_VERSION(name);
}

@implementation ABI5_0_0RCTBridge
{
  NSURL *_delegateBundleURL;
}

dispatch_queue_t ABI5_0_0RCTJSThread;

+ (void)initialize
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{

    // Set up JS thread
    ABI5_0_0RCTJSThread = (id)kCFNull;
  });
}

static ABI5_0_0RCTBridge *ABI5_0_0RCTCurrentBridgeInstance = nil;

/**
 * The last current active bridge instance. This is set automatically whenever
 * the bridge is accessed. It can be useful for static functions or singletons
 * that need to access the bridge for purposes such as logging, but should not
 * be relied upon to return any particular instance, due to race conditions.
 */
+ (instancetype)currentBridge
{
  return ABI5_0_0RCTCurrentBridgeInstance;
}

+ (void)setCurrentBridge:(ABI5_0_0RCTBridge *)currentBridge
{
  ABI5_0_0RCTCurrentBridgeInstance = currentBridge;
}

- (instancetype)initWithDelegate:(id<ABI5_0_0RCTBridgeDelegate>)delegate
                   launchOptions:(NSDictionary *)launchOptions
{
  if ((self = [super init])) {
    ABI5_0_0RCTPerformanceLoggerStart(ABI5_0_0RCTPLBridgeStartup);
    ABI5_0_0RCTPerformanceLoggerStart(ABI5_0_0RCTPLTTI);

    _delegate = delegate;
    _launchOptions = [launchOptions copy];
    [self setUp];
    ABI5_0_0RCTExecuteOnMainThread(^{ [self bindKeys]; }, NO);
  }
  return self;
}

- (instancetype)initWithBundleURL:(NSURL *)bundleURL
                   moduleProvider:(ABI5_0_0RCTBridgeModuleProviderBlock)block
                    launchOptions:(NSDictionary *)launchOptions
{
  if ((self = [super init])) {
    ABI5_0_0RCTPerformanceLoggerStart(ABI5_0_0RCTPLBridgeStartup);
    ABI5_0_0RCTPerformanceLoggerStart(ABI5_0_0RCTPLTTI);

    _bundleURL = bundleURL;
    _moduleProvider = block;
    _launchOptions = [launchOptions copy];
    [self setUp];
    ABI5_0_0RCTExecuteOnMainThread(^{ [self bindKeys]; }, NO);
  }
  return self;
}

ABI5_0_0RCT_NOT_IMPLEMENTED(- (instancetype)init)

- (void)dealloc
{
  /**
   * This runs only on the main thread, but crashes the subclass
   * ABI5_0_0RCTAssertMainThread();
   */
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [self invalidate];
}

- (void)bindKeys
{
  ABI5_0_0RCTAssertMainThread();

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(reload)
                                               name:ABI5_0_0RCTReloadNotification
                                             object:self.baseBridge];

#if TARGET_IPHONE_SIMULATOR
  ABI5_0_0RCTKeyCommands *commands = [ABI5_0_0RCTKeyCommands sharedInstance];

  // reload in current mode
  __weak typeof(self) weakSelf = self;
  [commands registerKeyCommandWithInput:@"r"
                          modifierFlags:UIKeyModifierCommand
                                 action:^(__unused UIKeyCommand *command) {
    ABI5_0_0RCTBridge *baseBridge = weakSelf.baseBridge;
    if (baseBridge) {
      [[NSNotificationCenter defaultCenter] postNotificationName:ABI5_0_0RCTReloadNotification
                                                          object:baseBridge
                                                        userInfo:nil];
    }
  }];

#endif
}

- (NSArray<Class> *)moduleClasses
{
  return self.batchedBridge.moduleClasses;
}

- (id)moduleForName:(NSString *)moduleName
{
  return [self.batchedBridge moduleForName:moduleName];
}

- (id)moduleForClass:(Class)moduleClass
{
  return [self moduleForName:ABI5_0_0RCTBridgeModuleNameForClass(moduleClass)];
}

- (NSArray *)modulesConformingToProtocol:(Protocol *)protocol
{
  NSMutableArray *modules = [NSMutableArray new];
  for (Class moduleClass in self.moduleClasses) {
    if ([moduleClass conformsToProtocol:protocol]) {
      id module = [self moduleForClass:moduleClass];
      if (module) {
        [modules addObject:module];
      }
    }
  }
  return [modules copy];
}

- (BOOL)moduleIsInitialized:(Class)moduleClass
{
  return [self.batchedBridge moduleIsInitialized:moduleClass];
}

- (ABI5_0_0RCTEventDispatcher *)eventDispatcher
{
  return [self moduleForClass:[ABI5_0_0RCTEventDispatcher class]];
}

- (void)reload
{
  /**
   * Any thread
   */
  dispatch_async(dispatch_get_main_queue(), ^{
    [self invalidate];
    [self setUp];
  });
}

- (void)setUp
{
  // Only update bundleURL from delegate if delegate bundleURL has changed
  NSURL *previousDelegateURL = _delegateBundleURL;
  _delegateBundleURL = [self.delegate sourceURLForBridge:self];
  if (_delegateBundleURL && ![_delegateBundleURL isEqual:previousDelegateURL]) {
    _bundleURL = _delegateBundleURL;
  }

  // Sanitize the bundle URL
  _bundleURL = [ABI5_0_0RCTConvert NSURL:_bundleURL.absoluteString];

  [self createBatchedBridge];
}

- (void)createBatchedBridge
{
  self.batchedBridge = [[ABI5_0_0RCTBatchedBridge alloc] initWithParentBridge:self];
}

- (BOOL)isLoading
{
  return self.batchedBridge.loading;
}

- (BOOL)isValid
{
  return self.batchedBridge.valid;
}

- (BOOL)isBatchActive
{
  return [_batchedBridge isBatchActive];
}

- (ABI5_0_0RCTBridge *)baseBridge
{
  return self;
}

- (void)invalidate
{
  ABI5_0_0RCTBridge *batchedBridge = self.batchedBridge;
  self.batchedBridge = nil;

  if (batchedBridge) {
    ABI5_0_0RCTExecuteOnMainThread(^{
      [batchedBridge invalidate];
    }, NO);
  }
}

- (void)enqueueJSCall:(NSString *)moduleDotMethod args:(NSArray *)args
{
  [self.batchedBridge enqueueJSCall:moduleDotMethod args:args];
}

- (void)enqueueCallback:(NSNumber *)cbID args:(NSArray *)args
{
  [self.batchedBridge enqueueCallback:cbID args:args];
}

@end
