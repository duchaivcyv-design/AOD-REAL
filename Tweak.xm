#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAFrameRateRange.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>

//==============================================================
// 0. BỘ ĐIỀU PHỐI TRẠNG THÁI & CẤU HÌNH TWEAK
//==============================================================

typedef NS_ENUM(NSInteger, AODState) {
    AODStateIdle = 0,       // Màn hình sáng bình thường / Đang tương tác
    AODStateActive,        // AOD gốc iOS đang hiển thị
    AODStateProximityOff   // Đút túi / Úp màn hình (Dập tắt đèn nền)
};

static AODState gCurrentState = AODStateIdle;
static NSInteger gBurnInShiftStep = 0;
static id gInjectedSessionProvider = nil;

static inline BOOL isAODMasterEnabled(void) {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(CFSTR("enabled"), CFSTR("com.jb.aodreal"), &valid);
    return valid ? (BOOL)val : YES;
}

static inline BOOL isWallpaperEnabled(void) {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(CFSTR("ShowWallpaperInAlwaysOn"), CFSTR("com.jb.aodreal"), &valid);
    return valid ? (BOOL)val : YES;
}

static inline BOOL isNotificationsEnabled(void) {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(CFSTR("ShowNotificationsInAlwaysOn"), CFSTR("com.jb.aodreal"), &valid);
    return valid ? (BOOL)val : YES;
}

static inline float getCustomAODRefreshRate(void) {
    CFPropertyListRef val = CFPreferencesCopyAppValue(CFSTR("CustomAODRefreshRate"), CFSTR("com.jb.aodreal"));
    if (val && CFGetTypeID(val) == CFNumberGetTypeID()) {
        float rate = [(__bridge NSNumber *)val floatValue];
        CFRelease(val);
        if (rate >= 2.0f && rate <= 30.0f) return rate;
    }
    if (val) CFRelease(val);
    return 2.0f;
}

