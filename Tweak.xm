#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <substrate.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <spawn.h>

//==============================================================
// 0. BỘ ĐIỀU PHỐI TRẠNG THÁI & ĐỌC CÀI ĐẶT GỐC APPLE
//==============================================================

typedef NS_ENUM(NSInteger, AODState) {
    AODStateIdle = 0,       // Màn hình sáng bình thường / Đang dùng
    AODStateTransitioning,  // Đang chạy animation lặn dần vào AOD (0.45s)
    AODStateActive,         // Đang hiển thị AOD tĩnh
    AODStateProximityOff    // Đang đút túi / Úp màn hình / Che camera (Tắt đèn nền về 0)
};

static AODState gCurrentState = AODStateIdle;
static CGFloat gCurrentAODProgress = 1.0f;
static NSInteger gBurnInShiftStep = 0;
static id gInjectedSessionProvider = nil;
static BOOL gAODDebug = NO;
#define AODLOG(fmt, ...) do { if (gAODDebug) NSLog(@"AODHOOK " fmt, ##__VA_ARGS__); } while (0)
static inline BOOL aodInAODFlow(void) {
    return gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning;
}

// CỜ BẢO VỆ KHỞI ĐỘNG CHỈ DÀNH RIÊNG CHO SPRINGBOARD
static BOOL gSpringBoardDidFinishLaunching = NO;
static BOOL gIsSpringBoardProcess = NO;

// Biến lưu cấu hình tải nhanh trong bộ nhớ RAM
static BOOL gCachedAODEnabled = YES;
static BOOL gCachedWallpaperEnabled = YES;
static BOOL gCachedBlurWallpaperEnabled = YES;
static BOOL gCachedNotificationsEnabled = YES;
static float gCachedCustomHz = 2.0f; // Mặc định 2 Hz (dải 2–5)
static float gCachedBrightnessFactor = 0.025f;

#define AOD_PREFS_DOMAIN CFSTR("com.jb.aodreal")
#define AOD_PREFS_NOTIFY CFSTR("com.jb.aodreal/preferences.changed")

// Đọc / ghi DUY NHẤT trong domain của tweak (Settings, backboardd, SpringBoard, PosterBoard đều dùng chung)
static inline BOOL aodReadBool(CFStringRef key, BOOL fallback) {
    Boolean valid = false;
    Boolean v = CFPreferencesGetAppBooleanValue(key, AOD_PREFS_DOMAIN, &valid);
    return valid ? (BOOL)v : fallback;
}

static inline float aodReadFloat(CFStringRef key, float fallback) {
    CFPropertyListRef raw = CFPreferencesCopyAppValue(key, AOD_PREFS_DOMAIN);
    float result = fallback;
    if (raw) {
        if (CFGetTypeID(raw) == CFNumberGetTypeID()) {
            result = [(__bridge NSNumber *)raw floatValue];
        }
        CFRelease(raw);
    }
    return result;
}

static inline void aodWriteValue(CFStringRef key, CFPropertyListRef value) {
    CFPreferencesSetAppValue(key, value, AOD_PREFS_DOMAIN);
    CFPreferencesAppSynchronize(AOD_PREFS_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), AOD_PREFS_NOTIFY, NULL, NULL, YES);
}

// TRẠNG THÁI DÙNG CHUNG: SpringBoard ghi, backboardd/PosterBoard đọc (mỗi tiến trình có biến static riêng)
static void aodPublishState(void) {
    if (!gIsSpringBoardProcess) return;
    NSNumber *v = @((int)gCurrentState);
    CFPreferencesSetAppValue(CFSTR("runtimeState"), (__bridge CFPropertyListRef)v, AOD_PREFS_DOMAIN);
    CFPreferencesAppSynchronize(AOD_PREFS_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.jb.aodreal/state"), NULL, NULL, YES);
}

#define AODSetState(x) do { gCurrentState = (x); aodPublishState(); AODLOG(@"state=%d", (int)gCurrentState); } while (0)

static void AODStateCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                             const void *object, CFDictionaryRef userInfo) {
    if (gIsSpringBoardProcess) return;
    CFPreferencesAppSynchronize(AOD_PREFS_DOMAIN);
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("runtimeState"), AOD_PREFS_DOMAIN);
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID()) {
            int st = 0;
            CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &st);
            gCurrentState = (AODState)st;
        }
        CFRelease(v);
    }
}

// Dải giá trị: Hz 2–5 (bước 1), độ sáng 2–30 (factor = mức / 1000; mặc định 25 = 0.025f)
static inline void loadAODPreferences(void) {
    gCachedAODEnabled           = aodReadBool(CFSTR("enabled"), YES);
    gCachedWallpaperEnabled     = aodReadBool(CFSTR("ShowWallpaperInAlwaysOn"), YES);
    gCachedBlurWallpaperEnabled = aodReadBool(CFSTR("BlurWallpaperInAlwaysOn"), YES);
    gCachedNotificationsEnabled = aodReadBool(CFSTR("ShowNotificationsInAlwaysOn"), YES);

    float hz = aodReadFloat(CFSTR("CustomAODRefreshRate"), 2.0f);
    gCachedCustomHz = (hz >= 2.0f && hz <= 5.0f) ? hz : 2.0f;

    float level = aodReadFloat(CFSTR("CustomAODBrightness"), 25.0f);
    if (level < 2.0f || level > 30.0f) level = 25.0f;
    gCachedBrightnessFactor = level / 1000.0f;
}

// CÁC HÀM GETTER TỐC ĐỘ CAO CHO TOÀN BỘ TWEAK
static inline BOOL isAODMasterEnabled(void) { 
    if (gIsSpringBoardProcess && !gSpringBoardDidFinishLaunching) return NO;
    return gCachedAODEnabled; 
}

static inline BOOL isWallpaperEnabled(void) { return gCachedWallpaperEnabled; }
static inline BOOL isBlurWallpaperEnabled(void) { return gCachedBlurWallpaperEnabled; }
static inline BOOL isNotificationsEnabled(void) { return gCachedNotificationsEnabled; }
static inline float getCustomAODRefreshRate(void) { return gCachedCustomHz; }
static inline float getAODPanelBrightnessFactor(void) { return gCachedBrightnessFactor; }
static inline float getCustomAODBrightnessFactor(void) { return gCachedBrightnessFactor; }

// CHÍNH SÁCH NGẮT AOD TỰ ĐỘNG CHUẨN GỐC APPLE (IOKIT AN TOÀN - CHỐNG SIGTRAP SPRINGBOARD)
static inline BOOL computeSuppressAODBySystemPolicies(void) {
    if ([[NSProcessInfo processInfo] isLowPowerModeEnabled]) {
        return YES;
    }

    CFTypeRef powerInfo = IOPSCopyPowerSourcesInfo();
    if (powerInfo) {
        CFArrayRef powerSourcesList = IOPSCopyPowerSourcesList(powerInfo);
        if (powerSourcesList) {
            CFIndex count = CFArrayGetCount(powerSourcesList);
            for (CFIndex i = 0; i < count; ++i) {
                CFDictionaryRef desc = IOPSGetPowerSourceDescription(powerInfo, CFArrayGetValueAtIndex(powerSourcesList, i));
                if (desc) {
                    CFStringRef state = (CFStringRef)CFDictionaryGetValue(desc, CFSTR(kIOPSPowerSourceStateKey));
                    if (state && CFStringCompare(state, CFSTR(kIOPSACPowerValue), 0) == kCFCompareEqualTo) {
                        CFRelease(powerSourcesList);
                        CFRelease(powerInfo);
                        return NO;
                    }

                    CFNumberRef curCapNum = (CFNumberRef)CFDictionaryGetValue(desc, CFSTR(kIOPSCurrentCapacityKey));
                    CFNumberRef maxCapNum = (CFNumberRef)CFDictionaryGetValue(desc, CFSTR(kIOPSMaxCapacityKey));
                    if (curCapNum && maxCapNum) {
                        int cur = 0, max = 100;
                        CFNumberGetValue(curCapNum, kCFNumberIntType, &cur);
                        CFNumberGetValue(maxCapNum, kCFNumberIntType, &max);
                        if (max > 0) {
                            int percent = (cur * 100) / max;
                            if (percent <= 5) { // Pin <= 5% -> ngắt AOD
                                CFRelease(powerSourcesList);
                                CFRelease(powerInfo);
                                return YES;
                            }
                        }
                    }
                }
            }
            CFRelease(powerSourcesList);
        }
        CFRelease(powerInfo);
    }

    return NO;
}

// Kiểm tra pin/nguồn/Low Power tối đa 1 lần mỗi 5 giây thay vì mỗi hook
static BOOL gSuppressCache = NO;
static CFAbsoluteTime gSuppressStamp = -1000.0;
static inline BOOL shouldSuppressAODBySystemPolicies(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gSuppressStamp > 5.0) {
        gSuppressCache = computeSuppressAODBySystemPolicies();
        gSuppressStamp = now;
    }
    return gSuppressCache;
}

//==============================================================
// 1. KHAI BÁO CÁC LỚP VÀ GIAO DIỆN HỆ THỐNG
//==============================================================

