#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAFrameRateRange.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
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

// Biến lưu cấu hình tải nhanh trong bộ nhớ RAM
static BOOL gCachedAODEnabled = YES;
static BOOL gCachedWallpaperEnabled = YES;
static BOOL gCachedBlurWallpaperEnabled = YES;
static BOOL gCachedNotificationsEnabled = YES;
static float gCachedCustomHz = 2.0f;
static float gCachedBrightnessFactor = 0.005f; // Mặc định nấc 5 (tương đương 0.5% độ sáng panel)

static inline void loadAODPreferences(void) {
    Boolean valid = false;
    
    // 1. Công tắc chính AOD (Màn hình luôn bật)
    Boolean masterVal = CFPreferencesGetAppBooleanValue(CFSTR("AlwaysOnDisplayEnabled"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) masterVal = CFPreferencesGetAppBooleanValue(CFSTR("enabled"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) masterVal = CFPreferencesGetAppBooleanValue(CFSTR("enabled"), CFSTR("com.jb.aodreal"), &valid);
    gCachedAODEnabled = valid ? (BOOL)masterVal : YES;

    // 2. Công tắc Hiển thị hình nền gốc
    valid = false;
    Boolean wpVal = CFPreferencesGetAppBooleanValue(CFSTR("ShowWallpaperInAlwaysOn"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) wpVal = CFPreferencesGetAppBooleanValue(CFSTR("ShowWallpaperInAlwaysOn"), CFSTR("com.jb.aodreal"), &valid);
    gCachedWallpaperEnabled = valid ? (BOOL)wpVal : YES;

    // 3. Công tắc Làm mờ hình nền (Blur Wallpaper Photo)
    valid = false;
    Boolean blurVal = CFPreferencesGetAppBooleanValue(CFSTR("BlurWallpaperInAlwaysOn"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) blurVal = CFPreferencesGetAppBooleanValue(CFSTR("BlurWallpaperInAlwaysOn"), CFSTR("com.jb.aodreal"), &valid);
    gCachedBlurWallpaperEnabled = valid ? (BOOL)blurVal : YES;

    // 4. Công tắc Hiển thị thông báo gốc
    valid = false;
    Boolean notiVal = CFPreferencesGetAppBooleanValue(CFSTR("ShowNotificationsInAlwaysOn"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) notiVal = CFPreferencesGetAppBooleanValue(CFSTR("ShowNotificationsInAlwaysOn"), CFSTR("com.jb.aodreal"), &valid);
    gCachedNotificationsEnabled = valid ? (BOOL)notiVal : YES;

    // 5. Nấc tần số quét tĩnh (2 - 5 - 10 - 15 - 20 Hz)
    CFPropertyListRef hzVal = CFPreferencesCopyAppValue(CFSTR("CustomAODRefreshRate"), CFSTR("com.jb.aodreal"));
    if (hzVal) {
        if (CFGetTypeID(hzVal) == CFNumberGetTypeID()) {
            float r = [(__bridge NSNumber *)hzVal floatValue];
            if (r >= 2.0f && r <= 20.0f) gCachedCustomHz = r;
        }
        CFRelease(hzVal);
    }

    // 6. Nấc độ sáng panel tĩnh (0.5 - 1 - 5 - 10 - 15 - 20)
    CFPropertyListRef brVal = CFPreferencesCopyAppValue(CFSTR("CustomAODBrightness"), CFSTR("com.jb.aodreal"));
    if (brVal) {
        if (CFGetTypeID(brVal) == CFNumberGetTypeID()) {
            float b = [(__bridge NSNumber *)brVal floatValue];
            if (b >= 0.5f && b <= 20.0f) {
                // Chia cho 1000.0f để ra hệ số backlight factor thực tế (0.0005f -> 0.020f)
                gCachedBrightnessFactor = b / 1000.0f;
            }
        }
        CFRelease(brVal);
    }
}

// CÁC HÀM GETTER TỐC ĐỘ CAO CHO TOÀN BỘ TWEAK
static inline BOOL isAODMasterEnabled(void) { return gCachedAODEnabled; }
static inline BOOL isWallpaperEnabled(void) { return gCachedWallpaperEnabled; }
static inline BOOL isBlurWallpaperEnabled(void) { return gCachedBlurWallpaperEnabled; }
static inline BOOL isNotificationsEnabled(void) { return gCachedNotificationsEnabled; }
static inline float getCustomAODRefreshRate(void) { return gCachedCustomHz; }
static inline float getAODPanelBrightnessFactor(void) { return gCachedBrightnessFactor; }
static inline float getCustomAODBrightnessFactor(void) { return gCachedBrightnessFactor; }

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

@interface PSListController : UIViewController
- (NSMutableArray *)specifiers;
- (void)reloadSpecifiers;
- (void)insertSpecifier:(PSSpecifier *)specifier atIndex:(NSInteger)index animated:(BOOL)animated;
- (void)addSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
@end

@interface DBSAlwaysOnViewController : PSListController
- (PSSpecifier *)_alwaysOnDisplaySpecifier;
- (PSSpecifier *)_showWallpaperSpecifier;
- (PSSpecifier *)_showNotificationsSpecifier;
- (void)_updatesForSpecifiers:(id)arg1 isAlwaysOnEnabled:(BOOL)enabled animated:(BOOL)animated;
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

@interface _UILegibilitySettings : NSObject
+ (instancetype)sharedInstanceForStyle:(long long)style;
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

@interface SBTapToWakeController : NSObject
- (BOOL)isTapToWakeSupported;
- (BOOL)shouldTapToWake;
- (void)setDigitizerInTapToWakeMode:(BOOL)mode;
- (void)setDigitizerModeRequiresHitTestSuppression:(BOOL)suppress;
- (void)setTapToWakeGestureRecognizer:(UITapGestureRecognizer *)gesture;
- (void)tapToWakeDidRecognize:(UITapGestureRecognizer *)arg1;
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
// 2. TẦNG DRIVER & PHẦN CỨNG (BACKBOARDD)
//==============================================================

%group Group_Backboardd

// BẢO VỆ NGUỒN ĐÈN NỀN PANEL (CHỈ CHO TẮT KHI CHE TIỆM CẬN HOẶC POLICY HỆ THỐNG YÊU CẦU)
%hook CBController
- (void)setPowerState:(BOOL)state completion:(id)completion {
    if (isAODMasterEnabled() && !state) {
        if (gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) {
            %orig(YES, completion); // Bảo toàn nguồn đèn nền panel để nuôi AOD
            return;
        }
    }
    %orig(state, completion);
}
%end

// ÉP HẠ XUNG NHỊP HZ/FPS PHẦN CỨNG & CHỐNG BLANK MÀN HÌNH
%hook CAWindowServerDisplay

- (float)refreshRate {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return getCustomAODRefreshRate(); // Ép tần số quét tĩnh theo nấc 2-5-10-15-20 Hz
    }
    return %orig;
}

- (void)setRefreshRate:(float)rate {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        %orig(getCustomAODRefreshRate());
        return;
    }
    %orig(rate);
}

- (BOOL)blankingRemovesPower {
    if (isAODMasterEnabled() && gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) {
        return NO;
    }
    return %orig;
}

- (void)setBlankingRemovesPower:(BOOL)val {
    if (isAODMasterEnabled() && gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) {
        %orig(NO);
        return;
    }
    %orig(val);
}

- (BOOL)disabled {
    if (isAODMasterEnabled() && gCurrentState != AODStateProximityOff && gCurrentState != AODStateIdle && !shouldSuppressAODBySystemPolicies()) {
        return NO;
    }
    return %orig;
}

- (void)setDisabled:(BOOL)val {
    if (isAODMasterEnabled() && val && gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) {
        %orig(NO);
        return;
    }
    %orig(val);
}

- (BOOL)isBlanked {
    if (isAODMasterEnabled() && gCurrentState != AODStateProximityOff && gCurrentState != AODStateIdle && !shouldSuppressAODBySystemPolicies()) {
        return NO;
    }
    return %orig;
}

- (void)setBlanked:(BOOL)blanked {
    if (isAODMasterEnabled() && blanked && gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) {
        %orig(NO);
        return;
    }
    %orig(blanked);
}

- (BOOL)disablesUpdates {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return NO;
    }
    return %orig;
}

- (void)setDisablesUpdates:(BOOL)val {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        %orig(NO);
        return;
    }
    %orig(val);
}

- (BOOL)isFlipBookActive {
    if (isAODMasterEnabled() && gCurrentState != AODStateIdle && gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) {
        return YES;
    }
    return %orig;
}

- (BOOL)isFlipBookEnabled { return isAODMasterEnabled() ? YES : %orig; }
- (void)setFlipBookEnabled:(BOOL)val { %orig(isAODMasterEnabled() ? YES : val); }

- (BOOL)isFlipBookSuppressed {
    if (isAODMasterEnabled() && (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies())) {
        return YES;
    }
    return %orig;
}

- (void)setFlipBookSuppressed:(BOOL)suppressed {
    if (isAODMasterEnabled() && gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies() && suppressed) {
        %orig(NO);
        return;
    }
    %orig(suppressed);
}

- (void)powerStateDidChange:(id)arg1 {
    if (isAODMasterEnabled() && gCurrentState != AODStateIdle && gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) {
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
    if (isAODMasterEnabled() && blanked) {
        if (gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) {
            %orig(NO, reason);
            return;
        }
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

- (BOOL)isAlwaysOnDisabledByAssertion { return %orig; }

- (long long)backlightState {
    long long state = %orig;
    if (isAODMasterEnabled() && state == 0) {
        if (gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) {
            return 2; // Ép giữ State AOD của BacklightServices
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
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return (double)getCustomAODRefreshRate();
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
    if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies() && suppressed) {
        %orig(NO);
        return;
    }
    %orig(suppressed);
}

- (BOOL)isUsingPseudoFlipbook { 
    return isAODMasterEnabled() ? YES : %orig; 
}

- (void)startLiveUpdates {
    %orig;
    if (isAODMasterEnabled()) {
        @try {
            [self main_performLiveUpdateIfNeeded];
        } @catch (NSException *e) {}
    }
}

- (void)suspendForReason:(id)reason {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) {
        return; // Ngăn engine đóng băng vòng lặp khi màn hình đang hiển thị AOD
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
    return (isAODMasterEnabled() && gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) ? YES : %orig; 
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

static CSCoverSheetViewController *gCoverSheetVC = nil;
static CSCombinedListViewController *gCombinedListVC = nil;
static id gCachedFlipbookSpec = nil;

// KIỂM TRA ĐIỀU KIỆN TỰ NGẮT AOD GỐC APPLE (PIN <= 5%, TIẾT KIỆM PIN)
static inline BOOL shouldSuppressAODBySystemPolicies(void) {
    UIDevice *device = [UIDevice currentDevice];
    [device setBatteryMonitoringEnabled:YES];
    if (device.batteryState != UIDeviceBatteryStateCharging && 
        device.batteryState != UIDeviceBatteryStateFull) {
        if (device.batteryLevel > 0.0f && device.batteryLevel <= 0.05f) {
            return YES; // Pin <= 5% -> Ngắt hoàn toàn AOD
        }
    }
    if ([[NSProcessInfo processInfo] isLowPowerModeEnabled]) {
        return YES; // Bật Tiết kiệm pin -> Ngắt hoàn toàn AOD
    }
    return NO;
}

// -------------------------------------------------------------
// COVERSHEET: ĐIỀU PHỐI AOD, NỀN VÀ HIỆU ỨNG CHUYỂN CẢNH MƯỢT
// -------------------------------------------------------------
%hook CSCoverSheetViewController

- (void)viewDidLoad {
    %orig;
    gCoverSheetVC = self;
}

- (void)dealloc {
    if (gCoverSheetVC == self) {
        gCoverSheetVC = nil;
    }
    %orig;
}

- (BOOL)isAlwaysOnPresentation { 
    if (shouldSuppressAODBySystemPolicies()) return NO;
    return (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) ? YES : %orig; 
}

- (BOOL)shouldDimForAlwaysOn { 
    return (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) ? YES : %orig; 
}

- (BOOL)coverSheetIsObscured {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) return NO;
    return %orig;
}

- (long long)backlightLuminance {
    if (isAODMasterEnabled()) {
        if (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning) return 1;
    }
    return %orig;
}

// BẬT CHU TRÌNH CẬP NHẬT LIÊN TỤC & CHUYỂN CẢNH AOD CHUẨN GỐC (CHỐNG CRASH)
- (void)_updateAppearanceForAODTransitionToInactive:(BOOL)inactive {
    %orig(inactive);
    if (isAODMasterEnabled()) {
        if (shouldSuppressAODBySystemPolicies()) {
            gCurrentState = AODStateProximityOff;
            return;
        }

        if (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning) {
            @try {
                [self _animateView:self.view toWhitePointReduced:YES withDuration:0.45f withDispatchGroup:nil];
                [self _updateDateTimeView];
                [self _updateComplicationsContainerView];
                [self _updateVibrancy];
                [self _updateContent];
            } @catch (NSException *e) {}
        }
    }
}

// CÔNG TẮC HÌNH NỀN & MỜ NỀN: ÉP ĐỒNG BỘ NỀN VÀ POSTERKIT
- (void)_updateWallpaperEffectView {
    %orig;
    
    UIView *floatingLayer = nil;
    UIView *effectView = nil;
    @try {
        floatingLayer = [self valueForKey:@"_wallpaperFloatingLayerContainerView"];
        effectView = [self valueForKey:@"_wallpaperEffectView"];
    } @catch (NSException *e) {}

    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        if (!isWallpaperEnabled()) {
            // TẮT HÌNH NỀN: ÉP ĐEN HOÀN TOÀN
            if (floatingLayer) {
                floatingLayer.hidden = YES;
                floatingLayer.alpha = 0.0f;
            }
            if (effectView) {
                effectView.hidden = NO;
                effectView.backgroundColor = [UIColor blackColor];
                effectView.alpha = 1.0f;
            }
            self.view.backgroundColor = [UIColor blackColor];
        } else {
            // HIỆN HÌNH NỀN: ĐỒNG BỘ HIỆU ỨNG LÀM MỜ
            if (floatingLayer) {
                floatingLayer.hidden = NO;
                floatingLayer.alpha = 1.0f;
            }
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
        if (floatingLayer) {
            floatingLayer.hidden = NO;
            floatingLayer.alpha = 1.0f;
        }
        if (effectView) {
            effectView.backgroundColor = [UIColor clearColor];
            effectView.alpha = 0.0f;
        }
        self.view.backgroundColor = [UIColor clearColor];
    }
}

- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession {
    if (isAODMasterEnabled() && !isWallpaperEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return @[]; // Ngắt hoàn toàn nạp phiên poster để màn đen tuyệt đối
    }
    NSArray *entries = %orig;
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        if (!entries || entries.count == 0) {
            @try {
                id sceneHost = [self valueForKey:@"_sceneHostEnvironment"];
                if (sceneHost) return @[sceneHost];
            } @catch (NSException *e) {}
        }
    }
    return entries;
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning) {
        gCurrentState = AODStateIdle;
    }
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

- (void)dealloc {
    if (gCombinedListVC == self) {
        gCombinedListVC = nil;
    }
    %orig;
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
    }
    %orig(hidden, reason);
}

- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession {
    return %orig;
}

%end

%hook CSBackgroundContentViewController
- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession {
    if (isAODMasterEnabled() && !isWallpaperEnabled()) return @[];
    return %orig;
}
%end

%hook CSComplicationContainerViewController
- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession {
    return %orig;
}

- (id)vibrancyConfiguration {
    id orig = %orig;
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        if (orig && [orig respondsToSelector:@selector(copyWithLuminanceReduced:)]) {
            return [orig performSelector:@selector(copyWithLuminanceReduced:) withObject:@(NO)];
        }
    }
    return orig;
}
%end

%hook CSActivityItemViewController
- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession {
    return %orig;
}
%end

// -------------------------------------------------------------
// ĐỒNG HỒ & WIDGET: CHỐNG ĐEN MÀN LCD, GIỮ ĐỘ SÁNG TRẮNG TƯƠNG PHẢN CAO
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
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return [%c(_UILegibilitySettings) sharedInstanceForStyle:1]; // White High Contrast
    }
    return %orig;
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
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return [%c(_UILegibilitySettings) sharedInstanceForStyle:1];
    }
    return %orig;
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
// ĐIỀU PHỐI ĐỘ SÁNG MÀN HÌNH VÀ VÒNG ĐỜI AOD
// -------------------------------------------------------------
%hook SBBacklightController