static inline float getCustomAODBrightnessFactor(void) {
    CFPropertyListRef val = CFPreferencesCopyAppValue(CFSTR("CustomAODBrightness"), CFSTR("com.jb.aodreal"));
    if (val && CFGetTypeID(val) == CFNumberGetTypeID()) {
        float level = [(__bridge NSNumber *)val floatValue];
        CFRelease(val);
        if (level >= 1.0f && level <= 30.0f) return level / 1000.0f;
    }
    if (val) CFRelease(val);
    return 0.006f; // Mức sáng tối ưu cho panel không bị dập nguồn
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
- (void)insertSpecifier:(PSSpecifier *)specifier atIndex:(NSInteger)index animated:(BOOL)animated;
- (void)addSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
@end

@interface DBSAlwaysOnViewController : PSListController
- (id)isAlwaysOnEnabled:(PSSpecifier *)specifier;
- (void)setAlwaysOnDisplayEnabled:(id)value specifier:(PSSpecifier *)specifier;
@end

@interface BLSHFlipbookSpecification : NSObject
- (double)framesPerSecond;
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
- (id)presentationDate;
@end

@interface BLSBacklightSceneUpdateContext : NSObject
- (long long)visualState;
@end

@interface BLSDiagnosticPresentationDateSpecifier : NSObject
- (id)presentationDate;
@end

@interface BLSHPresentationDateSpecifier : NSObject
- (id)presentationDate;
@end

@interface BLSHBacklightDisplayStateMachine : NSObject
- (void)transitionToDisplayMode:(long long)mode withDuration:(double)duration shouldWaitForCompletion:(BOOL)wait;
@end

@interface BLSHBacklightEnvironmentStateMachine : NSObject
- (void)transitionCompleteAfterCompletingTransitionState:(id)state;
- (void)transitionState:(id)state didBeginUpdateToBacklightState:(long long)bState visualState:(long long)vState;
- (void)transitionState:(id)state didCompleteUpdateToBacklightState:(long long)bState visualState:(long long)vState;
- (void)transitionState:(id)state didUpdateToDateSpecifier:(id)specifier;
- (id)transitionStateForEnvironment:(id)env;
- (id)withLock_transitionStateForEnvironment:(id)env;
@end

@interface BLSHBacklightFBSceneHostEnvironment : NSObject
- (id)presentationDate;
- (long long)visualState;
@end

@interface BLSHBacklightOSInterfaceProvider : NSObject
- (void)transitionToDisplayMode:(long long)mode withDuration:(double)duration;
@end

@interface BLSHBaseSceneHostEnvironment : NSObject
- (id)presentationDate;
- (long long)visualState;
@end

@interface BLSHEnvironmentTransitionState : NSObject
- (long long)visualStateForBacklightState:(long long)state requestedFidelity:(long long)fidelity;
@end

@interface BLSHEnvironmentTransitionStateTarget : NSObject
- (id)presentationDate;
- (long long)visualState;
@end

@interface BLSHLocalHostSceneEnvironment : NSObject
- (id)presentationDate;
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

@interface CSCoverSheetTransitionSettings : NSObject
- (long long)transitionStyle;
@end

@interface CSCoverSheetView : UIView
- (id)transitionContext;
@end

@interface CSCoverSheetViewController : UIViewController
- (BOOL)isAlwaysOnPresentation;
- (BOOL)shouldDimForAlwaysOn;
- (BOOL)coverSheetIsObscured;
- (long long)backlightLuminance;
- (void)setBacklightLevel:(float)level;
- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession;
- (id)transitionContext;
- (void)transitionSource:(id)source willBeginWithType:(long long)type;
- (void)transitionSource:(id)source didUpdateTransitionWithContext:(id)context;
- (void)transitionSource:(id)source didEndWithContext:(id)context;
@end

@interface CSCombinedListViewController : UIViewController
- (BOOL)showNotificationsInAlwaysOn;
- (void)setShowNotificationsInAlwaysOn:(BOOL)show;
- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession;
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

@interface SBFLockScreenDateView : UIView
- (id)vibrancyConfiguration;
- (id)legibilitySettings;
@end

@interface SBFLockScreenDateViewController : UIViewController
- (UIView *)view;
- (void)updateTimeNow;
- (id)legibilitySettings;
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
@end

@interface SBTapToWakeController : NSObject
- (BOOL)isTapToWakeSupported;
- (BOOL)shouldTapToWake;
- (void)tapToWakeDidRecognize:(id)arg1;
@end

@interface SBBacklightController : NSObject
+ (instancetype)sharedInstance;
- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion;
- (void)animateBacklightToFactor:(float)factor duration:(double)duration source:(long long)source completion:(id)completion;
- (float)backlightFactor;
- (float)_factorToPublishForBacklightState:(long long)state;
@end

@interface SBProximitySensorManager : NSObject
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
- (void)startFlipbookAndEnsureCurrent;
- (id)frameOnGlassNow;
- (void)startLiveUpdates;
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
- (id)presentationDate;
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
@end

@interface PRPosterColorHSLValues : NSObject
- (double)luminance;
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

//==============================================================
// 2. TẦNG BACKBOARDD & ĐIỀU PHỐI BACKLIGHTHOST (ĐỒNG BỘ NATIVE)
//==============================================================

%group Group_Backboardd

// Giữ panel hiển thị luôn được cấp nguồn, an toàn không can thiệp CBController
%hook CAWindowServerDisplay
- (BOOL)blankingRemovesPower {
    if (isAODMasterEnabled() && gCurrentState != AODStateProximityOff) {
        return NO;
    }
    return %orig;
}

- (void)setBlankingRemovesPower:(BOOL)val {
    if (isAODMasterEnabled() && gCurrentState != AODStateProximityOff) {
        %orig(NO);
        return;
    }
    %orig(val);
}

- (BOOL)disabled {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return NO;
    }
    return %orig;
}

- (void)setDisabled:(BOOL)val {
    if (isAODMasterEnabled() && val && gCurrentState == AODStateActive) {
        %orig(NO);
        return;
    }
    %orig(val);
}

- (BOOL)isBlanked {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return NO;
    }
    return %orig;
}

- (void)setBlanked:(BOOL)blanked {
    if (isAODMasterEnabled() && blanked && gCurrentState == AODStateActive) {
        %orig(NO);
        return;
    }
    %orig(blanked);
}

- (BOOL)disablesUpdates {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return NO;
    }
    return %orig;
}

- (void)setDisablesUpdates:(BOOL)val {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        %orig(NO);
        return;
    }
    %orig(val);
}

- (BOOL)isFlipBookActive {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return YES;
    }
    return %orig;
}

- (BOOL)isFlipBookEnabled { return isAODMasterEnabled() ? YES : %orig; }
- (void)setFlipBookEnabled:(BOOL)val { %orig(isAODMasterEnabled() ? YES : val); }

- (BOOL)isFlipBookSuppressed {
    if (isAODMasterEnabled() && gCurrentState != AODStateProximityOff) {
        return NO;
    }
    return %orig;
}

