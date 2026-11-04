#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAFrameRateRange.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <spawn.h>
#import <substrate.h>

//==============================================================
// 0. BỘ ĐIỀU PHỐI TRẠNG THÁI & ĐỌC CÀI ĐẶT GỐC APPLE
//==============================================================

typedef NS_ENUM(NSInteger, AODState) {
    AODStateIdle = 0,
    AODStateTransitioning,
    AODStateActive,
    AODStateProximityOff
};

static AODState gCurrentState = AODStateIdle;
static CGFloat gCurrentAODProgress = 1.0f;
static NSInteger gBurnInShiftStep = 0;
static id gInjectedSessionProvider = nil;

static BOOL gSpringBoardDidFinishLaunching = NO;
static BOOL gIsSpringBoardProcess = NO;

static BOOL gCachedAODEnabled = YES;
static BOOL gCachedWallpaperEnabled = YES;
static BOOL gCachedBlurWallpaperEnabled = YES;
static BOOL gCachedNotificationsEnabled = YES;
static float gCachedCustomHz = 1.0f;
static float gCachedBrightnessFactor = 0.005f;

static inline void loadAODPreferences(void) {
    Boolean valid = false;
    
    Boolean masterVal = CFPreferencesGetAppBooleanValue(CFSTR("AlwaysOnDisplayEnabled"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) masterVal = CFPreferencesGetAppBooleanValue(CFSTR("enabled"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) masterVal = CFPreferencesGetAppBooleanValue(CFSTR("enabled"), CFSTR("com.jb.aodreal"), &valid);
    gCachedAODEnabled = valid ? (BOOL)masterVal : YES;

    valid = false;
    Boolean wpVal = CFPreferencesGetAppBooleanValue(CFSTR("ShowWallpaperInAlwaysOn"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) wpVal = CFPreferencesGetAppBooleanValue(CFSTR("ShowWallpaperInAlwaysOn"), CFSTR("com.jb.aodreal"), &valid);
    gCachedWallpaperEnabled = valid ? (BOOL)wpVal : YES;

    valid = false;
    Boolean blurVal = CFPreferencesGetAppBooleanValue(CFSTR("BlurWallpaperInAlwaysOn"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) blurVal = CFPreferencesGetAppBooleanValue(CFSTR("BlurWallpaperInAlwaysOn"), CFSTR("com.jb.aodreal"), &valid);
    gCachedBlurWallpaperEnabled = valid ? (BOOL)blurVal : YES;

    valid = false;
    Boolean notiVal = CFPreferencesGetAppBooleanValue(CFSTR("ShowNotificationsInAlwaysOn"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) notiVal = CFPreferencesGetAppBooleanValue(CFSTR("ShowNotificationsInAlwaysOn"), CFSTR("com.jb.aodreal"), &valid);
    gCachedNotificationsEnabled = valid ? (BOOL)notiVal : YES;

    CFPropertyListRef hzVal = CFPreferencesCopyAppValue(CFSTR("CustomAODRefreshRate"), CFSTR("com.jb.aodreal"));
    if (hzVal) {
        if (CFGetTypeID(hzVal) == CFNumberGetTypeID()) {
            float r = [(__bridge NSNumber *)hzVal floatValue];
            if (r >= 1.0f && r <= 5.0f) gCachedCustomHz = r;
        }
        CFRelease(hzVal);
    } else {
        gCachedCustomHz = 1.0f;
    }

    CFPropertyListRef brVal = CFPreferencesCopyAppValue(CFSTR("CustomAODBrightness"), CFSTR("com.jb.aodreal"));
    if (brVal) {
        if (CFGetTypeID(brVal) == CFNumberGetTypeID()) {
            float b = [(__bridge NSNumber *)brVal floatValue];
            if (b >= 0.5f && b <= 20.0f) gCachedBrightnessFactor = b / 1000.0f;
        }
        CFRelease(brVal);
    } else {
        gCachedBrightnessFactor = 0.005f;
    }
}

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

static inline BOOL shouldSuppressAODBySystemPolicies(void) {
    if ([[NSProcessInfo processInfo] isLowPowerModeEnabled]) return YES;
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
                        CFRelease(powerSourcesList); CFRelease(powerInfo); return NO;
                    }
                    CFNumberRef curCapNum = (CFNumberRef)CFDictionaryGetValue(desc, CFSTR(kIOPSCurrentCapacityKey));
                    CFNumberRef maxCapNum = (CFNumberRef)CFDictionaryGetValue(desc, CFSTR(kIOPSMaxCapacityKey));
                    if (curCapNum && maxCapNum) {
                        int cur = 0, max = 100;
                        CFNumberGetValue(curCapNum, kCFNumberIntType, &cur);
                        CFNumberGetValue(maxCapNum, kCFNumberIntType, &max);
                        if (max > 0 && ((cur * 100) / max) <= 5) {
                            CFRelease(powerSourcesList); CFRelease(powerInfo); return YES;
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

//==============================================================
// 1. KHAI BÁO CÁC LỚP VÀ GIAO DIỆN HỆ THỐNG
//==============================================================
@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)title target:(id)target set:(SEL)set get:(SEL)get detail:(Class)detail cell:(long long)cell edit:(Class)edit;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end

@interface PSListController : UIViewController
- (NSMutableArray *)specifiers;
- (void)reloadSpecifiers;
- (void)reloadSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
- (void)insertSpecifier:(PSSpecifier *)specifier atIndex:(NSInteger)index animated:(BOOL)animated;
- (void)addSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
@end

@interface DBSMainDisplayPreferencesController : PSListController
- (BOOL)_deviceSupportsAlwaysOn;
- (BOOL)deviceSupportsAlwaysOn;
- (BOOL)supportsAlwaysOnDisplay;
- (BOOL)shouldShowAlwaysOn;
@end

@interface DBRDisplayController : PSListController
- (BOOL)shouldShowAlwaysOnDisplay;
- (BOOL)shouldShowAlwaysOnDisplaySpecifier;
- (BOOL)isAlwaysOnDisplaySupported;
@end

@interface DBSAlwaysOnViewController : PSListController
- (PSSpecifier *)_alwaysOnDisplaySpecifier;
- (PSSpecifier *)_showWallpaperSpecifier;
- (PSSpecifier *)_showNotificationsSpecifier;
- (void)_updatesForSpecifiers:(id)arg1 isAlwaysOnEnabled:(BOOL)enabled animated:(BOOL)animated;
- (id)isAlwaysOnEnabled:(PSSpecifier *)specifier;
- (void)setAlwaysOnDisplayEnabled:(id)value specifier:(PSSpecifier *)specifier;
- (void)setCustomHz:(id)value spec:(PSSpecifier *)spec;
- (id)getCustomHz:(PSSpecifier *)spec;
- (void)setCustomBrightness:(id)value spec:(PSSpecifier *)spec;
- (id)getCustomBrightness:(PSSpecifier *)spec;
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
// 2. TẦNG DRIVER & PHẦN CỨNG (BACKBOARDD)
//==============================================================
%group Group_Backboardd

%hook CBController
- (void)setPowerState:(BOOL)state completion:(id)completion {
    if (isAODMasterEnabled()) {
        if (!state) {
            if (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies()) {
                %orig(NO, completion); return;
            }
            if (gCurrentState == AODStateActive) {
                %orig(YES, completion); return;
            }
        } else {
            if (gCurrentState == AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) {
                gCurrentState = AODStateActive;
            }
        }
    }
    %orig(state, completion);
}
%end

%hook CAWindowServerDisplay
- (float)refreshRate {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) return getCustomAODRefreshRate();
    return %orig;
}
- (void)setRefreshRate:(float)rate {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) { %orig(getCustomAODRefreshRate()); return; }
    %orig(rate);
}
- (BOOL)blankingRemovesPower {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) return NO;
    return %orig;
}
- (void)setBlankingRemovesPower:(BOOL)val {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) { %orig(NO); return; }
    %orig(val);
}
- (BOOL)disabled {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) return NO;
    return %orig;
}
- (void)setDisabled:(BOOL)val {
    if (isAODMasterEnabled() && val && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) { %orig(NO); return; }
    %orig(val);
}
- (BOOL)isBlanked {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) return NO;
    return %orig;
}
- (void)setBlanked:(BOOL)blanked {
    if (isAODMasterEnabled() && blanked && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) { %orig(NO); return; }
    %orig(blanked);
}
- (BOOL)disablesUpdates {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) return NO;
    return %orig;
}
- (void)setDisablesUpdates:(BOOL)val {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) { %orig(NO); return; }
    %orig(val);
}
- (BOOL)isFlipBookActive {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) return YES;
    return %orig;
}
- (BOOL)isFlipBookEnabled { return isAODMasterEnabled() ? YES : %orig; }
- (void)setFlipBookEnabled:(BOOL)val { %orig(isAODMasterEnabled() ? YES : val); }
- (BOOL)isFlipBookSuppressed {
    if (isAODMasterEnabled() && (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies())) return YES;
    return %orig;
}
- (void)setFlipBookSuppressed:(BOOL)suppressed {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies() && suppressed) { %orig(NO); return; }
    %orig(suppressed);
}
- (void)powerStateDidChange:(id)arg1 {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) return;
    %orig(arg1);
}
%end