@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)title target:(id)target set:(SEL)set get:(SEL)get detail:(Class)detail cell:(long long)cell edit:(Class)edit;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
- (void)setValues:(NSArray *)values titles:(NSArray *)titles;
- (void)setValues:(NSArray *)values titles:(NSArray *)titles shortTitles:(NSArray *)shortTitles;
@end

@interface PSListController : UIViewController {
@public
    NSMutableArray *_specifiers;
}
- (NSMutableArray *)specifiers;
- (void)reloadSpecifiers;
- (PSSpecifier *)specifierForID:(NSString *)specifierID;
- (void)reloadSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
- (void)insertSpecifier:(PSSpecifier *)specifier atIndex:(NSInteger)index animated:(BOOL)animated;
- (void)addSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
- (id)loadSpecifiersFromPlistName:(NSString *)name target:(id)target bundle:(NSBundle *)bundle;
@end

@interface DBSMainDisplayPreferencesController : PSListController
- (NSMutableArray *)specifiers;
- (id)getAODMasterStatusText:(PSSpecifier *)spec;
@end

@interface DBSAlwaysOnViewController : PSListController
- (PSSpecifier *)_alwaysOnDisplaySpecifier;
- (id)getAODValue:(PSSpecifier *)spec;
- (void)setAODValue:(id)value spec:(PSSpecifier *)spec;
@end

@interface BLSHFlipbookSpecification : NSObject
- (double)framesPerSecond;
- (double)minimumGapDuration;
@end

@interface SBBacklightPlatformProvider : NSObject
- (BOOL)deviceSupportsAlwaysOn;
- (BOOL)isAlwaysOnEnabled;
- (id)flipbookSpecification;
- (id)sessionProvider;
- (id)initWithBacklightEnvironmentSessionProvider:(id)provider;
- (BOOL)isShowingBlankingWindow;
- (void)showBlankingWindow:(BOOL)show withFadeDuration:(double)duration;
- (void)_setBlankingWindowVisible:(BOOL)visible fadeDuration:(double)duration;
- (BOOL)isUsingAlwaysOnBrightnessCurve;
@end

@interface SBBacklightEnvironmentSessionProvider : NSObject
- (id)createInactiveEnvironmentSession;
- (id)_buildPresentation;
@end

@interface BLSBacklightFBSSceneEnvironment : NSObject
- (BOOL)supportsAlwaysOn;
- (BOOL)isDisplayBlanked;
- (long long)visualState;
@end

@interface SBAlwaysOnPolicyCoordinator : NSObject
- (NSSet *)activePolicies;
- (void)_activatePolicy:(id)policy;
@end

@interface SBFocusModeAlwaysOnPolicy : NSObject
- (BOOL)isAlwaysOnPolicyActive;
@end

@interface SBLowPowerModeAlwaysOnPolicy : NSObject
- (BOOL)isAlwaysOnPolicyActive;
- (void)_updateAssertion;
@end

@interface SBSetupAlwaysOnPolicy : NSObject
- (BOOL)isAlwaysOnPolicyActive;
@end

@interface SBThermalAlwaysOnPolicy : NSObject
- (BOOL)isAlwaysOnPolicyActive;
@end

@interface SBLockScreenService : NSObject
- (BOOL)isAlwaysOnPolicyActive;
@end

@interface BLSHBacklightTransitionStateMachine : NSObject
- (BOOL)isAlwaysOnEnabled;
- (BOOL)isAlwaysOnSuppressed;
@end

@interface BLSHXPCBacklightProxyHost : NSObject
- (BOOL)isAlwaysOnEnabled;
@end

@interface CAWindowServerDisplay : NSObject
- (id)currentMode;
- (void)setRefreshRate:(float)rate;
- (float)refreshRate;
- (BOOL)blankingRemovesPower;
- (void)setBlankingRemovesPower:(BOOL)val;
- (BOOL)disablesUpdates;
- (void)setDisablesUpdates:(BOOL)val;
- (BOOL)disabled;
- (void)setDisabled:(BOOL)val;
- (BOOL)isBlanked;
- (void)setBlanked:(BOOL)val;
- (BOOL)isFlipBookActive;
- (BOOL)isFlipBookEnabled;
- (void)setFlipBookEnabled:(BOOL)val;
- (BOOL)isFlipBookSuppressed;
- (void)setFlipBookSuppressed:(BOOL)val;
- (void)powerStateDidChange:(id)arg1;
@end

@interface CSCoverSheetViewController : UIViewController
- (BOOL)isAlwaysOnPresentation;
- (BOOL)shouldDimForAlwaysOn;
- (BOOL)coverSheetIsObscured;
- (long long)backlightLuminance;
- (void)setBacklightLevel:(float)level;
- (void)_updateAppearanceForAODTransitionToInactive:(BOOL)inactive;
- (void)_animateView:(UIView *)view toWhitePointReduced:(BOOL)reduced withDuration:(double)duration withDispatchGroup:(id)group;
- (void)_updateWallpaperEffectView;
- (void)_updateDateTimeView;
- (void)_updateComplicationsContainerView;
- (void)_updateVibrancy;
- (void)_updateContent;
- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession;
@end

@interface CSCombinedListViewController : UIViewController
- (BOOL)showNotificationsInAlwaysOn;
- (void)setShowNotificationsInAlwaysOn:(BOOL)show;
- (void)_setNotificationListHidden:(BOOL)hidden forReason:(id)reason;
- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession;
- (UIView *)view;
@end

@interface CSBackgroundContentViewController : UIViewController
- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession;
@end

@interface CSComplicationContainerViewController : UIViewController
- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession;
- (id)vibrancyConfiguration;
@end

@interface CSActivityItemViewController : UIViewController
- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession;
@end

@interface CSHomeAffordanceViewController : UIViewController
- (BOOL)isHomeAffordanceHidden;
@end

@interface CSQuickActionsViewController : UIViewController
- (BOOL)isQuickActionsHidden;
- (void)_updateQuickActionListHidden:(BOOL)hidden;
@end

@interface CSStatusBarViewController : UIViewController
- (BOOL)isStatusBarHidden;
@end

@interface NCNotificationShortLookView : UIView
- (void)setLegibilitySettings:(id)settings;
@end

@interface _UILegibilitySettings : NSObject
+ (instancetype)sharedInstanceForStyle:(long long)style;
- (UIColor *)primaryColor;
@end

@interface SBFLockScreenDateView : UIView
- (id)vibrancyConfiguration;
- (_UILegibilitySettings *)legibilitySettings;
- (void)setLegibilitySettings:(_UILegibilitySettings *)settings;
@end

@interface SBFLockScreenDateViewController : UIViewController
- (UIView *)view;
- (_UILegibilitySettings *)legibilitySettings;
- (void)setLegibilitySettings:(_UILegibilitySettings *)settings;
- (BOOL)restrictsVibrancy;
- (void)setRestrictsVibrancy:(BOOL)restricts;
- (void)updateTimeNow;
- (void)_updateWithFrameSpecifier:(id)arg1;
@end

@interface SBLockScreenViewControllerBase : UIViewController
- (void)setBacklightLevel:(float)level;
@end

@interface SBDashBoardLockScreenEnvironment : NSObject
- (void)setBacklightLevel:(float)level;
@end

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isLockScreenActive;
- (BOOL)shouldPreventBacklightBlankingForAlwaysOn;
- (void)lockUIFromSource:(int)source withOptions:(id)options;
- (void)unlockUIFromSource:(int)source withOptions:(id)options;
- (void)_wakeScreenForTapToWake;
- (void)tapToWakeControllerDidRecognizeWakeGesture:(id)gesture;
@end

@interface SBTapToWakeController : NSObject <UIGestureRecognizerDelegate>
- (BOOL)isTapToWakeSupported;
- (BOOL)shouldTapToWake;
- (void)setDigitizerInTapToWakeMode:(BOOL)mode;
- (void)setDigitizerModeRequiresHitTestSuppression:(BOOL)suppress;
- (void)setTapToWakeGestureRecognizer:(UITapGestureRecognizer *)gesture;
- (void)tapToWakeDidRecognize:(UITapGestureRecognizer *)gesture;
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch;
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer;
@end

@interface SBUIController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)handleHomeButtonDoublePressRequest;
@end

@interface SBBacklightController : NSObject
+ (instancetype)sharedInstance;
- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion;
- (void)animateBacklightToFactor:(float)factor duration:(double)duration source:(long long)source completion:(id)completion;
- (float)backlightFactor;
- (float)_factorToPublishForBacklightState:(long long)state;
- (void)_updateHIDUISensorModeForBacklightState:(long long)state source:(long long)source;
@end

@interface SBProximitySensorManager : NSObject
- (BOOL)isProximityDetectionPermitted;
- (BOOL)isProximityDetectionEnabled;
- (void)_setObjectInProximity:(BOOL)inProximity detectionMode:(int)mode;
@end

@interface BLSHBacklightStateMachine : NSObject
- (long long)backlightState;
- (BOOL)isAlwaysOnEnabled;
- (BOOL)isAlwaysOnSuppressed;
- (BOOL)isAlwaysOnDisabledByAssertion;
@end

@interface BLSHAlwaysOnPresentationEngine : NSObject
- (BOOL)isSuppressed;
- (void)setSuppressed:(BOOL)suppressed;
- (BOOL)isUsingPseudoFlipbook;
- (BOOL)alwaysFillFlipbook;
- (void)createFlipbook;
- (id)frameOnGlassNow;
- (void)startLiveUpdates;
- (void)main_performLiveUpdateIfNeeded;
- (void)suspendForReason:(id)reason;
@end