- (void)setFlipBookSuppressed:(BOOL)suppressed {
    if (isAODMasterEnabled() && gCurrentState != AODStateProximityOff && suppressed) {
        %orig(NO);
        return;
    }
    %orig(suppressed);
}

- (void)powerStateDidChange:(id)arg1 {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return;
    }
    %orig(arg1);
}
%end

%hook BKDisplayRenderOverlay
- (BOOL)disablesDisplayBlanking { return isAODMasterEnabled() ? YES : %orig; }
%end

%hook BKDisplayManager
- (void)setBlanked:(BOOL)blanked withReason:(id)reason {
    if (isAODMasterEnabled() && blanked && gCurrentState != AODStateProximityOff) {
        %orig(NO, reason);
        return;
    }
    %orig(blanked, reason);
}
%end

// [BLSHBacklightDisplayStateMachine]
// Triệt tiêu delay khi chuyển chế độ hiển thị phần cứng sang AOD: Bỏ chờ completion
%hook BLSHBacklightDisplayStateMachine
- (void)transitionToDisplayMode:(long long)mode withDuration:(double)duration shouldWaitForCompletion:(BOOL)wait {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        if (mode != 1) { // Chuyển sang AOD mode: Không chờ đợi gây lệch pha
            wait = NO;
        }
    }
    %orig(mode, duration, wait);
}
%end

// [BLSHBacklightOSInterfaceProvider]
%hook BLSHBacklightOSInterfaceProvider
- (void)transitionToDisplayMode:(long long)mode withDuration:(double)duration {
    %orig(mode, duration);
}
%end

// [BLSHBacklightEnvironmentStateMachine]
// Bộ điều phối hoàn tất transition giữa PosterBoard và SpringBoard đồng thời
%hook BLSHBacklightEnvironmentStateMachine
- (void)transitionCompleteAfterCompletingTransitionState:(id)state {
    %orig(state);
}

- (void)transitionState:(id)state didBeginUpdateToBacklightState:(long long)bState visualState:(long long)vState {
    %orig(state, bState, vState);
}

- (void)transitionState:(id)state didCompleteUpdateToBacklightState:(long long)bState visualState:(long long)vState {
    %orig(state, bState, vState);
}

- (void)transitionState:(id)state didUpdateToDateSpecifier:(id)specifier {
    %orig(state, specifier);
}

- (id)transitionStateForEnvironment:(id)env {
    return %orig(env);
}

- (id)withLock_transitionStateForEnvironment:(id)env {
    return %orig(env);
}
%end

// [BLSHEnvironmentTransitionState]
%hook BLSHEnvironmentTransitionState
- (long long)visualStateForBacklightState:(long long)state requestedFidelity:(long long)fidelity {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return 2; // VisualState = 2 (AOD Active)
    }
    return %orig(state, fidelity);
}
%end

// [BLSHEnvironmentTransitionStateTarget]
%hook BLSHEnvironmentTransitionStateTarget
- (long long)visualState {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return 2;
    }
    return %orig;
}
- (id)presentationDate { return %orig; }
%end

%hook BLSHBacklightStateMachine
- (BOOL)isAlwaysOnEnabled { return isAODMasterEnabled() ? YES : %orig; }

- (BOOL)isAlwaysOnSuppressed {
    if (isAODMasterEnabled()) {
        return (gCurrentState == AODStateProximityOff) ? YES : NO;
    }
    return %orig;
}

- (BOOL)isAlwaysOnDisabledByAssertion { return %orig; }

- (long long)backlightState {
    long long state = %orig;
    if (isAODMasterEnabled() && state == 0) {
        if (gCurrentState != AODStateProximityOff) {
            gCurrentState = AODStateActive;
            return 2;
        }
    }
    if (state != 2 && state != 0) {
        gCurrentState = AODStateIdle;
    }
    return state;
}
%end