%hook BKDisplayRenderOverlay
- (BOOL)disablesDisplayBlanking { return (isAODMasterEnabled() && gCurrentState == AODStateActive) ? YES : %orig; }
%end

%hook BKDisplayManager
- (void)setBlanked:(BOOL)blanked withReason:(id)reason {
    if (isAODMasterEnabled() && blanked && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) { %orig(NO, reason); return; }
    %orig(blanked, reason);
}
%end

%hook BLSHBacklightStateMachine
- (BOOL)isAlwaysOnEnabled { if (shouldSuppressAODBySystemPolicies()) return NO; return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnSuppressed { if (isAODMasterEnabled()) return (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies()) ? YES : NO; return %orig; }
- (long long)backlightState {
    long long state = %orig;
    if (isAODMasterEnabled() && state == 0 && gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) return 2;
    return state;
}
%end

%hook BLSHBacklightTransitionStateMachine
- (BOOL)isAlwaysOnEnabled { if (shouldSuppressAODBySystemPolicies()) return NO; return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnSuppressed { if (isAODMasterEnabled()) return (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies()) ? YES : NO; return %orig; }
%end

%hook BLSHXPCBacklightProxyHost
- (BOOL)isAlwaysOnEnabled { if (shouldSuppressAODBySystemPolicies()) return NO; return isAODMasterEnabled() ? YES : %orig; }
%end

%hook BLSHFlipbookSpecification
- (double)framesPerSecond { if (isAODMasterEnabled() && gCurrentState == AODStateActive) return (double)getCustomAODRefreshRate(); return %orig; }
- (double)minimumGapDuration {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        double fps = (double)getCustomAODRefreshRate();
        return (fps <= 1.0) ? 1.0 : (1.0 / fps);
    }
    return %orig;
}
%end

%hook BLSHAlwaysOnPresentationEngine
- (BOOL)isSuppressed { if (isAODMasterEnabled() && (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies())) return YES; return %orig; }
- (void)setSuppressed:(BOOL)suppressed { if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies() && suppressed) { %orig(NO); return; } %orig(suppressed); }
- (BOOL)isUsingPseudoFlipbook { return isAODMasterEnabled() ? YES : %orig; }
- (void)suspendForReason:(id)reason { if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) return; %orig(reason); }
%end