- (void)_updateHIDUISensorModeForBacklightState:(long long)state source:(long long)source {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        %orig(1, source); // Ép bật phần cứng cảm biến tiệm cận ở State AOD
        return;
    }
    %orig(state, source);
}

- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion {
    if (isAODMasterEnabled() && state == 0) {
        if (gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) {
            gCurrentState = AODStateTransitioning;
            
            if (gCoverSheetVC && [gCoverSheetVC respondsToSelector:@selector(_updateAppearanceForAODTransitionToInactive:)]) {
                [gCoverSheetVC _updateAppearanceForAODTransitionToInactive:YES];
            }
            
            if (gCombinedListVC) {
                [gCombinedListVC _setNotificationListHidden:!isNotificationsEnabled() forReason:@"AODTransition"];
            }
            
            [UIView animateWithDuration:0.45f delay:0.0f options:UIViewAnimationOptionCurveEaseInOut animations:^{
                gCurrentAODProgress = 0.0f;
                if (gCoverSheetVC) [gCoverSheetVC _updateWallpaperEffectView];
            } completion:^(BOOL finished) {
                gCurrentState = AODStateActive;
            }];
            
            state = 2; // Giữ State AOD
        }
    } else if (state != 0 && state != 2) {
        gCurrentState = AODStateIdle;
        gCurrentAODProgress = 1.0f;
        if (gCoverSheetVC && [gCoverSheetVC respondsToSelector:@selector(_updateAppearanceForAODTransitionToInactive:)]) {
            [gCoverSheetVC _updateAppearanceForAODTransitionToInactive:NO];
        }
        if (gCombinedListVC) {
            [gCombinedListVC _setNotificationListHidden:NO forReason:@"AODWake"];
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
        if (factor > 0.15f) {
            gCurrentState = AODStateIdle;
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
    if (isAODMasterEnabled() && gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) return NO;
    return %orig;
}

- (void)showBlankingWindow:(BOOL)show withFadeDuration:(double)duration {
    if (isAODMasterEnabled() && show && gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) return;
    %orig(show, duration);
}

- (void)_setBlankingWindowVisible:(BOOL)visible fadeDuration:(double)duration {
    if (isAODMasterEnabled() && visible && gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) return;
    %orig(visible, duration);
}

- (BOOL)isUsingAlwaysOnBrightnessCurve {
    if (isAODMasterEnabled() && gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) return YES;
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
    return isAODMasterEnabled() ? YES : %orig; 
}

- (void)lockUIFromSource:(int)source withOptions:(id)options {
    if (isAODMasterEnabled()) {
        if (shouldSuppressAODBySystemPolicies()) {
            gCurrentState = AODStateProximityOff;
        } else {
            gCurrentState = AODStateActive;
        }
    }
    %orig;
}

- (void)unlockUIFromSource:(int)source withOptions:(id)options {
    gCurrentState = AODStateIdle;
    %orig;
}
%end

// -------------------------------------------------------------
// CẢM ỨNG CHẠM ĐÁNH THỨC: NHẤP ĐÚP (DOUBLE TAP), LỌC NƯỚC/TAY ƯỚT
// -------------------------------------------------------------
%hook SBTapToWakeController

- (BOOL)isTapToWakeSupported { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)shouldTapToWake { return isAODMasterEnabled() ? YES : %orig; }

- (void)setTapToWakeGestureRecognizer:(UITapGestureRecognizer *)gesture {
    if (isAODMasterEnabled() && [gesture isKindOfClass:[UITapGestureRecognizer class]]) {
        gesture.numberOfTapsRequired = 2;
    }
    %orig(gesture);
}

- (void)setDigitizerInTapToWakeMode:(BOOL)mode {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        %orig(YES);
        return;
    }
    %orig(mode);
}

- (void)setDigitizerModeRequiresHitTestSuppression:(BOOL)arg1 {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        %orig(NO);
        return;
    }
    %orig(arg1);
}

- (void)tapToWakeDidRecognize:(UITapGestureRecognizer *)gesture {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        if ([gesture state] == UIGestureRecognizerStateRecognized || [gesture state] == UIGestureRecognizerStateEnded) {
            
            @try {
                NSArray *touches = [gesture valueForKey:@"_touches"];
                for (UITouch *touch in touches) {
                    if (touch.majorRadius > 18.0f || touch.majorRadiusTolerance > 10.0f) {
                        return; // Chống chạm nước / tỳ tay
                    }
                }
            } @catch (NSException *e) {}

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

%end

// -------------------------------------------------------------
// CẢM BIẾN TIỆM CẬN: CHE CAMERA / ÁP TAI / ĐÚT TÚI LÀ TẮT ĐEN 100%
// -------------------------------------------------------------
%hook SBProximitySensorManager

- (BOOL)isProximityDetectionPermitted {
    if (isAODMasterEnabled() && gCurrentState != AODStateIdle) {
        return YES;
    }
    return %orig;
}

- (BOOL)isProximityDetectionEnabled {
    if (isAODMasterEnabled() && gCurrentState != AODStateIdle) {
        return YES;
    }
    return %orig;
}

- (void)_setObjectInProximity:(BOOL)inProximity detectionMode:(int)mode {
    %orig(inProximity, mode);
    if (!isAODMasterEnabled() || gCurrentState == AODStateIdle) return;
    
    if (inProximity) {
        gCurrentState = AODStateProximityOff;
        [[%c(SBBacklightController) sharedInstance] setBacklightState:0 source:1 animated:NO completion:nil];
    } else {
        if (!shouldSuppressAODBySystemPolicies()) {
            gCurrentState = AODStateActive;
            [[%c(SBBacklightController) sharedInstance] setBacklightState:2 source:1 animated:YES completion:nil];
        }
    }
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
        if (!isWallpaperEnabled()) return 0.0f; // Tắt hình nền: Đen tuyền 100%
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
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return 1;
    }
    return %orig;
}

- (BOOL)isLowLuminance {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return YES;
    }
    return %orig;
}

%end

// LÀM MỜ HÌNH NỀN GỐC APPLE (ĐỒNG BỘ THEO CÔNG TẮC LÀM MỜ)
%hook PRPosterLockPosterHomeScreenAppearance

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

%hook PRPosterHomePosterHomeScreenAppearance

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

%hook PRPosterDescriptorHomeScreenConfiguration

- (BOOL)allowsModifyingLegibilityBlur {
    return YES;
}

%end

%end // Group_PosterBoard


//==============================================================
// 5. TẦNG PREFERENCES: CHUẨN XÁC, BỐ CỤC CHUẨN GỐC, NẤC CHỌN HIỂN THỊ ĐÚNG
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

// CHÈN DÒNG TRANG CHỦ "MÀN HÌNH LUÔN BẬT" VÀO TRANG DISPLAY & BRIGHTNESS
%hook PSListController
- (void)viewWillAppear:(BOOL)animated {
    %orig;

    NSString *className = NSStringFromClass([self class]);
    if ([className containsString:@"LargeText"] || 
        [className containsString:@"Zoom"] || 
        [className containsString:@"NightShift"] ||
        [className containsString:@"AlwaysOn"]) {
        return;
    }

    NSMutableArray *specs = [self specifiers];
    if (!specs || specs.count == 0) return;

    static NSString *const kAODEntryID = @"ALWAYS_ON_DISPLAY_ENTRY_ROW";
    for (PSSpecifier *s in specs) {
        if ([[s propertyForKey:@"id"] isEqualToString:kAODEntryID]) return;
    }

    Class detailClass = NSClassFromString(@"DBSAlwaysOnViewController");
    if (!detailClass) return;

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

    if (targetIndex < 0) return;

    PSSpecifier *aodSpec = [%c(PSSpecifier) preferenceSpecifierNamed:@"Màn hình luôn bật"
                                                              target:self 
                                                                 set:NULL 
                                                                 get:NULL 
                                                              detail:detailClass 
                                                                cell:2 
                                                                edit:Nil];
    [aodSpec setProperty:kAODEntryID forKey:@"id"];
    [aodSpec setProperty:NSStringFromClass(detailClass) forKey:@"detail"];

    if (targetIndex <= (NSInteger)specs.count) {
        [self insertSpecifier:aodSpec atIndex:targetIndex animated:NO];
    } else {
        [self addSpecifier:aodSpec animated:NO];
    }
}
%end

// TRANG CON AOD: BỐ CỤC CHUẨN XÁC NHƯ APPLE GỐC
%hook DBSAlwaysOnViewController

- (id)isAlwaysOnEnabled:(PSSpecifier *)specifier { 
    return @(isAODMasterEnabled()); 
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
    NSMutableArray *specs = [NSMutableArray array];

    // NHÓM 1: CÔNG TẮC CHÍNH DUY NHẤT TRÊN CÙNG
    PSSpecifier *mainGroup = [%c(PSSpecifier) preferenceSpecifierNamed:nil target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
    [mainGroup setProperty:@"Màn hình Luôn bật giảm độ sáng Màn hình khóa trong khi hiển thị các thông tin như thời gian, tiện ích và thông báo bằng nguồn điện tối thiểu.\n\nMàn hình sẽ tắt tự động để tiết kiệm thời lượng pin khi không sử dụng." forKey:@"footerText"];
    [specs addObject:mainGroup];

    PSSpecifier *mainSwitch = [%c(PSSpecifier) preferenceSpecifierNamed:@"Màn hình Luôn bật"
                                                                target:self
                                                                   set:@selector(setAlwaysOnDisplayEnabled:specifier:)
                                                                   get:@selector(isAlwaysOnEnabled:)
                                                                detail:Nil
                                                                  cell:6 // PSSwitchCell
                                                                  edit:Nil];
    [mainSwitch setProperty:@"ALWAYS_ON_MASTER_SWITCH" forKey:@"id"];
    [specs addObject:mainSwitch];

    // CHỈ KHI BẬT MÀN HÌNH LUÔN BẬT MỚI HIỆN CÁC NHÓM TÙY CHỈNH CON
    if (isAODMasterEnabled()) {
        // NHÓM 2: 3 CÔNG TẮC TÙY CHỈNH CON
        PSSpecifier *subGroup = [%c(PSSpecifier) preferenceSpecifierNamed:@"TÙY CHỈNH" target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
        [specs addObject:subGroup];

        PSSpecifier *wpSwitch = [%c(PSSpecifier) preferenceSpecifierNamed:@"Hiển thị hình nền"
                                                                   target:self
                                                                      set:@selector(setWallpaperSwitch:spec:)
                                                                      get:@selector(getWallpaperSwitch:)
                                                                   detail:Nil
                                                                     cell:6 // PSSwitchCell
                                                                     edit:Nil];
        [specs addObject:wpSwitch];

        PSSpecifier *blurSwitch = [%c(PSSpecifier) preferenceSpecifierNamed:@"Làm mờ hình nền"
                                                                    target:self
                                                                       set:@selector(setBlurSwitch:spec:)
                                                                       get:@selector(getBlurSwitch:)
                                                                    detail:Nil
                                                                      cell:6 // PSSwitchCell
                                                                      edit:Nil];
        [specs addObject:blurSwitch];

        PSSpecifier *notiSwitch = [%c(PSSpecifier) preferenceSpecifierNamed:@"Hiển thị thông báo"
                                                                     target:self
                                                                        set:@selector(setNotificationSwitch:spec:)
                                                                        get:@selector(getNotificationSwitch:)
                                                                     detail:Nil
                                                                       cell:6 // PSSwitchCell
                                                                       edit:Nil];
        [specs addObject:notiSwitch];

        // NHÓM 3: CẤU HÌNH PHẦN CỨNG TẦNG SÂU (NẤC CHỌN SEGMENT ĐÚNG CHUẨN)
        PSSpecifier *hwGroup = [%c(PSSpecifier) preferenceSpecifierNamed:@"CẤU HÌNH PHẦN CỨNG TẦNG SÂU" target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
        [hwGroup setProperty:@"Chọn cố định nấc tần số quét Hz (2-5-10-15-20) và độ sáng (0.5-1-5-10-15-20) khi khóa AOD." forKey:@"footerText"];
        [specs addObject:hwGroup];

        // Nấc tần số quét tĩnh: 2, 5, 10, 15, 20 Hz
        PSSpecifier *hzSegment = [%c(PSSpecifier) preferenceSpecifierNamed:@"Tần số quét tĩnh (Hz)"
                                                                    target:self
                                                                       set:@selector(setCustomHz:spec:)
                                                                       get:@selector(getCustomHz:)
                                                                    detail:Nil
                                                                      cell:3 // PSSegmentCell
                                                                      edit:Nil];
        [hzSegment setProperty:@"AOD_CUSTOM_HZ_KEY" forKey:@"id"];
        [hzSegment setProperty:@[@2, @5, @10, @15, @20] forKey:@"validValues"];
        [hzSegment setProperty:@[@"2Hz", @"5Hz", @"10Hz", @"15Hz", @"20Hz"] forKey:@"validTitles"];
        [specs addObject:hzSegment];

        // Nấc độ sáng panel: 0.5, 1, 5, 10, 15, 20
        PSSpecifier *brightSegment = [%c(PSSpecifier) preferenceSpecifierNamed:@"Độ sáng nền AOD"
                                                                        target:self
                                                                           set:@selector(setCustomBrightness:spec:)
                                                                           get:@selector(getCustomBrightness:)
                                                                        detail:Nil
                                                                          cell:3 // PSSegmentCell
                                                                          edit:Nil];
        [brightSegment setProperty:@"AOD_CUSTOM_BRIGHTNESS_KEY" forKey:@"id"];
        [brightSegment setProperty:@[@0.5f, @1.0f, @5.0f, @10.0f, @15.0f, @20.0f] forKey:@"validValues"];
        [brightSegment setProperty:@[@"0.5", @"1", @"5", @"10", @"15", @"20"] forKey:@"validTitles"];
        [specs addObject:brightSegment];
    }

    [self setValue:specs forKey:@"_specifiers"];
    return specs;
}

// BINDING THẬT CHO TỪNG CÔNG TẮC CON
%new
- (void)setWallpaperSwitch:(id)value spec:(PSSpecifier *)spec {
    CFPreferencesSetAppValue(CFSTR("ShowWallpaperInAlwaysOn"), (__bridge CFPropertyListRef)(value), CFSTR("com.apple.BacklightServices"));
    CFPreferencesSetAppValue(CFSTR("ShowWallpaperInAlwaysOn"), (__bridge CFPropertyListRef)(value), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.BacklightServices"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    loadAODPreferences();
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);
}

%new
- (id)getWallpaperSwitch:(PSSpecifier *)spec {
    return @(isWallpaperEnabled());
}

%new
- (void)setBlurSwitch:(id)value spec:(PSSpecifier *)spec {
    CFPreferencesSetAppValue(CFSTR("BlurWallpaperInAlwaysOn"), (__bridge CFPropertyListRef)(value), CFSTR("com.apple.BacklightServices"));
    CFPreferencesSetAppValue(CFSTR("BlurWallpaperInAlwaysOn"), (__bridge CFPropertyListRef)(value), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.BacklightServices"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    loadAODPreferences();
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);
}

%new
- (id)getBlurSwitch:(PSSpecifier *)spec {
    return @(isBlurWallpaperEnabled());
}

%new
- (void)setNotificationSwitch:(id)value spec:(PSSpecifier *)spec {
    CFPreferencesSetAppValue(CFSTR("ShowNotificationsInAlwaysOn"), (__bridge CFPropertyListRef)(value), CFSTR("com.apple.BacklightServices"));
    CFPreferencesSetAppValue(CFSTR("ShowNotificationsInAlwaysOn"), (__bridge CFPropertyListRef)(value), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.BacklightServices"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    loadAODPreferences();
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);
}

%new
- (id)getNotificationSwitch:(PSSpecifier *)spec {
    return @(isNotificationsEnabled());
}

%new
- (void)setCustomHz:(id)value spec:(PSSpecifier *)spec {
    CFPreferencesSetAppValue(CFSTR("CustomAODRefreshRate"), (__bridge CFPropertyListRef)(value), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    loadAODPreferences();
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);
}

%new
- (id)getCustomHz:(PSSpecifier *)spec {
    return @((int)getCustomAODRefreshRate());
}

%new
- (void)setCustomBrightness:(id)value spec:(PSSpecifier *)spec {
    CFPreferencesSetAppValue(CFSTR("CustomAODBrightness"), (__bridge CFPropertyListRef)(value), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    loadAODPreferences();
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);
}

%new
- (id)getCustomBrightness:(PSSpecifier *)spec {
    return @(getCustomAODBrightnessFactor() * 1000.0f);
}

%end // DBSAlwaysOnViewController

%end // Group_Preferences

//==============================================================
// 6. KHỞI TẠO TIẾN TRÌNH & ĐỒNG BỘ CẤU HÌNH REALTIME
//==============================================================

// Callback đồng bộ cấu hình tức thì từ Darwin Notification
static void AODPreferencesReloadCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    loadAODPreferences();
}

%ctor {
    @autoreleasepool {
        NSString *processName = [[NSProcessInfo processInfo] processName];
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

        // 1. Tải cấu hình vào bộ nhớ RAM ngay khi dylib inject
        loadAODPreferences();

        // 2. Lắng nghe Darwin Notification để cập nhật cấu hình realtime không cần respring
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            AODPreferencesReloadCallback,
            CFSTR("com.jb.aodreal/preferences.changed"),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        // 3. Phân luồng nạp Hook - Mỗi %init chỉ xuất hiện duy nhất 1 lần trong toàn bộ mã nguồn
        if ([bundleID isEqualToString:@"com.apple.springboard"] || [processName isEqualToString:@"SpringBoard"]) {
            %init(Group_SpringBoard);
        } else if ([bundleID isEqualToString:@"com.apple.PosterBoard"] || 
                   [processName.lowercaseString containsString:@"posterboard"]) {
            %init(Group_PosterBoard);
        } else if ([processName isEqualToString:@"backboardd"]) {
            %init(Group_Backboardd);
        } else if ([bundleID isEqualToString:@"com.apple.Preferences"] || 
                   [processName.lowercaseString containsString:@"preferences"] || 
                   [bundleID.lowercaseString containsString:@"preferences"]) {
            %init(Group_Preferences);
        }
    }
}