%hook BLSHBacklightTransitionStateMachine
- (BOOL)isAlwaysOnEnabled { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnSuppressed {
    if (isAODMasterEnabled()) {
        return (gCurrentState == AODStateProximityOff) ? YES : NO;
    }
    return %orig;
}
%end

%hook BLSHXPCBacklightProxyHost
- (BOOL)isAlwaysOnEnabled { return isAODMasterEnabled() ? YES : %orig; }
%end

%hook BLSHFlipbookSpecification
- (double)framesPerSecond {
    if (isAODMasterEnabled()) return (double)getCustomAODRefreshRate();
    return %orig;
}
%end

%hook BLSHAlwaysOnPresentationEngine
- (BOOL)isSuppressed {
    if (isAODMasterEnabled()) return (gCurrentState == AODStateProximityOff) ? YES : %orig;
    return %orig;
}

- (void)setSuppressed:(BOOL)suppressed {
    if (isAODMasterEnabled() && gCurrentState != AODStateProximityOff && suppressed) {
        %orig(NO);
        return;
    }
    %orig(suppressed);
}

- (BOOL)isUsingPseudoFlipbook { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)alwaysFillFlipbook { return isAODMasterEnabled() ? YES : %orig; }

- (void)startLiveUpdates {
    %orig;
    if (isAODMasterEnabled()) {
        @try {
            [self startFlipbookAndEnsureCurrent];
        } @catch (NSException *e) {}
    }
}
%end

// [BLSHBacklightSceneHostEnvironment]
%hook BLSHBacklightSceneHostEnvironment
- (BOOL)supportsAlwaysOn { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnActive { return (isAODMasterEnabled() && gCurrentState != AODStateProximityOff) ? YES : %orig; }
- (BOOL)isClientActive { return isAODMasterEnabled() ? YES : %orig; }
- (long long)visualState {
    long long state = %orig;
    if (isAODMasterEnabled() && state == 0 && gCurrentState != AODStateProximityOff) return 2;
    return state;
}
- (id)presentationDate { return %orig; }
%end

// [BLSHBacklightFBSceneHostEnvironment]
%hook BLSHBacklightFBSceneHostEnvironment
- (long long)visualState {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) return 2;
    return %orig;
}
- (id)presentationDate { return %orig; }
%end

// [BLSHBaseSceneHostEnvironment]
%hook BLSHBaseSceneHostEnvironment
- (long long)visualState {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) return 2;
    return %orig;
}
- (id)presentationDate { return %orig; }
%end

// [BLSHLocalHostSceneEnvironment]
%hook BLSHLocalHostSceneEnvironment
- (long long)visualState {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) return 2;
    return %orig;
}
- (id)presentationDate { return %orig; }
%end

// [BLSBacklightSceneUpdateContext]
%hook BLSBacklightSceneUpdateContext
- (long long)visualState {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) return 2;
    return %orig;
}
%end

// [BLSBacklightFBSSceneEnvironment]
%hook BLSBacklightFBSSceneEnvironment
- (BOOL)supportsAlwaysOn { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isDisplayBlanked {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) return NO;
    return %orig;
}
- (long long)visualState {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) return 2;
    return %orig;
}
- (id)presentationDate { return %orig; }
%end

// [BLSHPresentationDateSpecifier] & [BLSDiagnosticPresentationDateSpecifier]
%hook BLSHPresentationDateSpecifier
- (id)presentationDate { return %orig; }
%end

%hook BLSDiagnosticPresentationDateSpecifier
- (id)presentationDate { return %orig; }
%end

%end // Group_Backboardd

//==============================================================
// 3. TẦNG SPRINGBOARD: KÍCH HOẠT AOD NATIVE (KHÔNG DÙNG ANIMATION TỰ CHẾ)
//==============================================================

%group Group_SpringBoard

static id gCachedFlipbookSpec = nil;

// [CSCoverSheetTransitionSettings transitionStyle]
%hook CSCoverSheetTransitionSettings
- (long long)transitionStyle { return %orig; }
%end

// [CSCoverSheetView transitionContext]
%hook CSCoverSheetView
- (id)transitionContext { return %orig; }
%end

%hook CSCoverSheetViewController
- (BOOL)isAlwaysOnPresentation { 
    return (isAODMasterEnabled() && gCurrentState == AODStateActive) ? YES : %orig; 
}

- (BOOL)shouldDimForAlwaysOn { 
    return (isAODMasterEnabled() && gCurrentState == AODStateActive) ? YES : %orig; 
}

- (BOOL)coverSheetIsObscured {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) return NO;
    return %orig;
}

- (long long)backlightLuminance {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) return 1;
    return %orig;
}

- (void)setBacklightLevel:(float)level {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        %orig(getCustomAODBrightnessFactor() * 100.0f);
        return;
    }
    %orig(level);
}

- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession {
    NSArray *entries = %orig;
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        if (!entries || entries.count == 0) {
            @try {
                id sceneHost = [self valueForKey:@"_sceneHostEnvironment"];
                if (sceneHost) return @[sceneHost];
            } @catch (NSException *e) {}
        }
    }
    return entries;
}