%hook BLSHBacklightSceneHostEnvironment
- (BOOL)supportsAlwaysOn { if (shouldSuppressAODBySystemPolicies()) return NO; return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnActive { return (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) ? YES : %orig; }
- (BOOL)isClientActive { if (shouldSuppressAODBySystemPolicies()) return NO; return isAODMasterEnabled() ? YES : %orig; }
- (long long)visualState {
    long long state = %orig;
    if (isAODMasterEnabled() && state == 0 && gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) return 2;
    return state;
}
%end

%end // Group_Backboardd

//==============================================================
// 3. TẦNG SPRINGBOARD
//==============================================================
%group Group_SpringBoard

static CSCoverSheetViewController *gCoverSheetVC = nil;
static CSCombinedListViewController *gCombinedListVC = nil;
static id gCachedFlipbookSpec = nil;

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application { %orig; gSpringBoardDidFinishLaunching = YES; }
%end

%hook CSStatusBarViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (gCurrentState != AODStateActive) { self.view.alpha = 1.0f; self.view.hidden = NO; }
}
%end

%hook CSCoverSheetViewController
- (void)viewDidLoad { %orig; gCoverSheetVC = self; }
- (void)dealloc { if (gCoverSheetVC == self) gCoverSheetVC = nil; %orig; }
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    gCurrentState = AODStateIdle;
    @try {
        UIViewController *statusBarVC = [self valueForKey:@"_statusBarViewController"];
        if (statusBarVC) { statusBarVC.view.alpha = 1.0f; statusBarVC.view.hidden = NO; }
        UIViewController *homeAffordanceVC = [self valueForKey:@"_homeAffordanceViewController"];
        if (homeAffordanceVC) homeAffordanceVC.view.alpha = 1.0f;
        UIViewController *quickActionsVC = [self valueForKey:@"_quickActionsViewController"];
        if (quickActionsVC) quickActionsVC.view.alpha = 1.0f;
    } @catch (NSException *e) {}
}
- (BOOL)isAlwaysOnPresentation { if (shouldSuppressAODBySystemPolicies() || gCurrentState == AODStateIdle) return NO; return (isAODMasterEnabled() && gCurrentState == AODStateActive) ? YES : %orig; }
- (BOOL)shouldDimForAlwaysOn { if (gCurrentState == AODStateIdle) return NO; return (isAODMasterEnabled() && gCurrentState == AODStateActive) ? YES : %orig; }
- (BOOL)coverSheetIsObscured { if (gCurrentState == AODStateActive) return NO; return %orig; }
- (long long)backlightLuminance { if (isAODMasterEnabled() && gCurrentState == AODStateActive) return 1; return %orig; }