@interface BLSHPseudoFlipbook : NSObject
- (id)init;
- (id)frameOnGlass;
@end

@interface BLSHBacklightSceneHostEnvironment : NSObject
- (BOOL)supportsAlwaysOn;
- (BOOL)isAlwaysOnActive;
- (long long)visualState;
- (BOOL)isClientActive;
@end

@interface BKDisplayRenderOverlay : NSObject
- (BOOL)disablesDisplayBlanking;
@end

@interface BKDisplayManager : NSObject
- (void)setBlanked:(BOOL)blanked withReason:(id)reason;
@end

@interface PRPosterEnvironmentImpl : NSObject
- (CGFloat)backlightProgress;
- (void)setBacklightProgress:(CGFloat)progress;
- (CGFloat)linearBacklightProgress;
- (void)setLinearBacklightProgress:(CGFloat)progress;
- (long long)luminance;
- (BOOL)isLowLuminance;
- (BOOL)isLegibilityBlurEnabled;
@end

@interface PRPosterLockPosterAppearance : NSObject
- (BOOL)isLegibilityBlurEnabled;
- (BOOL)allowsModifyingLegibilityBlur;
@end

@interface PRPosterConfiguration : NSObject
- (BOOL)isLegibilityBlurEnabled;
@end

@interface PRPosterLockPosterHomeScreenAppearance : NSObject
- (BOOL)isLegibilityBlurEnabled;
- (BOOL)allowsModifyingLegibilityBlur;
@end

@interface PRPosterHomePosterHomeScreenAppearance : NSObject
- (BOOL)isLegibilityBlurEnabled;
- (BOOL)allowsModifyingLegibilityBlur;
@end

@interface PRPosterDescriptorHomeScreenConfiguration : NSObject
- (BOOL)allowsModifyingLegibilityBlur;
@end

@interface BLSBacklight : NSObject
+ (BOOL)isAlwaysOnEnabledByHardware;
@end

@interface BLSAlwaysOnFrequencyConfiguration : NSObject
- (BOOL)isAlwaysOnEnabled;
@end

@interface CBDisplayModule : NSObject
+ (BOOL)isAlwaysOnDisplaySupported;
@end

@interface CBController : NSObject
- (void)setPowerState:(BOOL)state completion:(id)completion;
@end

//==============================================================
// 2. TẦNG DRIVER & PHẦN CỨNG (BACKBOARDD) - ĐÃ TỐI ƯU CHỐNG JETSAM OOM
//==============================================================

%group Group_Backboardd

// BẢO VỆ NGUỒN ĐÈN NỀN PANEL (CHỐNG LẶP STATE VÀ DẬP TẮT KHI CẦN THIẾT)
%hook CBController

- (void)setPowerState:(BOOL)state completion:(id)completion {
    if (isAODMasterEnabled()) {
        if (!state) {
            if (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies()) {
                %orig(NO, completion);
                return;
            }
            if (aodInAODFlow()) {
                %orig(YES, completion);
                return;
            }
        } else {
            if (gCurrentState == AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) {
                AODSetState(AODStateActive);
            }
        }
    }
    %orig(state, completion);
}

%end

// ÉP HẠ XUNG NHỊP HZ/FPS CHỈ KHI Ở TRẠNG THÁI AOD TĨNH (TRÁNH NGHẼN BUFFER LÚC CHUYỂN CẢNH)
%hook CAWindowServerDisplay

- (float)refreshRate {
    if (isAODMasterEnabled() && aodInAODFlow()) {
        return getCustomAODRefreshRate(); // 1.0f -> 5.0f Hz
    }
    return %orig;
}

- (void)setRefreshRate:(float)rate {
    if (isAODMasterEnabled() && aodInAODFlow()) {
        %orig(getCustomAODRefreshRate());
        return;
    }
    %orig(rate);
}

- (BOOL)blankingRemovesPower {
    if (isAODMasterEnabled() && aodInAODFlow() && !shouldSuppressAODBySystemPolicies()) {
        return NO;
    }
    return %orig;
}

- (void)setBlankingRemovesPower:(BOOL)val {
    if (isAODMasterEnabled() && aodInAODFlow() && !shouldSuppressAODBySystemPolicies()) {
        %orig(NO);
        return;
    }
    %orig(val);
}

- (BOOL)disabled {
    if (isAODMasterEnabled() && aodInAODFlow() && !shouldSuppressAODBySystemPolicies()) {
        return NO;
    }
    return %orig;
}

- (void)setDisabled:(BOOL)val {
    if (isAODMasterEnabled() && val && aodInAODFlow() && !shouldSuppressAODBySystemPolicies()) {
        %orig(NO);
        return;
    }
    %orig(val);
}

- (BOOL)isBlanked {
    if (isAODMasterEnabled() && aodInAODFlow() && !shouldSuppressAODBySystemPolicies()) {
        return NO;
    }
    return %orig;
}

- (void)setBlanked:(BOOL)blanked {
    if (isAODMasterEnabled() && blanked && aodInAODFlow() && !shouldSuppressAODBySystemPolicies()) {
        %orig(NO);
        return;
    }
    %orig(blanked);
}

- (BOOL)disablesUpdates {
    if (isAODMasterEnabled() && aodInAODFlow()) {
        return NO;
    }
    return %orig;
}

- (void)setDisablesUpdates:(BOOL)val {
    if (isAODMasterEnabled() && aodInAODFlow()) {
        %orig(NO);
        return;
    }
    %orig(val);
}

- (BOOL)isFlipBookActive {
    if (isAODMasterEnabled() && aodInAODFlow() && !shouldSuppressAODBySystemPolicies()) {
        return YES;
    }
    return %orig;
}

- (BOOL)isFlipBookEnabled { 
    return isAODMasterEnabled() ? YES : %orig; 
}

- (void)setFlipBookEnabled:(BOOL)val { 
    %orig(isAODMasterEnabled() ? YES : val); 
}

- (BOOL)isFlipBookSuppressed {
    if (isAODMasterEnabled() && (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies())) {
        return YES;
    }
    return %orig;
}

- (void)setFlipBookSuppressed:(BOOL)suppressed {
    if (isAODMasterEnabled() && aodInAODFlow() && !shouldSuppressAODBySystemPolicies() && suppressed) {
        %orig(NO);
        return;
    }
    %orig(suppressed);
}

- (void)powerStateDidChange:(id)arg1 {
    if (isAODMasterEnabled() && aodInAODFlow() && !shouldSuppressAODBySystemPolicies()) {
        return;
    }
    %orig(arg1);
}

%end

%hook BKDisplayRenderOverlay
- (BOOL)disablesDisplayBlanking { 
    return (isAODMasterEnabled() && aodInAODFlow()) ? YES : %orig; 
}
%end

%hook BKDisplayManager
- (void)setBlanked:(BOOL)blanked withReason:(id)reason {
    if (isAODMasterEnabled() && blanked && aodInAODFlow() && !shouldSuppressAODBySystemPolicies()) {
        %orig(NO, reason);
        return;
    }
    %orig(blanked, reason);
}
%end

%hook BLSHBacklightStateMachine
- (BOOL)isAlwaysOnEnabled { 
    if (shouldSuppressAODBySystemPolicies()) return NO;
    return isAODMasterEnabled() ? YES : %orig; 
}

- (BOOL)isAlwaysOnSuppressed {
    if (isAODMasterEnabled()) {
        return (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies()) ? YES : NO;
    }
    return %orig;
}

- (long long)backlightState {
    long long state = %orig;
    if (isAODMasterEnabled() && state == 0) {
        if (gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) {
            return 2;
        }
    }
    return state;
}
%end

%hook BLSHBacklightTransitionStateMachine
- (BOOL)isAlwaysOnEnabled { 
    if (shouldSuppressAODBySystemPolicies()) return NO;
    return isAODMasterEnabled() ? YES : %orig; 
}

- (BOOL)isAlwaysOnSuppressed {
    if (isAODMasterEnabled()) {
        return (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies()) ? YES : NO;
    }
    return %orig;
}
%end

%hook BLSHXPCBacklightProxyHost
- (BOOL)isAlwaysOnEnabled { 
    if (shouldSuppressAODBySystemPolicies()) return NO;
    return isAODMasterEnabled() ? YES : %orig; 
}
%end

%hook BLSHFlipbookSpecification

- (double)framesPerSecond {
    if (isAODMasterEnabled() && aodInAODFlow()) {
        return (double)getCustomAODRefreshRate();
    }
    return %orig;
}

- (double)minimumGapDuration {
    if (isAODMasterEnabled() && aodInAODFlow()) {
        double fps = (double)getCustomAODRefreshRate();
        return (fps <= 1.0) ? 1.0 : (1.0 / fps);
    }
    return %orig;
}

%end

%hook BLSHAlwaysOnPresentationEngine

- (BOOL)isSuppressed {
    if (isAODMasterEnabled()) {
        if (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies()) return YES;
    }
    return %orig;
}

- (void)setSuppressed:(BOOL)suppressed {
    if (isAODMasterEnabled() && aodInAODFlow() && !shouldSuppressAODBySystemPolicies() && suppressed) {
        %orig(NO);
        return;
    }
    %orig(suppressed);
}