// Giữ nguyên luồng TransitionContext chuẩn của CoverSheet
- (id)transitionContext { return %orig; }
- (void)transitionSource:(id)source willBeginWithType:(long long)type { %orig(source, type); }
- (void)transitionSource:(id)source didUpdateTransitionWithContext:(id)context { %orig(source, context); }
- (void)transitionSource:(id)source didEndWithContext:(id)context { %orig(source, context); }

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (gCurrentState == AODStateActive) {
        gCurrentState = AODStateIdle;
    }
}
%end

// Quản lý hiển thị thông báo theo chuẩn Apple (Không gọi setHidden bừa bãi)
%hook CSCombinedListViewController
- (BOOL)showNotificationsInAlwaysOn {
    if (isAODMasterEnabled()) {
        return isNotificationsEnabled();
    }
    return %orig;
}

- (void)setShowNotificationsInAlwaysOn:(BOOL)show {
    if (isAODMasterEnabled()) {
        show = isNotificationsEnabled();
    }
    %orig(show);
}

- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession {
    if (isAODMasterEnabled() && !isNotificationsEnabled()) return @[];
    return %orig;
}
%end

// Quản lý hiển thị hình nền theo chuẩn Apple (Không phủ layer blur nhân tạo)
%hook CSBackgroundContentViewController
- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession {
    if (isAODMasterEnabled() && !isWallpaperEnabled()) return @[];
    return %orig;
}
%end

// [CSComplicationContainerViewController] - Đồng bộ độ sáng / vibrancy của Widget
%hook CSComplicationContainerViewController
- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession { return %orig; }

- (id)vibrancyConfiguration {
    id orig = %orig;
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        if (orig && [orig respondsToSelector:@selector(copyWithLuminanceReduced:)]) {
            return [orig performSelector:@selector(copyWithLuminanceReduced:) withObject:@(NO)];
        }
    }
    return orig;
}
%end

%hook CSActivityItemViewController
- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession { return %orig; }
%end

// [SBFLockScreenDateView] - Giữ độ nét đồng hồ & chống nhạt màu legibility
%hook SBFLockScreenDateView
- (id)vibrancyConfiguration {
    id orig = %orig;
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        if (orig && [orig respondsToSelector:@selector(copyWithLuminanceReduced:)]) {
            return [orig performSelector:@selector(copyWithLuminanceReduced:) withObject:@(NO)];
        }
    }
    return orig;
}

- (id)legibilitySettings { return %orig; }
%end

// [SBFLockScreenDateViewController] - Giữ legibility settings đồng bộ
%hook SBFLockScreenDateViewController
- (id)legibilitySettings { return %orig; }
%end

%hook SBLockScreenViewControllerBase
- (void)setBacklightLevel:(float)level {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        %orig(getCustomAODBrightnessFactor() * 100.0f);
        return;
    }
    %orig(level);
}
%end

%hook SBDashBoardLockScreenEnvironment
- (void)setBacklightLevel:(float)level {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        %orig(getCustomAODBrightnessFactor() * 100.0f);
        return;
    }
    %orig(level);
}
%end

%hook UIApplication
- (void)setBacklightLevel:(float)level {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        %orig(getCustomAODBrightnessFactor() * 100.0f);
        return;
    }
    %orig(level);
}
%end

// ĐIỀU PHỐI CHUYỂN TRẠNG THÁI SANG AOD NATIVE
// Không tự nhồi UIView animate - Để iOS tự chạy curve mờ gốc, dẹp bỏ xung đột 2 animation
%hook SBBacklightController
- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion {
    if (isAODMasterEnabled() && state == 0) {
        if (gCurrentState != AODStateProximityOff) {
            gCurrentState = AODStateActive;
            state = 2; // Giữ State AOD chuẩn gốc của Apple
        }
    } else if (state != 0 && state != 2) {
        gCurrentState = AODStateIdle;
    }
    %orig(state, source, animated, completion);
}

- (float)_factorToPublishForBacklightState:(long long)state {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return getCustomAODBrightnessFactor();
    }
    return %orig(state);
}