- (void)_updateAppearanceForAODTransitionToInactive:(BOOL)inactive {
    %orig(inactive);
    if (!isAODMasterEnabled()) return;
    if (shouldSuppressAODBySystemPolicies()) { gCurrentState = AODStateProximityOff; return; }

    if (inactive) {
        if (gCurrentState == AODStateActive) return;
        gCurrentState = AODStateTransitioning;
        [UIView animateWithDuration:0.45f delay:0.0f options:UIViewAnimationOptionCurveEaseInOut animations:^{
            self.view.transform = CGAffineTransformMakeScale(0.985f, 0.985f);
            @try {
                [self _animateView:self.view toWhitePointReduced:YES withDuration:0.45f withDispatchGroup:nil];
                [self _updateWallpaperEffectView];
                [self _updateDateTimeView];
                [self _updateComplicationsContainerView];
            } @catch (NSException *e) {}
        } completion:^(BOOL finished) {
            if (finished) {
                gCurrentState = AODStateActive;
                @try {
                    UIViewController *statusBarVC = [self valueForKey:@"_statusBarViewController"];
                    if (statusBarVC) [UIView animateWithDuration:0.2f animations:^{ statusBarVC.view.alpha = 0.0f; }];
                    UIViewController *homeAffordanceVC = [self valueForKey:@"_homeAffordanceViewController"];
                    if (homeAffordanceVC) homeAffordanceVC.view.alpha = 0.0f;
                    UIViewController *quickActionsVC = [self valueForKey:@"_quickActionsViewController"];
                    if (quickActionsVC) quickActionsVC.view.alpha = 0.0f;
                } @catch (NSException *e) {}
            }
        }];
    } else {
        gCurrentState = AODStateIdle;
        @try {
            UIViewController *statusBarVC = [self valueForKey:@"_statusBarViewController"];
            if (statusBarVC) { statusBarVC.view.alpha = 1.0f; statusBarVC.view.hidden = NO; }
            UIViewController *homeAffordanceVC = [self valueForKey:@"_homeAffordanceViewController"];
            if (homeAffordanceVC) { homeAffordanceVC.view.alpha = 1.0f; homeAffordanceVC.view.hidden = NO; }
            UIViewController *quickActionsVC = [self valueForKey:@"_quickActionsViewController"];
            if (quickActionsVC) { quickActionsVC.view.alpha = 1.0f; quickActionsVC.view.hidden = NO; }
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
- (void)_updateContent {
    %orig;
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        @try {
            UIViewController *combinedListVC = [self valueForKey:@"_combinedListViewController"];
            if (combinedListVC) { combinedListVC.view.hidden = !isNotificationsEnabled(); combinedListVC.view.alpha = isNotificationsEnabled() ? 1.0f : 0.0f; }
        } @catch (NSException *e) {}
    } else if (gCurrentState == AODStateIdle) {
        @try {
            UIViewController *statusBarVC = [self valueForKey:@"_statusBarViewController"];
            if (statusBarVC && statusBarVC.view.alpha != 1.0f) { statusBarVC.view.alpha = 1.0f; statusBarVC.view.hidden = NO; }
            UIViewController *homeAffordanceVC = [self valueForKey:@"_homeAffordanceViewController"];
            if (homeAffordanceVC && homeAffordanceVC.view.alpha != 1.0f) { homeAffordanceVC.view.alpha = 1.0f; homeAffordanceVC.view.hidden = NO; }
        } @catch (NSException *e) {}
    }
}
- (void)_updateWallpaperEffectView {
    %orig;
    UIView *floatingLayer = nil; UIView *effectView = nil; UIView *bgView = nil;
    @try {
        floatingLayer = [self valueForKey:@"_wallpaperFloatingLayerContainerView"];
        effectView = [self valueForKey:@"_wallpaperEffectView"];
        bgView = [self valueForKey:@"_backgroundView"];
    } @catch (NSException *e) {}
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        if (!isWallpaperEnabled()) {
            if (floatingLayer) floatingLayer.alpha = 0.0f; if (bgView) bgView.alpha = 0.0f;
            if (effectView) { effectView.hidden = NO; effectView.backgroundColor = [UIColor blackColor]; effectView.alpha = 1.0f; }
            self.view.backgroundColor = [UIColor blackColor];
        } else {
            if (floatingLayer) floatingLayer.alpha = 1.0f; if (bgView) bgView.alpha = 1.0f;
            if (effectView) {
                effectView.hidden = NO;
                if (isBlurWallpaperEnabled()) { effectView.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.45f]; effectView.alpha = 1.0f; }
                else { effectView.backgroundColor = [UIColor clearColor]; effectView.alpha = 0.0f; }
            }
            self.view.backgroundColor = [UIColor clearColor];
        }
    } else {
        if (floatingLayer) floatingLayer.alpha = 1.0f; if (bgView) bgView.alpha = 1.0f;
        if (effectView) { effectView.backgroundColor = [UIColor clearColor]; effectView.alpha = 0.0f; }
        self.view.backgroundColor = [UIColor clearColor]; self.view.transform = CGAffineTransformIdentity;
    }
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    gCurrentState = AODStateIdle;
    self.view.transform = CGAffineTransformIdentity;
    @try {
        UIViewController *statusBarVC = [self valueForKey:@"_statusBarViewController"];
        if (statusBarVC) { statusBarVC.view.alpha = 1.0f; statusBarVC.view.hidden = NO; }
    } @catch (NSException *e) {}
}
%end

%hook CSCombinedListViewController
- (void)viewDidLoad { %orig; gCombinedListVC = self; }
- (void)dealloc { if (gCombinedListVC == self) gCombinedListVC = nil; %orig; }
- (BOOL)showNotificationsInAlwaysOn { return isAODMasterEnabled() ? isNotificationsEnabled() : %orig; }
- (void)setShowNotificationsInAlwaysOn:(BOOL)show { %orig(isAODMasterEnabled() ? isNotificationsEnabled() : show); }
- (void)_setNotificationListHidden:(BOOL)hidden forReason:(id)reason {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        if (!isNotificationsEnabled()) { %orig(YES, reason); return; }
        %orig(NO, reason); return;
    }
    %orig(hidden, reason);
}
%end

%hook CSBackgroundContentViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    if (isAODMasterEnabled() && !isWallpaperEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        self.view.alpha = 0.0f; self.view.hidden = YES;
    }
}
%end

%hook CSComplicationContainerViewController
- (id)vibrancyConfiguration { if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) return nil; return %orig; }
%end

%hook SBFLockScreenDateView
- (id)vibrancyConfiguration {
    id orig = %orig;
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        if (orig && [orig respondsToSelector:@selector(copyWithLuminanceReduced:)]) return [orig performSelector:@selector(copyWithLuminanceReduced:) withObject:@(NO)];
    }
    return orig;
}
- (_UILegibilitySettings *)legibilitySettings {
    _UILegibilitySettings *orig = %orig;
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        UIColor *textColor = orig ? [orig primaryColor] : nil;
        if (textColor) {
            CGFloat r = 0, g = 0, b = 0, a = 0; [textColor getRed:&r green:&g blue:&b alpha:&a];
            if (r < 0.25f && g < 0.25f && b < 0.25f) return [%c(_UILegibilitySettings) sharedInstanceForStyle:1];
        }
        return orig;
    }
    return orig;
}
%end