- (BOOL)isUsingPseudoFlipbook { 
    return isAODMasterEnabled() ? YES : %orig; 
}

- (void)suspendForReason:(id)reason {
    if (isAODMasterEnabled() && aodInAODFlow() && !shouldSuppressAODBySystemPolicies()) {
        return;
    }
    %orig(reason);
}

%end

%hook BLSHBacklightSceneHostEnvironment
- (BOOL)supportsAlwaysOn { 
    if (shouldSuppressAODBySystemPolicies()) return NO;
    return isAODMasterEnabled() ? YES : %orig; 
}

- (BOOL)isAlwaysOnActive { 
    return (isAODMasterEnabled() && aodInAODFlow() && !shouldSuppressAODBySystemPolicies()) ? YES : %orig; 
}

- (BOOL)isClientActive { 
    if (shouldSuppressAODBySystemPolicies()) return NO;
    return isAODMasterEnabled() ? YES : %orig; 
}

- (long long)visualState {
    long long state = %orig;
    if (isAODMasterEnabled() && state == 0) {
        if (gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) {
            return 2;
        }
    }
    return state;
}
%end

%end // Group_Backboardd

//==============================================================
// 3. TẦNG SPRINGBOARD: KHOÁ ĐỘ TƯƠNG PHẢN ĐỒNG HỒ, TIỆM CẬN & CHẠM 2 LẦN
//==============================================================

%group Group_SpringBoard

static __weak CSCoverSheetViewController *gCoverSheetVC = nil;
static __weak CSCombinedListViewController *gCombinedListVC = nil;
static id gCachedFlipbookSpec = nil;

// -------------------------------------------------------------
// KHỞI ĐỘNG AN TOÀN: CHẶN AOD CAN THIỆP KHI SPRINGBOARD ĐANG BOOT
// -------------------------------------------------------------
%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    gSpringBoardDidFinishLaunching = YES;
}

%end

// -------------------------------------------------------------
// ĐIỀU PHỐI STATUS BAR COVERSHEET: ÉP HIỆN Ở MÀN HÌNH KHÓA SÁNG
// -------------------------------------------------------------
%hook CSStatusBarViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (gCurrentState != AODStateActive) {
        self.view.alpha = 1.0f;
        self.view.hidden = NO;
    }
}

%end

// -------------------------------------------------------------
// COVERSHEET: TÁCH BIỆT RÕ RÀNG MÀN HÌNH KHÓA SÁNG VÀ AOD TĨNH
// -------------------------------------------------------------
%hook CSCoverSheetViewController

- (void)viewDidLoad {
    %orig;
    gCoverSheetVC = self;
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    AODSetState(AODStateIdle);
    @try {
        UIViewController *statusBarVC = [self valueForKey:@"_statusBarViewController"];
        if (statusBarVC) {
            statusBarVC.view.alpha = 1.0f;
            statusBarVC.view.hidden = NO;
        }
        UIViewController *homeAffordanceVC = [self valueForKey:@"_homeAffordanceViewController"];
        if (homeAffordanceVC) homeAffordanceVC.view.alpha = 1.0f;

        UIViewController *quickActionsVC = [self valueForKey:@"_quickActionsViewController"];
        if (quickActionsVC) quickActionsVC.view.alpha = 1.0f;
    } @catch (NSException *e) {}
}

// TUYỆT ĐỐI CHỈ COI LÀ AOD KHI ĐÃ VÀO AOD TĨNH HOÀN TOÀN
- (BOOL)isAlwaysOnPresentation { 
    if (shouldSuppressAODBySystemPolicies() || gCurrentState == AODStateIdle) return NO;
    return (isAODMasterEnabled() && gCurrentState == AODStateActive) ? YES : %orig; 
}

- (BOOL)shouldDimForAlwaysOn { 
    if (gCurrentState == AODStateIdle) return NO;
    return (isAODMasterEnabled() && gCurrentState == AODStateActive) ? YES : %orig; 
}

- (BOOL)coverSheetIsObscured {
    if (gCurrentState == AODStateActive) return NO;
    return %orig;
}

- (long long)backlightLuminance {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) return 1;
    return %orig;
}

// CHUYỂN CẢNH LẶN SÁNG CHUẨN GỐC (0.45s)
- (void)_updateAppearanceForAODTransitionToInactive:(BOOL)inactive {
    %orig(inactive);
    if (!isAODMasterEnabled()) return;

    if (shouldSuppressAODBySystemPolicies()) {
        AODSetState(AODStateProximityOff);
        return;
    }

    if (inactive) {
        if (gCurrentState == AODStateActive) return;
        AODSetState(AODStateTransitioning);

        // Chu trình bấm khóa: Màn hình co nhẹ 0.985 và lặn dịu sáng trong 0.45s
        [UIView animateWithDuration:0.45f delay:0.0f options:UIViewAnimationOptionCurveEaseInOut animations:^{
            self.view.transform = CGAffineTransformMakeScale(0.985f, 0.985f);
            @try {
                [self _animateView:self.view toWhitePointReduced:YES withDuration:0.45f withDispatchGroup:nil];
                [self _updateWallpaperEffectView];
                [self _updateDateTimeView];
                [self _updateComplicationsContainerView];
            } @catch (NSException *e) {}
        } completion:^(BOOL finished) {
            if (finished && gCurrentState == AODStateTransitioning) {
                AODLOG(@"transition finished -> AODStateActive");
                // ĐÃ VÀO AOD HOÀN TOÀN -> LÚC NÀY MỚI ĐƯỢC PHÉP ẨN STATUS BAR VÀ PHÍM TẮT
                AODSetState(AODStateActive);
                @try {
                    UIViewController *statusBarVC = [self valueForKey:@"_statusBarViewController"];
                    if (statusBarVC) {
                        [UIView animateWithDuration:0.2f animations:^{
                            statusBarVC.view.alpha = 0.0f;
                        }];
                    }

                    UIViewController *homeAffordanceVC = [self valueForKey:@"_homeAffordanceViewController"];
                    if (homeAffordanceVC) homeAffordanceVC.view.alpha = 0.0f;

                    UIViewController *quickActionsVC = [self valueForKey:@"_quickActionsViewController"];
                    if (quickActionsVC) quickActionsVC.view.alpha = 0.0f;
                } @catch (NSException *e) {}
            }
        }];
    } else {
        // ĐÁNH THỨC SÁNG MÀN HÌNH KHÓA: HIỆN LẠI ĐẦY ĐỦ 100% GIAO DIỆN NGAY LẬP TỨC
        AODSetState(AODStateIdle);

        @try {
            UIViewController *statusBarVC = [self valueForKey:@"_statusBarViewController"];
            if (statusBarVC) {
                statusBarVC.view.alpha = 1.0f;
                statusBarVC.view.hidden = NO;
            }

            UIViewController *homeAffordanceVC = [self valueForKey:@"_homeAffordanceViewController"];
            if (homeAffordanceVC) {
                homeAffordanceVC.view.alpha = 1.0f;
                homeAffordanceVC.view.hidden = NO;
            }

            UIViewController *quickActionsVC = [self valueForKey:@"_quickActionsViewController"];
            if (quickActionsVC) {
                quickActionsVC.view.alpha = 1.0f;
                quickActionsVC.view.hidden = NO;
            }
        } @catch (NSException *e) {}

        [UIView animateWithDuration:0.35f delay:0.0f options:UIViewAnimationOptionCurveEaseOut animations:^{
            self.view.transform = CGAffineTransformIdentity;
            @try {
                [self _animateView:self.view toWhitePointReduced:NO withDuration:0.35f withDispatchGroup:nil];
                [self _updateWallpaperEffectView];
                [self _updateDateTimeView];
                [self _updateComplicationsContainerView];
            } @catch (NSException *e) {}
        } completion:nil];
    }
}

// BẢO VỆ DANH SÁCH THÔNG BÁO VÀ STATUS BAR KHI Ở IDLE
- (void)_updateContent {
    %orig;

    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        @try {
            UIViewController *combinedListVC = [self valueForKey:@"_combinedListViewController"];
            if (combinedListVC) {
                combinedListVC.view.hidden = !isNotificationsEnabled();
                combinedListVC.view.alpha = isNotificationsEnabled() ? 1.0f : 0.0f;
            }
        } @catch (NSException *e) {}
    } else if (gCurrentState == AODStateIdle) {
        // Màn hình khóa sáng: Đảm bảo Status Bar và Home Bar luôn hiển thị 100%
        @try {
            UIViewController *statusBarVC = [self valueForKey:@"_statusBarViewController"];
            if (statusBarVC && statusBarVC.view.alpha != 1.0f) {
                statusBarVC.view.alpha = 1.0f;
                statusBarVC.view.hidden = NO;
            }
            UIViewController *homeAffordanceVC = [self valueForKey:@"_homeAffordanceViewController"];
            if (homeAffordanceVC && homeAffordanceVC.view.alpha != 1.0f) {
                homeAffordanceVC.view.alpha = 1.0f;
                homeAffordanceVC.view.hidden = NO;
            }
        } @catch (NSException *e) {}
    }
}