- (void)animateBacklightToFactor:(float)factor duration:(double)duration source:(long long)source completion:(id)completion {
    if (isAODMasterEnabled()) {
        if (gCurrentState == AODStateActive) {
            if (factor <= 0.05f) {
                factor = getCustomAODBrightnessFactor();
            }
        }
        if (factor > 0.1f) {
            gCurrentState = AODStateIdle;
        }
    }
    %orig(factor, duration, source, completion);
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
- (BOOL)isAlwaysOnEnabled { return isAODMasterEnabled() ? YES : %orig; }

- (id)flipbookSpecification {
    id orig = %orig;
    if (orig) return orig;
    
    if (isAODMasterEnabled()) {
        if (!gCachedFlipbookSpec) {
            Class specClass = NSClassFromString(@"BLSHFlipbookSpecification");
            if (specClass) {
                @try {
                    SEL sel1 = @selector(initWithSoftMemoryLimit:frameCapacity:framesPerSecond:minimumGapDuration:coaelscingEpsilon:minimumPrepareInterval:maximumRenderInterval:);
                    if ([specClass instancesRespondToSelector:sel1]) {
                        NSMethodSignature *sig = [specClass instanceMethodSignatureForSelector:sel1];
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        id instance = [specClass alloc];
                        [inv setTarget:instance];
                        [inv setSelector:sel1];
                        
                        unsigned long long softLimit = 52428800;
                        unsigned long long cap = 120;
                        double fps = (double)getCustomAODRefreshRate();
                        double minGap = 0.0;
                        double coalescing = 0.1;
                        double minPrep = 0.05;
                        double maxRend = 0.25;
                        
                        [inv setArgument:&softLimit atIndex:2];
                        [inv setArgument:&cap atIndex:3];
                        [inv setArgument:&fps atIndex:4];
                        [inv setArgument:&minGap atIndex:5];
                        [inv setArgument:&coalescing atIndex:6];
                        [inv setArgument:&minPrep atIndex:7];
                        [inv setArgument:&maxRend atIndex:8];
                        [inv invoke];
                        [inv getReturnValue:&gCachedFlipbookSpec];
                    } else {
                        gCachedFlipbookSpec = [[specClass alloc] init];
                    }
                } @catch (NSException *e) {
                    gCachedFlipbookSpec = [[specClass alloc] init];
                }
            }
        }
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
    if (isAODMasterEnabled() && gCurrentState != AODStateProximityOff) return NO;
    return %orig;
}

- (void)showBlankingWindow:(BOOL)show withFadeDuration:(double)duration {
    if (isAODMasterEnabled() && show && gCurrentState != AODStateProximityOff) return;
    %orig(show, duration);
}

- (void)_setBlankingWindowVisible:(BOOL)visible fadeDuration:(double)duration {
    if (isAODMasterEnabled() && visible && gCurrentState != AODStateProximityOff) return;
    %orig(visible, duration);
}

- (BOOL)isUsingAlwaysOnBrightnessCurve {
    if (isAODMasterEnabled() && gCurrentState != AODStateProximityOff) return YES;
    return %orig;
}
%end

%hook SBAlwaysOnPolicyCoordinator
- (NSSet *)activePolicies { return isAODMasterEnabled() ? [NSSet set] : %orig; }
- (void)_activatePolicy:(id)policy {
    if (isAODMasterEnabled()) return;
    %orig(policy);
}
%end

%hook SBFocusModeAlwaysOnPolicy
- (BOOL)isAlwaysOnPolicyActive { return NO; }
%end

%hook SBLowPowerModeAlwaysOnPolicy
- (BOOL)isAlwaysOnPolicyActive { return NO; }
%end

%hook SBSetupAlwaysOnPolicy
- (BOOL)isAlwaysOnPolicyActive { return NO; }
%end

%hook SBThermalAlwaysOnPolicy
- (BOOL)isAlwaysOnPolicyActive { return NO; }
%end

%hook SBLockScreenService
- (BOOL)isAlwaysOnPolicyActive { return NO; }
%end

%hook SBLockScreenManager
- (BOOL)shouldPreventBacklightBlankingForAlwaysOn { 
    return (isAODMasterEnabled() && gCurrentState != AODStateProximityOff) ? YES : %orig; 
}

- (void)lockUIFromSource:(int)source withOptions:(id)options {
    if (isAODMasterEnabled()) {
        gCurrentState = AODStateActive;
    }
    %orig;
}

- (void)unlockUIFromSource:(int)source withOptions:(id)options {
    gCurrentState = AODStateIdle;
    %orig;
}
%end

// CẢM ỨNG CHẠM ĐÁNH THỨC (Tap to Wake)
%hook SBTapToWakeController
- (BOOL)isTapToWakeSupported { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)shouldTapToWake { return isAODMasterEnabled() ? YES : %orig; }

- (void)tapToWakeDidRecognize:(id)arg1 {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        [[%c(SBLockScreenManager) sharedInstance] _wakeScreenForTapToWake];
    }
    %orig(arg1);
}
%end

// CẢM BIẾN TIỆM CẬN: Đút túi/úp mặt thì dập tắt hẳn đèn, bỏ ra thì AOD tự sáng
%hook SBProximitySensorManager
- (void)_setObjectInProximity:(BOOL)inProximity detectionMode:(int)mode {
    %orig(inProximity, mode);
    if (!isAODMasterEnabled() || gCurrentState == AODStateIdle) return;
    
    if (inProximity) {
        gCurrentState = AODStateProximityOff;
        [[%c(SBBacklightController) sharedInstance] setBacklightState:0 source:1 animated:NO completion:nil];
    } else {
        gCurrentState = AODStateActive;
        [[%c(SBBacklightController) sharedInstance] setBacklightState:2 source:1 animated:YES completion:nil];
    }
}
%end

// CHỐNG ÁM MÀN HÌNH: Dịch chuyển vi mô đồng hồ
%hook SBFLockScreenDateViewController
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

%end // Group_SpringBoard

//==============================================================
// 4. TẦNG POSTERBOARD: ĐỒNG BỘ NATIVE LÀM MỜ HÌNH NỀN GỐC
//==============================================================

%group Group_PosterBoard

// [PRPosterEnvironmentImpl]
// Cho phép hình nền tự hạ luminance & backlight theo đường cong gốc của iOS
%hook PRPosterEnvironmentImpl
- (CGFloat)backlightProgress {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return 0.0f;
    }
    return %orig;
}