%hook SBFLockScreenDateViewController
- (BOOL)restrictsVibrancy { if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) return NO; return %orig; }
- (_UILegibilitySettings *)legibilitySettings {
    _UILegibilitySettings *orig = %orig;
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        UIColor *textColor = orig ? [orig primaryColor] : nil;
        if (textColor) {
            CGFloat r = 0, g = 0, b = 0, a = 0; [textColor getRed:&r green:&g blue:&b alpha:&a];
            if (r < 0.25f && g < 0.25f && b < 0.25f) return [%c(_UILegibilitySettings) sharedInstanceForStyle:1];
        }
        return orig;
    }
    return orig;
}
- (void)_updateWithFrameSpecifier:(id)arg1 { %orig(arg1); if (isAODMasterEnabled() && gCurrentState == AODStateActive) [self updateTimeNow]; }
- (void)updateTimeNow {
    %orig;
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        gBurnInShiftStep++;
        double angle = (gBurnInShiftStep % 8) * (M_PI / 4.0);
        CGFloat dx = (CGFloat)(cos(angle) * 0.35f); CGFloat dy = (CGFloat)(sin(angle) * 0.30f);
        [UIView animateWithDuration:1.0f animations:^{ self.view.transform = CGAffineTransformMakeTranslation(dx, dy); }];
    } else { self.view.transform = CGAffineTransformIdentity; }
}
%end

%hook SBLockScreenViewControllerBase
- (void)setBacklightLevel:(float)level { if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) { %orig(getAODPanelBrightnessFactor() * 100.0f); return; } %orig(level); }
%end
%hook SBDashBoardLockScreenEnvironment
- (void)setBacklightLevel:(float)level { if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) { %orig(getAODPanelBrightnessFactor() * 100.0f); return; } %orig(level); }
%end
%hook UIApplication
- (void)setBacklightLevel:(float)level { if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) { %orig(getAODPanelBrightnessFactor() * 100.0f); return; } %orig(level); }
%end

%hook SBBacklightController
- (void)_updateHIDUISensorModeForBacklightState:(long long)state source:(long long)source {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) { %orig(1, source); return; }
    %orig(state, source);
}
- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion {
    if (isAODMasterEnabled()) {
        if (state == 0) {
            if (gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) {
                gCurrentState = AODStateTransitioning;
                if (gCoverSheetVC && [gCoverSheetVC respondsToSelector:@selector(_updateAppearanceForAODTransitionToInactive:)]) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [gCoverSheetVC _updateAppearanceForAODTransitionToInactive:YES]; });
                }
                state = 2;
            }
        } else if (state == 1 || state == 3) {
            gCurrentState = AODStateIdle; gCurrentAODProgress = 1.0f;
            if (gCoverSheetVC && [gCoverSheetVC respondsToSelector:@selector(_updateAppearanceForAODTransitionToInactive:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{ [gCoverSheetVC _updateAppearanceForAODTransitionToInactive:NO]; });
            }
        }
    }
    %orig(state, source, YES, completion);
}
- (float)_factorToPublishForBacklightState:(long long)state {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        if (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies()) return 0.0f;
        return getAODPanelBrightnessFactor();
    }
    return %orig(state);
}
- (void)animateBacklightToFactor:(float)factor duration:(double)duration source:(long long)source completion:(id)completion {
    if (isAODMasterEnabled()) {
        if (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning) {
            if (factor <= 0.05f) factor = (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies()) ? 0.0f : getAODPanelBrightnessFactor();
        }
        if (factor > 0.15f) gCurrentState = AODStateIdle;
    }
    %orig(factor, duration, source, completion);
}
%end

%hook BLSBacklightFBSSceneEnvironment
- (BOOL)supportsAlwaysOn { if (shouldSuppressAODBySystemPolicies()) return NO; return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isDisplayBlanked { if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) return NO; return %orig; }
- (long long)visualState { if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) return (shouldSuppressAODBySystemPolicies() || gCurrentState == AODStateProximityOff) ? 0 : 2; return %orig; }
%end

%hook SBBacklightPlatformProvider
- (id)initWithBacklightEnvironmentSessionProvider:(id)provider { if (provider) gInjectedSessionProvider = provider; return %orig(provider); }
- (BOOL)deviceSupportsAlwaysOn { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnEnabled { if (shouldSuppressAODBySystemPolicies()) return NO; return isAODMasterEnabled() ? YES : %orig; }
- (id)flipbookSpecification {
    id orig = %orig; if (orig) return orig;
    if (isAODMasterEnabled()) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            Class specClass = NSClassFromString(@"BLSHFlipbookSpecification");
            if (specClass) { @try { gCachedFlipbookSpec = [[specClass alloc] init]; } @catch (NSException *e) {} }
        });
        return gCachedFlipbookSpec;
    }
    return nil;
}
- (id)sessionProvider {
    id orig = %orig; if (orig) return orig;
    if (isAODMasterEnabled()) {
        if (gInjectedSessionProvider) return gInjectedSessionProvider;
        Class providerClass = NSClassFromString(@"SBBacklightEnvironmentSessionProvider");
        if (providerClass && [providerClass respondsToSelector:@selector(sharedInstance)]) return [providerClass performSelector:@selector(sharedInstance)];
    }
    return orig;
}
- (BOOL)isShowingBlankingWindow { if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) return NO; return %orig; }
- (void)showBlankingWindow:(BOOL)show withFadeDuration:(double)duration { if (isAODMasterEnabled() && show && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) return; %orig(show, duration); }
- (void)_setBlankingWindowVisible:(BOOL)visible fadeDuration:(double)duration { if (isAODMasterEnabled() && visible && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) return; %orig(visible, duration); }
- (BOOL)isUsingAlwaysOnBrightnessCurve { if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) return YES; return %orig; }
%end