// XỬ LÝ HÌNH NỀN & LÀM MỜ THEO CÔNG TẮC
- (void)_updateWallpaperEffectView {
    %orig;
    
    UIView *floatingLayer = nil;
    UIView *effectView = nil;
    UIView *bgView = nil;
    @try {
        floatingLayer = [self valueForKey:@"_wallpaperFloatingLayerContainerView"];
        effectView = [self valueForKey:@"_wallpaperEffectView"];
        bgView = [self valueForKey:@"_backgroundView"];
    } @catch (NSException *e) {}

    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        if (!isWallpaperEnabled()) {
            if (floatingLayer) floatingLayer.alpha = 0.0f;
            if (bgView) bgView.alpha = 0.0f;
            if (effectView) {
                effectView.hidden = NO;
                effectView.backgroundColor = [UIColor blackColor];
                effectView.alpha = 1.0f;
            }
            self.view.backgroundColor = [UIColor blackColor];
        } else {
            if (floatingLayer) floatingLayer.alpha = 1.0f;
            if (bgView) bgView.alpha = 1.0f;
            if (effectView) {
                effectView.hidden = NO;
                if (isBlurWallpaperEnabled()) {
                    effectView.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.45f];
                    effectView.alpha = 1.0f;
                } else {
                    effectView.backgroundColor = [UIColor clearColor];
                    effectView.alpha = 0.0f;
                }
            }
            self.view.backgroundColor = [UIColor clearColor];
        }
    } else {
        if (floatingLayer) floatingLayer.alpha = 1.0f;
        if (bgView) bgView.alpha = 1.0f;
        if (effectView) {
            effectView.backgroundColor = [UIColor clearColor];
            effectView.alpha = 0.0f;
        }
        self.view.backgroundColor = [UIColor clearColor];
        self.view.transform = CGAffineTransformIdentity;
    }
}

// GIỮ NGUYÊN %orig ĐỂ CHỐNG NÉM NGOẠI LỆ MUTABLESET GÂY SIGABRT
- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession {
    return %orig;
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    AODSetState(AODStateIdle);
    self.view.transform = CGAffineTransformIdentity;
    @try {
        UIViewController *statusBarVC = [self valueForKey:@"_statusBarViewController"];
        if (statusBarVC) {
            statusBarVC.view.alpha = 1.0f;
            statusBarVC.view.hidden = NO;
        }
    } @catch (NSException *e) {}
}

%end

// -------------------------------------------------------------
// THÔNG BÁO: CHỐNG RESPRING, TUÂN THỦ CÔNG TẮC GỐC
// -------------------------------------------------------------
%hook CSCombinedListViewController

- (void)viewDidLoad {
    %orig;
    gCombinedListVC = self;
}

- (BOOL)showNotificationsInAlwaysOn {
    return isAODMasterEnabled() ? isNotificationsEnabled() : %orig;
}

- (void)setShowNotificationsInAlwaysOn:(BOOL)show {
    %orig(isAODMasterEnabled() ? isNotificationsEnabled() : show);
}

- (void)_setNotificationListHidden:(BOOL)hidden forReason:(id)reason {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        if (!isNotificationsEnabled()) {
            %orig(YES, reason);
            return;
        }
        %orig(NO, reason);
        return;
    }
    %orig(hidden, reason);
}

- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession {
    return %orig;
}

%end

// TRIỆT TIÊU TOÀN BỘ HÌNH NỀN CÒN SÓT TẠI TẦNG BACKGROUND CONTENT
%hook CSBackgroundContentViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    if (isAODMasterEnabled() && !isWallpaperEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        self.view.alpha = 0.0f;
        self.view.hidden = YES;
    }
}

- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession {
    return %orig;
}

%end

// GIỮ ĐỘ SÁNG RÕ NÉT CỦA WIDGET TRÊN MÀN HÌNH LCD
%hook CSComplicationContainerViewController

- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession {
    return %orig;
}

- (id)vibrancyConfiguration {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return nil;
    }
    return %orig;
}

%end

%hook CSActivityItemViewController

- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession {
    return %orig;
}

%end

// -------------------------------------------------------------
// ĐỒNG HỒ & WIDGET: CHỐNG ĐEN MÀN LCD, GIỮ TƯƠNG PHẢN CAO
// -------------------------------------------------------------
%hook SBFLockScreenDateView

- (id)vibrancyConfiguration {
    id orig = %orig;
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        if (orig && [orig respondsToSelector:@selector(copyWithLuminanceReduced:)]) {
            return [orig performSelector:@selector(copyWithLuminanceReduced:) withObject:@(NO)];
        }
    }
    return orig;
}

- (_UILegibilitySettings *)legibilitySettings {
    _UILegibilitySettings *orig = %orig;
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        UIColor *textColor = orig ? [orig primaryColor] : nil;
        if (textColor) {
            CGFloat r = 0, g = 0, b = 0, a = 0;
            [textColor getRed:&r green:&g blue:&b alpha:&a];
            if (r < 0.25f && g < 0.25f && b < 0.25f) {
                return [%c(_UILegibilitySettings) sharedInstanceForStyle:1];
            }
        }
        return orig;
    }
    return orig;
}

%end

%hook SBFLockScreenDateViewController

- (BOOL)restrictsVibrancy {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return NO;
    }
    return %orig;
}

- (_UILegibilitySettings *)legibilitySettings {
    _UILegibilitySettings *orig = %orig;
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        UIColor *textColor = orig ? [orig primaryColor] : nil;
        if (textColor) {
            CGFloat r = 0, g = 0, b = 0, a = 0;
            [textColor getRed:&r green:&g blue:&b alpha:&a];
            if (r < 0.25f && g < 0.25f && b < 0.25f) {
                return [%c(_UILegibilitySettings) sharedInstanceForStyle:1];
            }
        }
        return orig;
    }
    return orig;
}

- (void)_updateWithFrameSpecifier:(id)arg1 {
    %orig(arg1);
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        [self updateTimeNow];
    }
}

- (void)updateTimeNow {
    %orig;
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        gBurnInShiftStep++;
        double angle = (gBurnInShiftStep % 8) * (M_PI / 4.0);
        CGFloat dx = (CGFloat)(cos(angle) * 0.35f);
        CGFloat dy = (CGFloat)(sin(angle) * 0.30f);
        
        [UIView animateWithDuration:1.0f animations:^{
            self.view.transform = CGAffineTransformMakeTranslation(dx, dy);
        }];
    } else {
        self.view.transform = CGAffineTransformIdentity;
    }
}

%end

%hook SBLockScreenViewControllerBase

- (void)setBacklightLevel:(float)level {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        %orig(getAODPanelBrightnessFactor() * 100.0f);
        return;
    }
    %orig(level);
}

%end

%hook SBDashBoardLockScreenEnvironment

- (void)setBacklightLevel:(float)level {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        %orig(getAODPanelBrightnessFactor() * 100.0f);
        return;
    }
    %orig(level);
}

%end

%hook UIApplication

- (void)setBacklightLevel:(float)level {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        %orig(getAODPanelBrightnessFactor() * 100.0f);
        return;
    }
    %orig(level);
}

%end

// -------------------------------------------------------------
// ĐIỀU PHỐI ĐỘ SÁNG MÀN HÌNH VÀ VÒNG ĐỜI AOD (PHÂN BIỆT RÕ RÀNG TRẠNG THÁI)
// -------------------------------------------------------------
%hook SBBacklightController

- (void)_updateHIDUISensorModeForBacklightState:(long long)state source:(long long)source {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        %orig(1, source);
        return;
    }
    %orig(state, source);
}

- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion {
    if (isAODMasterEnabled()) {
        if (state == 0) {
            // Chu trình khóa màn hình: Bắt đầu chuyển cảnh vào AOD
            if (gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) {
                AODSetState(AODStateTransitioning);
                AODLOG(@"lock -> begin AOD transition");

                if (gCoverSheetVC && [gCoverSheetVC respondsToSelector:@selector(_updateAppearanceForAODTransitionToInactive:)]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [gCoverSheetVC _updateAppearanceForAODTransitionToInactive:YES];
                    });
                } else {
                    AODLOG(@"no coversheet hook available, relying on safety net");
                }

                // Lưới an toàn: không để trạng thái kẹt ở Transitioning nếu hoạt ảnh không hoàn tất
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (gCurrentState == AODStateTransitioning) {
                        AODSetState(AODStateActive);
                        AODLOG(@"safety net -> AODStateActive");
                    }
                });

                state = 2; // Giữ State AOD của BacklightServices để không dập tắt màn hình
            }
        } else if (state == 1 || state == 3) {
            // Mở màn hình khóa sáng hoặc nhấc máy: LẬP TỨC TRẢ VỀ IDLE VÀ KHÔI PHỤC GIAO DIỆN
            AODSetState(AODStateIdle);
            gCurrentAODProgress = 1.0f;
            if (gCoverSheetVC && [gCoverSheetVC respondsToSelector:@selector(_updateAppearanceForAODTransitionToInactive:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [gCoverSheetVC _updateAppearanceForAODTransitionToInactive:NO];
                });
            }
        }
    }
    %orig(state, source, YES, completion);
}

- (float)_factorToPublishForBacklightState:(long long)state {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        if (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies()) {
            return 0.0f;
        }
        return getAODPanelBrightnessFactor();
    }
    return %orig(state);
}