- (CGFloat)linearBacklightProgress {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return 0.0f;
    }
    return %orig;
}

- (void)setBacklightProgress:(CGFloat)progress {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        %orig(0.0f);
        return;
    }
    %orig(progress);
}

- (void)setLinearBacklightProgress:(CGFloat)progress {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        %orig(0.0f);
        return;
    }
    %orig(progress);
}

- (long long)luminance {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return 1;
    }
    return %orig;
}

- (BOOL)isLowLuminance {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return YES;
    }
    return %orig;
}
%end

// [PRPosterColorHSLValues luminance]
%hook PRPosterColorHSLValues
- (double)luminance {
    return %orig;
}
%end

%end // Group_PosterBoard

//==============================================================
// 5. TẦNG PREFERENCES: GIAO DIỆN CÀI ĐẶT CHUẨN SETTINGS (APPLE AOD)
//==============================================================

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

static void AODInjectIntoList(PSListController *list) {
    if (!list) return;

    NSString *className = NSStringFromClass([list class]);
    if (!([className containsString:@"Display"] || [className containsString:@"Brightness"] ||
          [className containsString:@"DBS"] || [className containsString:@"DBR"])) return;

    NSMutableArray *specs = [list specifiers];
    if (!specs) return;

    static NSString *const kAODID = @"ALWAYS_ON_DISPLAY";
    for (PSSpecifier *s in specs) {
        id specID = [s propertyForKey:@"id"];
        if ([specID isKindOfClass:[NSString class]] && [(NSString *)specID isEqualToString:kAODID]) return;
    }

    Class detailClass = NSClassFromString(@"DBSAlwaysOnViewController");
    if (!detailClass) return;

    PSSpecifier *aodSpec = [%c(PSSpecifier) preferenceSpecifierNamed:@"Màn hình luôn bật"
                                                              target:list set:NULL get:NULL detail:detailClass cell:2 edit:Nil];
    [aodSpec setProperty:kAODID forKey:@"id"];
    [aodSpec setProperty:NSStringFromClass(detailClass) forKey:@"detail"];

    NSInteger idx = -1;
    for (NSInteger i = 0; i < (NSInteger)specs.count; i++) {
        NSString *sid = [[[specs objectAtIndex:i] propertyForKey:@"id"] description].uppercaseString;
        if ([sid containsString:@"RAISE"] || [sid containsString:@"WAKE"]) { idx = i + 1; break; }
    }
    if (idx < 0) {
        for (NSInteger i = 0; i < (NSInteger)specs.count; i++) {
            NSString *sid = [[[specs objectAtIndex:i] propertyForKey:@"id"] description].uppercaseString;
            if ([sid containsString:@"AUTOLOCK"] || [sid containsString:@"AUTO_LOCK"]) { idx = i + 1; break; }
        }
    }

    if (idx >= 0 && idx <= (NSInteger)specs.count) {
        [list insertSpecifier:aodSpec atIndex:idx animated:NO];
    } else {
        [list addSpecifier:aodSpec animated:NO];
    }
}