%hook SBLowPowerModeAlwaysOnPolicy
- (BOOL)isAlwaysOnPolicyActive { return [[NSProcessInfo processInfo] isLowPowerModeEnabled] ? YES : %orig; }
%end
%hook SBFocusModeAlwaysOnPolicy
- (BOOL)isAlwaysOnPolicyActive { return %orig; }
%end
%hook SBThermalAlwaysOnPolicy
- (BOOL)isAlwaysOnPolicyActive { return %orig; }
%end

%hook SBLockScreenManager
- (BOOL)shouldPreventBacklightBlankingForAlwaysOn { if (shouldSuppressAODBySystemPolicies() || gCurrentState == AODStateProximityOff) return NO; return (isAODMasterEnabled() && gCurrentState == AODStateActive) ? YES : %orig; }
- (void)lockUIFromSource:(int)source withOptions:(id)options { if (isAODMasterEnabled() && shouldSuppressAODBySystemPolicies()) gCurrentState = AODStateProximityOff; %orig; }
- (void)unlockUIFromSource:(int)source withOptions:(id)options { gCurrentState = AODStateIdle; %orig; }
%end

%hook SBTapToWakeController
- (BOOL)isTapToWakeSupported { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)shouldTapToWake { return isAODMasterEnabled() ? YES : %orig; }
- (void)setTapToWakeGestureRecognizer:(UITapGestureRecognizer *)gesture { if (isAODMasterEnabled() && [gesture isKindOfClass:[UITapGestureRecognizer class]]) gesture.numberOfTapsRequired = 2; %orig(gesture); }
- (void)setDigitizerInTapToWakeMode:(BOOL)mode { if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) { %orig(YES); return; } %orig(mode); }
- (void)tapToWakeDidRecognize:(UITapGestureRecognizer *)gesture {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        if ([gesture state] == UIGestureRecognizerStateRecognized || [gesture state] == UIGestureRecognizerStateEnded) {
            gCurrentState = AODStateIdle;
            [[%c(SBBacklightController) sharedInstance] setBacklightState:1 source:13 animated:YES completion:nil];
            SBLockScreenManager *lsm = [%c(SBLockScreenManager) sharedInstance];
            if ([lsm respondsToSelector:@selector(tapToWakeControllerDidRecognizeWakeGesture:)]) [lsm tapToWakeControllerDidRecognizeWakeGesture:gesture];
            else if ([lsm respondsToSelector:@selector(_wakeScreenForTapToWake)]) [lsm _wakeScreenForTapToWake];
        }
    }
    %orig(gesture);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch { if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) return YES; return %orig; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer { return YES; }
%end

%hook SBProximitySensorManager
- (BOOL)isProximityDetectionPermitted { if (isAODMasterEnabled() && gCurrentState != AODStateIdle) return YES; return %orig; }
- (BOOL)isProximityDetectionEnabled { if (isAODMasterEnabled() && gCurrentState != AODStateIdle) return YES; return %orig; }
- (void)_setObjectInProximity:(BOOL)inProximity detectionMode:(int)mode {
    %orig(inProximity, mode);
    if (!isAODMasterEnabled() || gCurrentState == AODStateIdle) return;
    if (inProximity) { gCurrentState = AODStateProximityOff; [[%c(SBBacklightController) sharedInstance] setBacklightState:0 source:1 animated:NO completion:nil]; }
    else { if (!shouldSuppressAODBySystemPolicies()) { gCurrentState = AODStateActive; [[%c(SBBacklightController) sharedInstance] setBacklightState:2 source:1 animated:YES completion:nil]; } }
}
%end

%hook SBUIController
- (BOOL)handleHomeButtonDoublePressRequest { if (isAODMasterEnabled() && gCurrentState == AODStateActive) return NO; return %orig; }
%end

%end // Group_SpringBoard

//==============================================================
// 4. TẦNG POSTERBOARD
//==============================================================
%group Group_PosterBoard
%hook PRPosterEnvironmentImpl
- (CGFloat)backlightProgress { if (isAODMasterEnabled()) { if (!isWallpaperEnabled()) return 0.0f; if (gCurrentState == AODStateActive) return 0.20f; if (gCurrentState == AODStateTransitioning) return gCurrentAODProgress; } return %orig; }
- (CGFloat)linearBacklightProgress { if (isAODMasterEnabled()) { if (!isWallpaperEnabled()) return 0.0f; if (gCurrentState == AODStateActive) return 0.20f; if (gCurrentState == AODStateTransitioning) return gCurrentAODProgress; } return %orig; }
- (long long)luminance { if (isAODMasterEnabled()) { if (!isWallpaperEnabled()) return 0; if (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning) return 1; } return %orig; }
- (BOOL)isLowLuminance { if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) return YES; return %orig; }
- (BOOL)isLegibilityBlurEnabled { if (isAODMasterEnabled() && isBlurWallpaperEnabled()) return YES; return %orig; }
%end
%hook PRPosterLockPosterAppearance
- (BOOL)isLegibilityBlurEnabled { if (isAODMasterEnabled() && isBlurWallpaperEnabled()) return YES; return %orig; }
- (BOOL)allowsModifyingLegibilityBlur { return YES; }
%end
%hook PRPosterConfiguration
- (BOOL)isLegibilityBlurEnabled { if (isAODMasterEnabled() && isBlurWallpaperEnabled()) return YES; return %orig; }
%end
%end // Group_PosterBoard