- (void)animateBacklightToFactor:(float)factor duration:(double)duration source:(long long)source completion:(id)completion {
    if (isAODMasterEnabled()) {
        if (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning) {
            if (factor <= 0.05f) {
                factor = (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies()) ? 0.0f : getAODPanelBrightnessFactor();
            }
        }
        if (factor > 0.9f && gCurrentState == AODStateActive) {
            AODLOG(@"backlight back to full -> Idle");
            AODSetState(AODStateIdle);
        }
    }
    %orig(factor, duration, source, completion);
}

%end

%hook BLSBacklightFBSSceneEnvironment

- (BOOL)supportsAlwaysOn { 
    if (shouldSuppressAODBySystemPolicies()) return NO;
    return isAODMasterEnabled() ? YES : %orig; 
}

- (BOOL)isDisplayBlanked {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) return NO;
    return %orig;
}

- (long long)visualState {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return (shouldSuppressAODBySystemPolicies() || gCurrentState == AODStateProximityOff) ? 0 : 2;
    }
    return %orig;
}

%end

%hook SBBacklightPlatformProvider

- (id)initWithBacklightEnvironmentSessionProvider:(id)provider {
    if (provider) {
        gInjectedSessionProvider = provider;
    }
    return %orig(provider);
}

- (BOOL)deviceSupportsAlwaysOn { return isAODMasterEnabled() ? YES : %orig; }

- (BOOL)isAlwaysOnEnabled { 
    if (shouldSuppressAODBySystemPolicies()) return NO;
    return isAODMasterEnabled() ? YES : %orig; 
}

- (id)flipbookSpecification {
    id orig = %orig;
    if (orig) return orig;
    
    if (isAODMasterEnabled()) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            Class specClass = NSClassFromString(@"BLSHFlipbookSpecification");
            if (specClass) {
                @try {
                    gCachedFlipbookSpec = [[specClass alloc] init];
                } @catch (NSException *e) {}
            }
        });
        return gCachedFlipbookSpec;
    }
    return nil;
}

- (id)sessionProvider {
    id orig = %orig;
    if (orig) return orig;
    if (isAODMasterEnabled()) {
        if (gInjectedSessionProvider) return gInjectedSessionProvider;
        Class providerClass = NSClassFromString(@"SBBacklightEnvironmentSessionProvider");
        if (providerClass && [providerClass respondsToSelector:@selector(sharedInstance)]) {
            return [providerClass performSelector:@selector(sharedInstance)];
        }
    }
    return orig;
}

- (BOOL)isShowingBlankingWindow {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) return NO;
    return %orig;
}

- (void)showBlankingWindow:(BOOL)show withFadeDuration:(double)duration {
    if (isAODMasterEnabled() && show && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) return;
    %orig(show, duration);
}

- (void)_setBlankingWindowVisible:(BOOL)visible fadeDuration:(double)duration {
    if (isAODMasterEnabled() && visible && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) return;
    %orig(visible, duration);
}

- (BOOL)isUsingAlwaysOnBrightnessCurve {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) return YES;
    return %orig;
}

%end

// -------------------------------------------------------------
// CHÍNH SÁCH HỆ THỐNG: TUÂN THỦ TỰ ĐỘNG TẮT CỦA APPLE
// -------------------------------------------------------------
%hook SBLowPowerModeAlwaysOnPolicy

- (BOOL)isAlwaysOnPolicyActive {
    return [[NSProcessInfo processInfo] isLowPowerModeEnabled] ? YES : %orig;
}

%end

%hook SBFocusModeAlwaysOnPolicy

- (BOOL)isAlwaysOnPolicyActive {
    return %orig;
}

%end

%hook SBThermalAlwaysOnPolicy

- (BOOL)isAlwaysOnPolicyActive {
    return %orig;
}

%end

%hook SBLockScreenManager

- (BOOL)shouldPreventBacklightBlankingForAlwaysOn { 
    if (shouldSuppressAODBySystemPolicies() || gCurrentState == AODStateProximityOff) return NO;
    return (isAODMasterEnabled() && gCurrentState == AODStateActive) ? YES : %orig; 
}

- (void)lockUIFromSource:(int)source withOptions:(id)options {
    if (isAODMasterEnabled() && shouldSuppressAODBySystemPolicies()) {
        AODSetState(AODStateProximityOff);
    }
    %orig;
}

- (void)unlockUIFromSource:(int)source withOptions:(id)options {
    AODSetState(AODStateIdle);
    %orig;
}

%end

// -------------------------------------------------------------
// CHẠM 2 LẦN BẬT SÁNG & SỬA TRIỆT ĐỂ LIỆT CẢM ỨNG
// -------------------------------------------------------------
%hook SBTapToWakeController

- (BOOL)isTapToWakeSupported { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)shouldTapToWake { return isAODMasterEnabled() ? YES : %orig; }

- (void)setTapToWakeGestureRecognizer:(UITapGestureRecognizer *)gesture {
    if (isAODMasterEnabled() && [gesture isKindOfClass:[UITapGestureRecognizer class]]) {
        gesture.numberOfTapsRequired = 2; // Nhấp đúp 2 lần mới sáng
    }
    %orig(gesture);
}

- (void)setDigitizerInTapToWakeMode:(BOOL)mode {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        %orig(YES); // Giữ cảm ứng digitizer mở khi ở AOD
        return;
    }
    %orig(mode);
}

- (void)tapToWakeDidRecognize:(UITapGestureRecognizer *)gesture {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        if ([gesture state] == UIGestureRecognizerStateRecognized || [gesture state] == UIGestureRecognizerStateEnded) {
            // Chạm đúp 2 lần ở AOD: Chuyển ngay về Idle và bật sáng màn hình khóa
            AODSetState(AODStateIdle);
            [[%c(SBBacklightController) sharedInstance] setBacklightState:1 source:13 animated:YES completion:nil];
            
            SBLockScreenManager *lsm = [%c(SBLockScreenManager) sharedInstance];
            if ([lsm respondsToSelector:@selector(tapToWakeControllerDidRecognizeWakeGesture:)]) {
                [lsm tapToWakeControllerDidRecognizeWakeGesture:gesture];
            } else if ([lsm respondsToSelector:@selector(_wakeScreenForTapToWake)]) {
                [lsm _wakeScreenForTapToWake];
            }
        }
    }
    %orig(gesture);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    // Khi đang ở AOD: Bắt buộc nhận touch để đón nhận chạm 2 lần
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return YES;
    }
    // Màn hình khóa sáng hoặc màn hình chính: Trả quyền hoàn toàn cho hệ thống (CHỐNG LIỆT CẢM ỨNG)
    return %orig;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

%end

// -------------------------------------------------------------
// CẢM BIẾN TIỆM CẬN: CHE CAMERA LẬP TỨC TẮT ĐEN TOÀN BỘ
// -------------------------------------------------------------
%hook SBProximitySensorManager

- (BOOL)isProximityDetectionPermitted {
    if (isAODMasterEnabled() && gCurrentState != AODStateIdle) return YES;
    return %orig;
}

- (BOOL)isProximityDetectionEnabled {
    if (isAODMasterEnabled() && gCurrentState != AODStateIdle) return YES;
    return %orig;
}

- (void)_setObjectInProximity:(BOOL)inProximity detectionMode:(int)mode {
    %orig(inProximity, mode);
    if (!isAODMasterEnabled() || gCurrentState == AODStateIdle) return;
    
    if (inProximity) {
        AODSetState(AODStateProximityOff);
        [[%c(SBBacklightController) sharedInstance] setBacklightState:0 source:1 animated:NO completion:nil];
    } else {
        if (!shouldSuppressAODBySystemPolicies()) {
            AODSetState(AODStateActive);
            [[%c(SBBacklightController) sharedInstance] setBacklightState:2 source:1 animated:YES completion:nil];
        }
    }
}

%end

// -------------------------------------------------------------
// CÔ LẬP CẢM ỨNG & EVENT: CHỈ HOẠT ĐỘNG TRÊN LOCKSCREEN
// -------------------------------------------------------------
%hook SBUIController

- (BOOL)handleHomeButtonDoublePressRequest {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return NO;
    }
    return %orig;
}

%end

%end // Group_SpringBoard

//==============================================================
// 4. TẦNG POSTERBOARD: LÀM TỐI & ÉP MỜ HÌNH NỀN THEO CÔNG TẮC GỐC
//==============================================================

%group Group_PosterBoard

%hook PRPosterEnvironmentImpl

- (CGFloat)backlightProgress {
    if (isAODMasterEnabled()) {
        // Tắt hình nền: Dập tắt hoàn toàn về 0%
        if (!isWallpaperEnabled()) return 0.0f;
        
        // Bật hình nền: Chạy độ sáng dịu AOD theo tiến trình
        if (gCurrentState == AODStateActive) return 0.20f;
        if (gCurrentState == AODStateTransitioning) return gCurrentAODProgress;
    }
    return %orig;
}

- (CGFloat)linearBacklightProgress {
    if (isAODMasterEnabled()) {
        if (!isWallpaperEnabled()) return 0.0f;
        if (gCurrentState == AODStateActive) return 0.20f;
        if (gCurrentState == AODStateTransitioning) return gCurrentAODProgress;
    }
    return %orig;
}