%hook PSListController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    AODInjectIntoList(self);
}
%end

%hook DBSAlwaysOnViewController

- (id)isAlwaysOnEnabled:(PSSpecifier *)specifier { return @(isAODMasterEnabled()); }

- (void)setAlwaysOnDisplayEnabled:(id)value specifier:(PSSpecifier *)specifier {
    %orig(value, specifier);
    CFPreferencesSetAppValue(CFSTR("enabled"), (__bridge CFPropertyListRef)(value), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);
}

- (NSMutableArray *)specifiers {
    NSMutableArray *specs = %orig;
    if (!specs) specs = [NSMutableArray array];

    static NSString *const kAODHzID = @"AOD_CUSTOM_HZ_KEY";
    
    BOOL hasHz = NO;
    for (PSSpecifier *s in specs) {
        id specID = [s propertyForKey:@"id"];
        if ([specID isKindOfClass:[NSString class]] && [(NSString *)specID isEqualToString:kAODHzID]) {
            hasHz = YES;
            break;
        }
    }

    if (!hasHz) {
        PSSpecifier *group = [%c(PSSpecifier) preferenceSpecifierNamed:@"CẤU HÌNH PHẦN CỨNG TẦNG SÂU (2-30)"
                                                               target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
        [group setProperty:@"Ép phần cứng hạ xung nhịp và độ sáng xuống mức tối thiểu khi khóa màn hình." forKey:@"footerText"];

        PSSpecifier *hzSlider = [%c(PSSpecifier) preferenceSpecifierNamed:@"Tần số quét tĩnh (2-30 Hz)"
                                                                   target:self set:@selector(setCustomHz:spec:) get:@selector(getCustomHz:) detail:Nil cell:5 edit:Nil];
        [hzSlider setProperty:kAODHzID forKey:@"id"];
        [hzSlider setProperty:@(2.0f) forKey:@"min"];
        [hzSlider setProperty:@(30.0f) forKey:@"max"];
        [hzSlider setProperty:@YES forKey:@"showValue"];

        PSSpecifier *brightSlider = [%c(PSSpecifier) preferenceSpecifierNamed:@"Độ sáng AOD (Mức 1-30)"
                                                                       target:self set:@selector(setCustomBrightness:spec:) get:@selector(getCustomBrightness:) detail:Nil cell:5 edit:Nil];
        [brightSlider setProperty:@"AOD_CUSTOM_BRIGHTNESS_KEY" forKey:@"id"];
        [brightSlider setProperty:@(1.0f) forKey:@"min"];
        [brightSlider setProperty:@(30.0f) forKey:@"max"];
        [brightSlider setProperty:@YES forKey:@"showValue"];

        [specs addObject:group];
        [specs addObject:hzSlider];
        [specs addObject:brightSlider];
    }

    return specs;
}

%new
- (void)setCustomHz:(id)value spec:(PSSpecifier *)spec {
    CFPreferencesSetAppValue(CFSTR("CustomAODRefreshRate"), (__bridge CFPropertyListRef)(value), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);
}

%new
- (id)getCustomHz:(PSSpecifier *)spec { return @(getCustomAODRefreshRate()); }

%new
- (void)setCustomBrightness:(id)value spec:(PSSpecifier *)spec {
    CFPreferencesSetAppValue(CFSTR("CustomAODBrightness"), (__bridge CFPropertyListRef)(value), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);
}

%new
- (id)getCustomBrightness:(PSSpecifier *)spec { return @(getCustomAODBrightnessFactor() * 1000.0f); }

%end

%end // Group_Preferences

//==============================================================
// 6. KHỞI TẠO TIẾN TRÌNH
//==============================================================

%ctor {
    @autoreleasepool {
        NSString *processName = [[NSProcessInfo processInfo] processName];
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

        if ([bundleID isEqualToString:@"com.apple.springboard"]) {
            %init(Group_SpringBoard);
        } else if ([bundleID isEqualToString:@"com.apple.PosterBoard"]) {
            %init(Group_PosterBoard);
        } else if ([processName isEqualToString:@"backboardd"]) {
            %init(Group_Backboardd);
        } else if ([bundleID isEqualToString:@"com.apple.Preferences"] || [processName isEqualToString:@"Preferences"]) {
            %init(Group_Preferences);
        }
    }
}