//==============================================================
// 5. TẦNG PREFERENCES: ÉP APPLE TỰ SINH GIAO DIỆN GỐC
//==============================================================

static Boolean (*orig_MGGetBoolAnswer)(CFStringRef property) = NULL;
static Boolean replaced_MGGetBoolAnswer(CFStringRef property) {
    if (property) {
        NSString *key = (__bridge NSString *)property;
        if ([key isEqualToString:@"AlwaysOnDisplaySupport"] || [key isEqualToString:@"DeviceSupportsAlwaysOn"] || [key isEqualToString:@"oPeik/9e8lQWMszEjbPzng"]) return YES;
    }
    return orig_MGGetBoolAnswer ? orig_MGGetBoolAnswer(property) : NO;
}

%group Group_Preferences

%hook BLSBacklight
+ (BOOL)isAlwaysOnEnabledByHardware { return YES; }
%end
%hook BLSAlwaysOnFrequencyConfiguration
- (BOOL)isAlwaysOnEnabled { return YES; }
%end
%hook CBDisplayModule
+ (BOOL)isAlwaysOnDisplaySupported { return YES; }
%end

%hook DBSMainDisplayPreferencesController
- (NSMutableArray *)specifiers {
    NSMutableArray *specs = %orig;
    if (!specs) return specs;

    static NSString *const kAODEntryID = @"ALWAYS_ON_DISPLAY_ENTRY_ROW";
    
    for (PSSpecifier *s in specs) {
        NSString *sID = [s propertyForKey:@"id"];
        if ([sID isEqualToString:kAODEntryID] || [sID containsString:@"ALWAYS_ON"]) return specs;
    }

    PSSpecifier *nativeAODSpec = nil;
    SEL aodSelector = NSSelectorFromString(@"_alwaysOnDisplaySpecifier");
    if ([self respondsToSelector:aodSelector]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        nativeAODSpec = [self performSelector:aodSelector];
        #pragma clang diagnostic pop
    }

    if (!nativeAODSpec) {
        Class detailClass = NSClassFromString(@"DBSAlwaysOnViewController");
        if (!detailClass) {
            dlopen("/System/Library/PrivateFrameworks/DisplayAndBrightnessSettings.framework/DisplayAndBrightnessSettings", RTLD_NOW);
            dlopen("/System/Library/PrivateFrameworks/Settings/DisplayAndBrightnessSettings.framework/DisplayAndBrightnessSettings", RTLD_NOW);
            detailClass = NSClassFromString(@"DBSAlwaysOnViewController");
        }
        if (detailClass) {
            nativeAODSpec = [%c(PSSpecifier) preferenceSpecifierNamed:@"Màn hình Luôn bật" target:self set:NULL get:@selector(getAODMasterStatusText:) detail:detailClass cell:2 edit:Nil];
            [nativeAODSpec setProperty:kAODEntryID forKey:@"id"];
            [nativeAODSpec setProperty:detailClass forKey:@"detail"];
            [nativeAODSpec setProperty:@YES forKey:@"isController"];
            [nativeAODSpec setProperty:@YES forKey:@"enabled"];
        }
    }

    if (nativeAODSpec) {
        NSInteger targetIndex = -1;
        for (NSInteger i = 0; i < (NSInteger)specs.count; i++) {
            NSString *sid = [[[specs objectAtIndex:i] propertyForKey:@"id"] description].uppercaseString;
            if ([sid containsString:@"RAISE_TO_WAKE"] || [sid containsString:@"WAKE"] || [sid containsString:@"AUTOLOCK"]) { targetIndex = i + 1; break; }
        }
        if (targetIndex >= 0 && targetIndex <= (NSInteger)specs.count) [specs insertObject:nativeAODSpec atIndex:targetIndex];
        else [specs addObject:nativeAODSpec];
    }

    return specs;
}