- (long long)luminance {
    if (isAODMasterEnabled()) {
        if (!isWallpaperEnabled()) return 0; // Tắt hình nền: Ép luminance = 0 (tối đen tuyệt đối)
        if (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning) return 1;
    }
    return %orig;
}

- (BOOL)isLowLuminance {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return YES;
    }
    return %orig;
}

// BẬT LÀM MỜ HÌNH NỀN TRỰC TIẾP TRÊN LOCK SCREEN POSTER
- (BOOL)isLegibilityBlurEnabled {
    if (isAODMasterEnabled() && isBlurWallpaperEnabled()) {
        return YES;
    }
    return %orig;
}

%end

// HOOK CHUẨN XÁC VÀO APPEARANCE CỦA POSTER MÀN HÌNH KHÓA
%hook PRPosterLockPosterAppearance

- (BOOL)isLegibilityBlurEnabled {
    if (isAODMasterEnabled() && isBlurWallpaperEnabled()) {
        return YES;
    }
    return %orig;
}

- (BOOL)allowsModifyingLegibilityBlur {
    return YES;
}

%end

// HOOK BỔ TRỢ ĐỒNG BỘ CONFIGURATION GỐC
%hook PRPosterConfiguration

- (BOOL)isLegibilityBlurEnabled {
    if (isAODMasterEnabled() && isBlurWallpaperEnabled()) {
        return YES;
    }
    return %orig;
}

%end

%end // Group_PosterBoard

//==============================================================
// 5. TẦNG PREFERENCES: CHUẨN GỐC APPLE, TỰ HIỆN TRANG NGOÀI & BUNG MỤC CON
//==============================================================

// Con trỏ hook động runtime MobileGestalt
static Boolean (*orig_MGGetBoolAnswer)(CFStringRef property) = NULL;
static Boolean replaced_MGGetBoolAnswer(CFStringRef property) {
    if (property) {
        NSString *key = (__bridge NSString *)property;
        if ([key isEqualToString:@"AlwaysOnDisplaySupport"] || 
            [key isEqualToString:@"DeviceSupportsAlwaysOn"] ||
            [key isEqualToString:@"oPeik/9e8lQWMszEjbPzng"]) {
            return YES;
        }
    }
    return orig_MGGetBoolAnswer ? orig_MGGetBoolAnswer(property) : NO;
}

//==============================================================
// 5a. HELPER DỰNG CÔNG TẮC / THANH TRƯỢT (dùng chung cho trang AOD)
//==============================================================

static NSString *aodHzFooter(void) {
    return [NSString stringWithFormat:@"Hiện tại: %.0f Hz (tần số quét khi AOD tĩnh)", (double)gCachedCustomHz];
}

static NSString *aodBrightnessFooter(void) {
    return [NSString stringWithFormat:@"Mức %.0f (tương đương %.1f%% độ sáng panel)",
            (double)(gCachedBrightnessFactor * 1000.0f), (double)(gCachedBrightnessFactor * 100.0f)];
}

static PSSpecifier *makeAODSwitch(id target, NSString *title, NSString *key, NSString *sid) {
    PSSpecifier *s = [%c(PSSpecifier) preferenceSpecifierNamed:title
                                                        target:target
                                                           set:@selector(setAODValue:spec:)
                                                           get:@selector(getAODValue:)
                                                        detail:Nil
                                                          cell:6 // PSSwitchCell
                                                          edit:Nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:sid forKey:@"id"];
    [s setProperty:@YES forKey:@"default"];
    return s;
}

static PSSpecifier *makeAODSlider(id target, NSString *key, NSString *sid, float lo, float hi, int segments) {
    PSSpecifier *s = [%c(PSSpecifier) preferenceSpecifierNamed:nil
                                                        target:target
                                                           set:@selector(setAODValue:spec:)
                                                           get:@selector(getAODValue:)
                                                        detail:Nil
                                                          cell:5 // PSSliderCell
                                                          edit:Nil];
    [s setProperty:@"PSSliderTableCell" forKey:@"cellClass"];
    [s setProperty:key forKey:@"key"];
    [s setProperty:sid forKey:@"id"];
    [s setProperty:@(lo) forKey:@"min"];
    [s setProperty:@(hi) forKey:@"max"];
    [s setProperty:@YES forKey:@"isSegmented"];
    [s setProperty:@(segments) forKey:@"segmentCount"];
    [s setProperty:@YES forKey:@"showValue"];
    return s;
}

%group Group_Preferences

// ÉP HỆ THỐNG MỞ KHÓA TÍNH NĂNG AOD GỐC CHO PHẦN CÀI ĐẶT
%hook BLSBacklight
+ (BOOL)isAlwaysOnEnabledByHardware { return YES; }
%end

%hook BLSAlwaysOnFrequencyConfiguration
- (BOOL)isAlwaysOnEnabled { return YES; }
%end

%hook CBDisplayModule
+ (BOOL)isAlwaysOnDisplaySupported { return YES; }
%end

// HOOK TRỰC TIẾP VÀO CONTROLLER MÀN HÌNH: DBSMainDisplayPreferencesController
%hook DBSMainDisplayPreferencesController

- (NSMutableArray *)specifiers {
    NSArray *origSpecs = %orig;
    NSMutableArray *specs = origSpecs ? [origSpecs mutableCopy] : [NSMutableArray array];

    static NSString *const kAODEntryID = @"ALWAYS_ON_DISPLAY_ENTRY_ROW";
    for (PSSpecifier *s in specs) {
        if ([[s propertyForKey:@"id"] isEqualToString:kAODEntryID]) {
            return specs;
        }
    }

    Class detailClass = NSClassFromString(@"DBSAlwaysOnViewController");
    if (!detailClass) {
        dlopen("/System/Library/PrivateFrameworks/DisplayAndBrightnessSettings.framework/DisplayAndBrightnessSettings", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/Settings/DisplayAndBrightnessSettings.framework/DisplayAndBrightnessSettings", RTLD_NOW);
        detailClass = NSClassFromString(@"DBSAlwaysOnViewController");
    }

    if (detailClass) {
        PSSpecifier *aodSpec = [%c(PSSpecifier) preferenceSpecifierNamed:@"Màn hình Luôn bật"
                                                                  target:self 
                                                                     set:NULL 
                                                                     get:@selector(getAODMasterStatusText:) 
                                                                  detail:detailClass 
                                                                    cell:2 // PSLinkCell
                                                                    edit:Nil];
        [aodSpec setProperty:kAODEntryID forKey:@"id"];
        [aodSpec setProperty:detailClass forKey:@"detail"];
        [aodSpec setProperty:@YES forKey:@"isController"];
        [aodSpec setProperty:@YES forKey:@"enabled"];

        // Chèn vào vị trí kế sau mục "Đưa lên để bật" hoặc "Tự động khóa"
        NSInteger targetIndex = -1;
        for (NSInteger i = 0; i < (NSInteger)specs.count; i++) {
            NSString *sid = [[[specs objectAtIndex:i] propertyForKey:@"id"] description].uppercaseString;
            if ([sid containsString:@"RAISE_TO_WAKE"] || [sid containsString:@"WAKE"]) {
                targetIndex = i + 1;
                break;
            }
        }
        if (targetIndex < 0) {
            for (NSInteger i = 0; i < (NSInteger)specs.count; i++) {
                NSString *sid = [[[specs objectAtIndex:i] propertyForKey:@"id"] description].uppercaseString;
                if ([sid containsString:@"AUTOLOCK"] || [sid containsString:@"AUTO_LOCK"]) {
                    targetIndex = i + 1;
                    break;
                }
            }
        }

        if (targetIndex >= 0 && targetIndex <= (NSInteger)specs.count) {
            [specs insertObject:aodSpec atIndex:targetIndex];
        } else {
            [specs addObject:aodSpec];
        }
    }

    [self setValue:specs forKey:@"_specifiers"];
    return specs;
}

%new
- (id)getAODMasterStatusText:(PSSpecifier *)spec {
    return aodReadBool(CFSTR("enabled"), YES) ? @"Bật" : @"Tắt";
}

%end

// TRANG CON AOD: CÔNG TẮC & THANH TRƯỢT NỐI TRỰC TIẾP VÀO CẤU HÌNH TWEAK
%hook DBSAlwaysOnViewController

- (BOOL)shouldShowAlwaysOn {
    return YES;
}

%new
- (id)getAODValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (!key) return nil;
    if ([key isEqualToString:@"CustomAODRefreshRate"]) {
        return @(getCustomAODRefreshRate());
    }
    if ([key isEqualToString:@"CustomAODBrightness"]) {
        return @(getCustomAODBrightnessFactor() * 1000.0f);
    }
    return @(aodReadBool((__bridge CFStringRef)key, YES));
}