%new
- (id)getAODMasterStatusText:(PSSpecifier *)spec {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(CFSTR("AlwaysOnDisplayEnabled"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) val = CFPreferencesGetAppBooleanValue(CFSTR("enabled"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) val = CFPreferencesGetAppBooleanValue(CFSTR("enabled"), CFSTR("com.jb.aodreal"), &valid);
    return (valid ? (BOOL)val : YES) ? @"Bật" : @"Tắt";
}
%end

%hook DBSAlwaysOnViewController
- (BOOL)shouldShowAlwaysOn { return YES; }
- (id)isAlwaysOnEnabled:(PSSpecifier *)specifier { 
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(CFSTR("AlwaysOnDisplayEnabled"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) val = CFPreferencesGetAppBooleanValue(CFSTR("enabled"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) val = CFPreferencesGetAppBooleanValue(CFSTR("enabled"), CFSTR("com.jb.aodreal"), &valid);
    return @(valid ? (BOOL)val : YES);
}
- (void)setAlwaysOnDisplayEnabled:(id)value specifier:(PSSpecifier *)specifier {
    CFPreferencesSetAppValue(CFSTR("AlwaysOnDisplayEnabled"), (__bridge CFPropertyListRef)(value), CFSTR("com.apple.BacklightServices"));
    CFPreferencesSetAppValue(CFSTR("enabled"), (__bridge CFPropertyListRef)(value), CFSTR("com.apple.BacklightServices"));
    CFPreferencesSetAppValue(CFSTR("enabled"), (__bridge CFPropertyListRef)(value), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.BacklightServices"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    loadAODPreferences();
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);
    [self reloadSpecifiers];
}
- (NSMutableArray *)specifiers {
    NSMutableArray *specs = %orig;
    if (!specs) specs = [NSMutableArray array];

    for (NSString *selName in @[@"_alwaysOnDisplaySpecifier", @"_showWallpaperSpecifier", @"_showNotificationsSpecifier"]) {
        SEL sel = NSSelectorFromString(selName);
        if ([self respondsToSelector:sel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            PSSpecifier *nativeSpec = [self performSelector:sel];
            #pragma clang diagnostic pop
            if (nativeSpec) {
                BOOL exists = NO;
                for (PSSpecifier *s in specs) { if ([[s propertyForKey:@"id"] isEqualToString:[nativeSpec propertyForKey:@"id"]]) { exists = YES; break; } }
                if (!exists) [specs addObject:nativeSpec];
            }
        }
    }

    static NSString *const kAODHzID = @"AOD_CUSTOM_HZ_KEY";
    BOOL hasHz = NO;
    for (PSSpecifier *s in specs) { if ([[s propertyForKey:@"id"] isEqualToString:kAODHzID]) { hasHz = YES; break; } }
    if (!hasHz) {
        PSSpecifier *hzGroup = [%c(PSSpecifier) preferenceSpecifierNamed:@"TẦN SỐ QUÉT TĨNH (1 - 5 HZ)" target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
        [hzGroup setProperty:[NSString stringWithFormat:@"Hiện tại: %.0f Hz", getCustomAODRefreshRate()] forKey:@"footerText"];
        [hzGroup setProperty:@"AOD_HZ_GROUP_ID" forKey:@"id"];
        [specs addObject:hzGroup];

        PSSpecifier *hzSlider = [%c(PSSpecifier) preferenceSpecifierNamed:nil target:self set:@selector(setCustomHz:spec:) get:@selector(getCustomHz:) detail:Nil cell:5 edit:Nil];
        [hzSlider setProperty:@"CustomAODRefreshRate" forKey:@"key"];
        [hzSlider setProperty:kAODHzID forKey:@"id"];
        [hzSlider setProperty:@1.0f forKey:@"min"];
        [hzSlider setProperty:@5.0f forKey:@"max"];
        [hzSlider setProperty:@YES forKey:@"isSegmented"];
        [hzSlider setProperty:@4 forKey:@"segmentCount"];
        [hzSlider setProperty:@YES forKey:@"showValue"];
        [specs addObject:hzSlider];
    }
    return specs;
}
%new
- (void)setCustomHz:(id)value spec:(PSSpecifier *)spec {
    float roundedHz = roundf([value floatValue]);
    if (roundedHz < 1.0f) roundedHz = 1.0f;
    if (roundedHz > 5.0f) roundedHz = 5.0f;
    gCachedCustomHz = roundedHz;
    CFPreferencesSetAppValue(CFSTR("CustomAODRefreshRate"), (__bridge CFPropertyListRef)(@(roundedHz)), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);
    for (PSSpecifier *s in [self specifiers]) {
        if ([[s propertyForKey:@"id"] isEqualToString:@"AOD_HZ_GROUP_ID"]) {
            [s setProperty:[NSString stringWithFormat:@"Hiện tại: %.0f Hz", roundedHz] forKey:@"footerText"];
            [self reloadSpecifier:s animated:NO];
            break;
        }
    }
}
%new
- (id)getCustomHz:(PSSpecifier *)spec { return @(getCustomAODRefreshRate()); }
%end

%end // Group_Preferences

//==============================================================
// 6. KHỞI TẠO TIẾN TRÌNH & ĐỒNG BỘ CẤU HÌNH REALTIME
//==============================================================

static void AODPreferencesReloadCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    loadAODPreferences();
}

%ctor {
    @autoreleasepool {
        NSString *processName = [[NSProcessInfo processInfo] processName];
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

        loadAODPreferences();

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
            gCurrentState = AODStateIdle;
            %init(Group_SpringBoard);
        } else if ([bundleID isEqualToString:@"com.apple.PosterBoard"] || [processName.lowercaseString containsString:@"posterboard"]) {
            %init(Group_PosterBoard);
        } else if ([processName isEqualToString:@"backboardd"]) {
            %init(Group_Backboardd);
        } else if ([bundleID isEqualToString:@"com.apple.Preferences"] || [processName.lowercaseString containsString:@"preferences"]) {
            
            void *gestaltHandle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
            if (gestaltHandle) {
                void *mgFunc = dlsym(gestaltHandle, "MGGetBoolAnswer");
                if (mgFunc) {
                    MSHookFunction(mgFunc, (void *)replaced_MGGetBoolAnswer, (void **)&orig_MGGetBoolAnswer);
                }
            }

            [[NSBundle bundleWithPath:@"/System/Library/PreferenceBundles/Display.bundle"] load];
            dlopen("/System/Library/PreferenceBundles/Display.bundle/Display", RTLD_NOW | RTLD_GLOBAL);
            dlopen("/System/Library/PrivateFrameworks/DisplayAndBrightnessSettings.framework/DisplayAndBrightnessSettings", RTLD_NOW | RTLD_GLOBAL);
            dlopen("/System/Library/PrivateFrameworks/Settings/DisplayAndBrightnessSettings.framework/DisplayAndBrightnessSettings", RTLD_NOW | RTLD_GLOBAL);

            %init(Group_Preferences);
        }
    }
}