%new
- (void)setAODValue:(id)value spec:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (!key || !value) return;

    id out = nil;
    if ([key isEqualToString:@"CustomAODRefreshRate"]) {
        out = @(fmaxf(2.0f, fminf(5.0f, roundf([value floatValue]))));
    } else if ([key isEqualToString:@"CustomAODBrightness"]) {
        out = @(fmaxf(2.0f, fminf(30.0f, roundf([value floatValue]))));
    } else {
        out = @([value boolValue]);
    }

    aodWriteValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)out);
    loadAODPreferences();

    if ([key isEqualToString:@"enabled"]) {
        [self reloadSpecifiers]; // Bật/tắt master -> hiện/ẩn thanh trượt
        return;
    }

    NSString *groupID = nil;
    NSString *footer = nil;
    if ([key isEqualToString:@"CustomAODRefreshRate"]) {
        groupID = @"AOD_REAL_HZ_GROUP";
        footer = aodHzFooter();
    } else if ([key isEqualToString:@"CustomAODBrightness"]) {
        groupID = @"AOD_REAL_BRIGHTNESS_GROUP";
        footer = aodBrightnessFooter();
    }
    if (!groupID) return;

    for (PSSpecifier *s in [self specifiers]) {
        if ([[s propertyForKey:@"id"] isEqualToString:groupID]) {
            [s setProperty:footer forKey:@"footerText"];
            [self reloadSpecifier:s animated:NO];
            break;
        }
    }
}

- (NSMutableArray *)specifiers {
    NSArray *origSpecs = %orig;
    NSMutableArray *specs = origSpecs ? [origSpecs mutableCopy] : [NSMutableArray array];

    // 1. Gỡ công tắc gốc của Apple có cùng key/ID để tránh trùng dòng
    if ([self respondsToSelector:@selector(_alwaysOnDisplaySpecifier)]) {
        PSSpecifier *nativeMaster = [self _alwaysOnDisplaySpecifier];
        if (nativeMaster) [specs removeObject:nativeMaster];
    }
    NSSet *ownKeys = [NSSet setWithObjects:@"enabled", @"AlwaysOnDisplayEnabled",
                      @"ShowWallpaperInAlwaysOn", @"BlurWallpaperInAlwaysOn",
                      @"ShowNotificationsInAlwaysOn", nil];
    NSMutableArray *drop = [NSMutableArray array];
    for (PSSpecifier *s in specs) {
        NSString *sid = [s propertyForKey:@"id"];
        NSString *skey = [s propertyForKey:@"key"];
        if ([sid hasPrefix:@"AOD_REAL_"] || (skey && [ownKeys containsObject:skey])) {
            [drop addObject:s];
        }
    }
    [specs removeObjectsInArray:drop];

    // 2. Dựng lại đúng thứ tự:
    //    tiêu đề nhỏ -> công tắc "Màn hình luôn bật"
    //    -> (khi bật) tiêu đề nhỏ + 3 công tắc hiển thị -> Hz -> độ sáng
    NSMutableArray *mine = [NSMutableArray array];

    PSSpecifier *masterHeader = [%c(PSSpecifier) preferenceSpecifierNamed:@"MÀN HÌNH LUÔN BẬT"
                                                                    target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
    [masterHeader setProperty:@"AOD_REAL_MASTER_GROUP" forKey:@"id"];
    [mine addObject:masterHeader];
    [mine addObject:makeAODSwitch(self, @"Màn hình luôn bật", @"enabled", @"AOD_REAL_MASTER")];

    if (aodReadBool(CFSTR("enabled"), YES)) {
        PSSpecifier *displayHeader = [%c(PSSpecifier) preferenceSpecifierNamed:@"HIỂN THỊ KHI LUÔN BẬT"
                                                                        target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
        [displayHeader setProperty:@"AOD_REAL_DISPLAY_GROUP" forKey:@"id"];
        [mine addObject:displayHeader];
        [mine addObject:makeAODSwitch(self, @"Hiện hình nền", @"ShowWallpaperInAlwaysOn", @"AOD_REAL_WALLPAPER")];
        [mine addObject:makeAODSwitch(self, @"Làm mờ hình nền", @"BlurWallpaperInAlwaysOn", @"AOD_REAL_BLUR")];
        [mine addObject:makeAODSwitch(self, @"Hiện thông báo", @"ShowNotificationsInAlwaysOn", @"AOD_REAL_NOTIFY")];

        PSSpecifier *hzGroup = [%c(PSSpecifier) preferenceSpecifierNamed:@"TẦN SỐ QUÉT TĨNH (2 - 5 HZ)"
                                                                  target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
        [hzGroup setProperty:aodHzFooter() forKey:@"footerText"];
        [hzGroup setProperty:@"AOD_REAL_HZ_GROUP" forKey:@"id"];
        [mine addObject:hzGroup];
        [mine addObject:makeAODSlider(self, @"CustomAODRefreshRate", @"AOD_REAL_HZ", 2.0f, 5.0f, 3)];

        PSSpecifier *brGroup = [%c(PSSpecifier) preferenceSpecifierNamed:@"ĐỘ SÁNG MÀN HÌNH TĨNH AOD (2 - 30)"
                                                                  target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
        [brGroup setProperty:aodBrightnessFooter() forKey:@"footerText"];
        [brGroup setProperty:@"AOD_REAL_BRIGHTNESS_GROUP" forKey:@"id"];
        [mine addObject:brGroup];
        [mine addObject:makeAODSlider(self, @"CustomAODBrightness", @"AOD_REAL_BRIGHTNESS", 2.0f, 30.0f, 28)];
    }

    [specs insertObjects:mine atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, mine.count)]];
    @try {
        [self setValue:specs forKey:@"_specifiers"];
    } @catch (NSException *e) {
        AODLOG(@"set _specifiers failed: %@", e);
    }
    AODLOG(@"AOD subpage specifiers: %lu", (unsigned long)specs.count);
    return specs;
}

%end // DBSAlwaysOnViewController

%end // Group_Preferences

//==============================================================
// 6. KHỞI TẠO TIẾN TRÌNH & ĐỒNG BỘ CẤU HÌNH REALTIME
//==============================================================

static void AODPreferencesReloadCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    loadAODPreferences();
}

static void initGroupPreferencesExplicitly(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PreferenceBundles/Display.bundle/Display", RTLD_NOW | RTLD_GLOBAL);
        dlopen("/System/Library/PrivateFrameworks/DisplayAndBrightnessSettings.framework/DisplayAndBrightnessSettings", RTLD_NOW | RTLD_GLOBAL);
        dlopen("/System/Library/PrivateFrameworks/Settings/DisplayAndBrightnessSettings.framework/DisplayAndBrightnessSettings", RTLD_NOW | RTLD_GLOBAL);

        Class dbsClass = objc_getClass("DBSMainDisplayPreferencesController");
        Class aodClass = objc_getClass("DBSAlwaysOnViewController");
        %init(Group_Preferences, 
              DBSMainDisplayPreferencesController = dbsClass,
              DBSAlwaysOnViewController = aodClass);
    });
}

// Hook đón đầu tại tầng PSListController để kích hoạt ngay khi trang hiển thị nạp
%group Group_PreferencesLoader
%hook PSListController
- (void)viewDidLoad {
    %orig;
    if ([self isKindOfClass:objc_getClass("DBSMainDisplayPreferencesController")]) {
        initGroupPreferencesExplicitly();
        [self reloadSpecifiers];
    }
}
%end
%end

%ctor {
    @autoreleasepool {
        NSString *processName = [[NSProcessInfo processInfo] processName];
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

        loadAODPreferences();
        gAODDebug = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/aod_debug"];

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            (CFNotificationCallback)AODStateCallback,
            CFSTR("com.jb.aodreal/state"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            (CFNotificationCallback)AODPreferencesReloadCallback,
            CFSTR("com.jb.aodreal/preferences.changed"),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        if ([bundleID isEqualToString:@"com.apple.springboard"] || [processName isEqualToString:@"SpringBoard"]) {
            gIsSpringBoardProcess = YES;
            AODSetState(AODStateIdle);
            %init(Group_SpringBoard);
        } else if ([bundleID isEqualToString:@"com.apple.PosterBoard"] || 
                   [processName.lowercaseString containsString:@"posterboard"]) {
            %init(Group_PosterBoard);
        } else if ([processName isEqualToString:@"backboardd"]) {
            %init(Group_Backboardd);
        } else if ([bundleID isEqualToString:@"com.apple.Preferences"] || 
                   [processName.lowercaseString containsString:@"preferences"]) {
            
            // 1. Hook MobileGestalt động
            void *gestaltHandle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
            if (gestaltHandle) {
                void *mgFunc = dlsym(gestaltHandle, "MGGetBoolAnswer");
                if (mgFunc) {
                    MSHookFunction(mgFunc, (void *)replaced_MGGetBoolAnswer, (void **)&orig_MGGetBoolAnswer);
                }
            }

            // 2. Ép load các bundle liên quan đến Display của Preferences
            [[NSBundle bundleWithPath:@"/System/Library/PreferenceBundles/Display.bundle"] load];
            dlopen("/System/Library/PreferenceBundles/Display.bundle/Display", RTLD_NOW | RTLD_GLOBAL);
            dlopen("/System/Library/PrivateFrameworks/DisplayAndBrightnessSettings.framework/DisplayAndBrightnessSettings", RTLD_NOW | RTLD_GLOBAL);
            dlopen("/System/Library/PrivateFrameworks/Settings/DisplayAndBrightnessSettings.framework/DisplayAndBrightnessSettings", RTLD_NOW | RTLD_GLOBAL);

            // 3. Khởi tạo hook trực tiếp nếu class đã có, hoặc dùng loader đón đầu khi view load
            if (objc_getClass("DBSMainDisplayPreferencesController")) {
                initGroupPreferencesExplicitly();
            } else {
                %init(Group_PreferencesLoader);
            }
        }
    }
}
