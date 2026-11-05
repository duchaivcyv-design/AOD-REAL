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

// CỜ BẢO VỆ KHỞI ĐỘNG CHỈ DÀNH RIÊNG CHO SPRINGBOARD
static BOOL gSpringBoardDidFinishLaunching = NO;
static BOOL gIsSpringBoardProcess = NO;

// Biến lưu cấu hình tải nhanh trong bộ nhớ RAM
static BOOL gCachedAODEnabled = YES;
static BOOL gCachedWallpaperEnabled = YES;
static BOOL gCachedBlurWallpaperEnabled = YES;
static BOOL gCachedNotificationsEnabled = YES;
static float gCachedCustomHz = 1.0f; // Mặc định 1.0 Hz
static float gCachedBrightnessFactor = 0.005f;

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

    // 3. Công tắc Làm mờ ảnh trên hình nền
    valid = false;
    Boolean blurVal = CFPreferencesGetAppBooleanValue(CFSTR("BlurWallpaperInAlwaysOn"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) blurVal = CFPreferencesGetAppBooleanValue(CFSTR("BlurWallpaperInAlwaysOn"), CFSTR("com.jb.aodreal"), &valid);
    gCachedBlurWallpaperEnabled = valid ? (BOOL)blurVal : YES;

    // 4. Công tắc Hiển thị thông báo gốc
    valid = false;
    Boolean notiVal = CFPreferencesGetAppBooleanValue(CFSTR("ShowNotificationsInAlwaysOn"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) notiVal = CFPreferencesGetAppBooleanValue(CFSTR("ShowNotificationsInAlwaysOn"), CFSTR("com.jb.aodreal"), &valid);
    gCachedNotificationsEnabled = valid ? (BOOL)notiVal : YES;

    // 5. Nấc tần số quét tĩnh (1 - 5 Hz)
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

    // 6. Nấc độ sáng panel tĩnh
    CFPropertyListRef brVal = CFPreferencesCopyAppValue(CFSTR("CustomAODBrightness"), CFSTR("com.jb.aodreal"));
    if (brVal) {
        if (CFGetTypeID(brVal) == CFNumberGetTypeID()) {
            float b = [(__bridge NSNumber *)brVal floatValue];
            if (b >= 0.5f && b <= 20.0f) {
                gCachedBrightnessFactor = b / 1000.0f;
            }
        }
        CFRelease(brVal);
    } else {
        gCachedBrightnessFactor = 0.005f;
    }
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

// CHÍNH SÁCH NGẮT AOD TỰ ĐỘNG CHUẨN GỐC APPLE (IOKIT AN TOÀN - CHỐNG SIGTRAP VÀ LEAK BỘ NHỚ)
static inline BOOL shouldSuppressAODBySystemPolicies(void) {
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

//==============================================================
// 1. KHAI BÁO CÁC LỚP VÀ GIAO DIỆN HỆ THỐNG
//==============================================================

// Khai báo hook MobileSubstrate/ElleKit cho MobileGestalt runtime
#if defined(__cplusplus)
extern "C" {
#endif
void MSHookFunction(void *symbol, void *replace, void **result);
#if defined(__cplusplus)
}
#endif

@interface SpringBoard : UIApplication
- (void)applicationDidFinishLaunching:(id)application;
@end

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

// Lớp giao diện nội bộ tweak mở rộng từ PSListController
@interface AODRealInternalViewController : PSListController
- (id)getAODVal:(PSSpecifier *)spec;
- (void)setAODVal:(id)value specifier:(PSSpecifier *)spec;
- (id)getCustomHz:(PSSpecifier *)spec;
- (void)setCustomHz:(id)value spec:(PSSpecifier *)spec;
- (id)getCustomBrightness:(PSSpecifier *)spec;
- (void)setCustomBrightness:(id)value spec:(PSSpecifier *)spec;
@end

@interface DBSMainDisplayPreferencesController : PSListController
- (NSMutableArray *)specifiers;
- (id)getAODMasterStatusText:(PSSpecifier *)spec;
- (id)getAODLinkStatusText:(PSSpecifier *)spec;
@end

@interface DBSAlwaysOnViewController : PSListController
- (BOOL)shouldShowAlwaysOn;
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
+ (instancetype)sharedInstance;
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
- (void)setTextColor:(UIColor *)color;
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
// 2. TẦNG DRIVER & PHẦN CỨNG (BACKBOARDD) - ĐÃ SỬA LỖI CHẶN VÀO AOD
//==============================================================

%group Group_Backboardd

// BẢO VỆ NGUỒN ĐÈN NỀN PANEL: GIỮ NGUỒN CHO AOD KHI KHÔNG BỊ POLICY CHẶN
%hook CBController

- (void)setPowerState:(BOOL)state completion:(id)completion {
    if (isAODMasterEnabled() && !shouldSuppressAODBySystemPolicies()) {
        if (!state) {
            // Khi hệ thống yêu cầu tắt màn hình, ép giữ nguồn sáng tối thiểu cho AOD
            %orig(YES, completion);
            return;
        }
    }
    %orig(state, completion);
}

%end

// ÉP HẠ XUNG NHỊP HZ/FPS CHO AOD
%hook CAWindowServerDisplay

- (float)refreshRate {
    if (isAODMasterEnabled() && !shouldSuppressAODBySystemPolicies()) {
        return getCustomAODRefreshRate(); // 1.0f -> 5.0f Hz
    }
    return %orig;
}

- (void)setRefreshRate:(float)rate {
    if (isAODMasterEnabled() && !shouldSuppressAODBySystemPolicies()) {
        %orig(getCustomAODRefreshRate());
        return;
    }
    %orig(rate);
}

- (BOOL)blankingRemovesPower {
    if (isAODMasterEnabled() && !shouldSuppressAODBySystemPolicies()) {
        return NO;
    }
    return %orig;
}

- (void)setBlankingRemovesPower:(BOOL)val {
    if (isAODMasterEnabled() && !shouldSuppressAODBySystemPolicies()) {
        %orig(NO);
        return;
    }
    %orig(val);
}

- (BOOL)disabled {
    if (isAODMasterEnabled() && !shouldSuppressAODBySystemPolicies()) {
        return NO;
    }
    return %orig;
}

- (void)setDisabled:(BOOL)val {
    if (isAODMasterEnabled() && val && !shouldSuppressAODBySystemPolicies()) {
        %orig(NO);
        return;
    }
    %orig(val);
}

- (BOOL)isBlanked {
    if (isAODMasterEnabled() && !shouldSuppressAODBySystemPolicies()) {
        return NO;
    }
    return %orig;
}

- (void)setBlanked:(BOOL)blanked {
    if (isAODMasterEnabled() && blanked && !shouldSuppressAODBySystemPolicies()) {
        %orig(NO);
        return;
    }
    %orig(blanked);
}

- (BOOL)disablesUpdates {
    if (isAODMasterEnabled() && !shouldSuppressAODBySystemPolicies()) {
        return NO;
    }
    return %orig;
}

- (void)setDisablesUpdates:(BOOL)val {
    if (isAODMasterEnabled() && !shouldSuppressAODBySystemPolicies()) {
        %orig(NO);
        return;
    }
    %orig(val);
}

- (BOOL)isFlipBookActive {
    if (isAODMasterEnabled() && !shouldSuppressAODBySystemPolicies()) {
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
    if (isAODMasterEnabled() && shouldSuppressAODBySystemPolicies()) {
        return YES;
    }
    return %orig;
}

- (void)setFlipBookSuppressed:(BOOL)suppressed {
    if (isAODMasterEnabled() && !shouldSuppressAODBySystemPolicies() && suppressed) {
        %orig(NO);
        return;
    }
    %orig(suppressed);
}

- (void)powerStateDidChange:(id)arg1 {
    if (isAODMasterEnabled() && !shouldSuppressAODBySystemPolicies()) {
        return;
    }
    %orig(arg1);
}

%end

%hook BKDisplayRenderOverlay
- (BOOL)disablesDisplayBlanking { 
    return (isAODMasterEnabled() && !shouldSuppressAODBySystemPolicies()) ? YES : %orig; 
}
%end

%hook BKDisplayManager
- (void)setBlanked:(BOOL)blanked withReason:(id)reason {
    if (isAODMasterEnabled() && blanked && !shouldSuppressAODBySystemPolicies()) {
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
        return shouldSuppressAODBySystemPolicies() ? YES : NO;
    }
    return %orig;
}

- (long long)backlightState {
    long long state = %orig;
    if (isAODMasterEnabled() && state == 0) {
        if (!shouldSuppressAODBySystemPolicies()) {
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
        return shouldSuppressAODBySystemPolicies() ? YES : NO;
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
    if (isAODMasterEnabled() && !shouldSuppressAODBySystemPolicies()) {
        return (double)getCustomAODRefreshRate();
    }
    return %orig;
}

- (double)minimumGapDuration {
    if (isAODMasterEnabled() && !shouldSuppressAODBySystemPolicies()) {
        double fps = (double)getCustomAODRefreshRate();
        return (fps <= 1.0) ? 1.0 : (1.0 / fps);
    }
    return %orig;
}

%end

%hook BLSHAlwaysOnPresentationEngine

- (BOOL)isSuppressed {
    if (isAODMasterEnabled()) {
        if (shouldSuppressAODBySystemPolicies()) return YES;
    }
    return %orig;
}

- (void)setSuppressed:(BOOL)suppressed {
    if (isAODMasterEnabled() && !shouldSuppressAODBySystemPolicies() && suppressed) {
        %orig(NO);
        return;
    }
    %orig(suppressed);
}

- (BOOL)isUsingPseudoFlipbook { 
    return isAODMasterEnabled() ? YES : %orig; 
}

- (void)suspendForReason:(id)reason {
    if (isAODMasterEnabled() && !shouldSuppressAODBySystemPolicies()) {
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
    return (isAODMasterEnabled() && !shouldSuppressAODBySystemPolicies()) ? YES : %orig; 
}

- (BOOL)isClientActive { 
    if (shouldSuppressAODBySystemPolicies()) return NO;
    return isAODMasterEnabled() ? YES : %orig; 
}

- (long long)visualState {
    long long state = %orig;
    if (isAODMasterEnabled() && state == 0) {
        if (!shouldSuppressAODBySystemPolicies()) {
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

// HÀM KHÔI PHỤC NGAY LẬP TỨC 100% GIAO DIỆN, CỬ CHỈ HOME X VÀ CAMERA FACE ID
static void restoreLockScreenActiveUI(void) {
    gCurrentState = AODStateIdle;
    gCurrentAODProgress = 1.0f;

    if (gCoverSheetVC) {
        dispatch_async(dispatch_get_main_queue(), ^{
            gCoverSheetVC.view.transform = CGAffineTransformIdentity;
            gCoverSheetVC.view.backgroundColor = [UIColor clearColor];

            @try {
                UIViewController *statusBarVC = [gCoverSheetVC valueForKey:@"_statusBarViewController"];
                if (statusBarVC) {
                    statusBarVC.view.alpha = 1.0f;
                    statusBarVC.view.hidden = NO;
                }

                UIViewController *homeAffordanceVC = [gCoverSheetVC valueForKey:@"_homeAffordanceViewController"];
                if (homeAffordanceVC) {
                    homeAffordanceVC.view.alpha = 1.0f;
                    homeAffordanceVC.view.hidden = NO;
                }

                UIViewController *quickActionsVC = [gCoverSheetVC valueForKey:@"_quickActionsViewController"];
                if (quickActionsVC) {
                    quickActionsVC.view.alpha = 1.0f;
                    quickActionsVC.view.hidden = NO;
                }

                UIViewController *combinedListVC = [gCoverSheetVC valueForKey:@"_combinedListViewController"];
                if (combinedListVC) {
                    combinedListVC.view.transform = CGAffineTransformIdentity;
                    combinedListVC.view.alpha = 1.0f;
                    combinedListVC.view.hidden = NO;
                }
            } @catch (NSException *e) {}

            if ([gCoverSheetVC respondsToSelector:@selector(_updateAppearanceForAODTransitionToInactive:)]) {
                [gCoverSheetVC _updateAppearanceForAODTransitionToInactive:NO];
            }
        });
    }
}

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

- (void)dealloc {
    if (gCoverSheetVC == self) {
        gCoverSheetVC = nil;
    }
    %orig;
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    restoreLockScreenActiveUI();
}

- (BOOL)isAlwaysOnPresentation { 
    if (shouldSuppressAODBySystemPolicies() || gCurrentState != AODStateActive) return NO;
    return isAODMasterEnabled() ? YES : %orig; 
}

- (BOOL)shouldDimForAlwaysOn { 
    if (gCurrentState != AODStateActive) return NO;
    return isAODMasterEnabled() ? YES : %orig; 
}

- (BOOL)coverSheetIsObscured {
    if (gCurrentState == AODStateActive) return NO;
    return %orig;
}

- (long long)backlightLuminance {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) return 1;
    return %orig;
}

- (void)_updateAppearanceForAODTransitionToInactive:(BOOL)inactive {
    %orig(inactive);
    if (!isAODMasterEnabled()) return;

    if (shouldSuppressAODBySystemPolicies()) {
        gCurrentState = AODStateProximityOff;
        return;
    }

    if (inactive) {
        if (gCurrentState == AODStateActive) return;
        gCurrentState = AODStateTransitioning;

        // 1. Ẩn NGAY LẬP TỨC Status Bar, Home Affordance và 2 nút công cụ dưới đáy
        @try {
            UIViewController *statusBarVC = [self valueForKey:@"_statusBarViewController"];
            UIViewController *homeAffordanceVC = [self valueForKey:@"_homeAffordanceViewController"];
            UIViewController *quickActionsVC = [self valueForKey:@"_quickActionsViewController"];
            
            [UIView animateWithDuration:0.15f delay:0.0f options:UIViewAnimationOptionCurveEaseOut animations:^{
                if (statusBarVC) statusBarVC.view.alpha = 0.0f;
                if (homeAffordanceVC) homeAffordanceVC.view.alpha = 0.0f;
                if (quickActionsVC) quickActionsVC.view.alpha = 0.0f;
            } completion:^(BOOL fin) {
                if (statusBarVC) statusBarVC.view.hidden = YES;
                if (homeAffordanceVC) homeAffordanceVC.view.hidden = YES;
                if (quickActionsVC) quickActionsVC.view.hidden = YES;
            }];
        } @catch (NSException *e) {}

        // 2. Chuyển cảnh lặn 0.45s: Thu nhẹ màn hình + ÉP NHẸ THÔNG BÁO dạng nén co giãn
        [UIView animateWithDuration:0.45f delay:0.0f options:UIViewAnimationOptionCurveEaseInOut animations:^{
            self.view.transform = CGAffineTransformMakeScale(0.985f, 0.985f);

            // Ép nhẹ kích thước khối thông báo như gốc Apple
            @try {
                UIViewController *combinedListVC = [self valueForKey:@"_combinedListViewController"];
                if (combinedListVC) {
                    combinedListVC.view.transform = CGAffineTransformMakeScale(0.975f, 0.975f);
                    combinedListVC.view.alpha = isNotificationsEnabled() ? 0.85f : 0.0f;
                }
            } @catch (NSException *e) {}

            @try {
                [self _animateView:self.view toWhitePointReduced:YES withDuration:0.45f withDispatchGroup:nil];
                [self _updateWallpaperEffectView];
                [self _updateDateTimeView];
                [self _updateComplicationsContainerView];
            } @catch (NSException *e) {}
        } completion:^(BOOL finished) {
            if (finished && gCurrentState == AODStateTransitioning) {
                gCurrentState = AODStateActive;
                @try {
                    UIViewController *combinedListVC = [self valueForKey:@"_combinedListViewController"];
                    if (combinedListVC) {
                        combinedListVC.view.hidden = !isNotificationsEnabled();
                        combinedListVC.view.alpha = isNotificationsEnabled() ? 1.0f : 0.0f;
                    }
                } @catch (NSException *e) {}
            }
        }];
    } else {
        restoreLockScreenActiveUI();
    }
}

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
    } else {
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
    }
}

// XỬ LÝ HÌNH NỀN VÀ KHẮC PHỤC TRIỆT ĐỂ LỖI ĐEN LÕM CHIỀU SÂU (DEPTH EFFECT)
- (void)_updateWallpaperEffectView {
    %orig;
    
    UIView *floatingLayer = nil;
    UIView *effectView = nil;
    UIView *bgView = nil;
    UIView *posterPortalView = nil;

    @try {
        floatingLayer = [self valueForKey:@"_wallpaperFloatingLayerContainerView"];
        effectView = [self valueForKey:@"_wallpaperEffectView"];
        bgView = [self valueForKey:@"_backgroundView"];
        posterPortalView = [self valueForKey:@"_posterPortalView"];
    } @catch (NSException *e) {}

    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        if (!isWallpaperEnabled()) {
            // TẮT HÌNH NỀN: ÉP ĐỒNG BỘ 100% TẤT CẢ CÁC LỚP NỀN & LỚP NỔI CHIỀU SÂU VỀ ĐEN
            // Loại bỏ hoàn toàn tình trạng phần lõm chiều sâu bị đen loang lổ
            if (floatingLayer) {
                floatingLayer.alpha = 0.0f;
                floatingLayer.hidden = YES;
            }
            if (bgView) {
                bgView.alpha = 0.0f;
                bgView.hidden = YES;
            }
            if (posterPortalView) {
                posterPortalView.alpha = 0.0f;
                posterPortalView.hidden = YES;
            }
            if (effectView) {
                effectView.hidden = NO;
                effectView.backgroundColor = [UIColor blackColor];
                effectView.alpha = 1.0f;
            }
            self.view.backgroundColor = [UIColor blackColor];
        } else {
            // BẬT HÌNH NỀN: GIỮ NGUYÊN TẤNG CHIỀU SÂU VÀ ÁP LỚP MỜ ĐỒNG BỘ
            if (floatingLayer) {
                floatingLayer.hidden = NO;
                floatingLayer.alpha = 1.0f;
            }
            if (bgView) {
                bgView.hidden = NO;
                bgView.alpha = 1.0f;
            }
            if (posterPortalView) {
                posterPortalView.hidden = NO;
                posterPortalView.alpha = 1.0f;
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
        if (bgView) {
            bgView.hidden = NO;
            bgView.alpha = 1.0f;
        }
        if (posterPortalView) {
            posterPortalView.hidden = NO;
            posterPortalView.alpha = 1.0f;
        }
        if (effectView) {
            effectView.backgroundColor = [UIColor clearColor];
            effectView.alpha = 0.0f;
        }
        self.view.backgroundColor = [UIColor clearColor];
        self.view.transform = CGAffineTransformIdentity;
    }
}

- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession {
    return %orig;
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    restoreLockScreenActiveUI();
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
// ĐỒNG HỒ & WIDGET: CHỐNG MỜ TRONG SUỐT (LIQUID GLASS), ÉP ĐỤC TRẮNG SÁNG RÕ NÉT
// -------------------------------------------------------------
%hook SBFLockScreenDateView

- (id)vibrancyConfiguration {
    // Triệt tiêu vibrancy trong suốt khi vào AOD để đồng hồ không bị chìm/mờ
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return nil;
    }
    return %orig;
}

- (_UILegibilitySettings *)legibilitySettings {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        // Ép phong cách đục màu trắng nguyên khối (Style 1: White legibility)
        return [%c(_UILegibilitySettings) sharedInstanceForStyle:1];
    }
    return %orig;
}

// Đảm bảo các nhãn thời gian và ngày tháng luôn giữ sắc trắng đục nguyên chất
- (void)setTextColor:(UIColor *)color {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        %orig([UIColor colorWithWhite:1.0f alpha:0.92f]);
        return;
    }
    %orig(color);
}

%end

%hook SBFLockScreenDateViewController

- (BOOL)restrictsVibrancy {
    if (isAODMasterEnabled() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return YES; // Hạn chế tối đa hiệu ứng trong suốt để giữ sắc trắng đục
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
// ĐIỀU PHỐI ĐỘ SÁNG MÀN HÌNH VÀ VÒNG ĐỜI AOD (PHÂN BIỆT RÕ RÀNG TRẠNG THÁI)
// -------------------------------------------------------------
%hook SBBacklightController

- (void)_updateHIDUISensorModeForBacklightState:(long long)state source:(long long)source {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        %orig(1, source);
        return;
    }
    %orig(state, source);
}

- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion {
    if (isAODMasterEnabled()) {
        if (state == 0) {
            // Khi nhấn khoá màn hình: Vào tiến trình AOD
            if (gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) {
                gCurrentState = AODStateTransitioning;

                if (gCoverSheetVC && [gCoverSheetVC respondsToSelector:@selector(_updateAppearanceForAODTransitionToInactive:)]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [gCoverSheetVC _updateAppearanceForAODTransitionToInactive:YES];
                    });
                }
                state = 2; // Giữ state 2 để BacklightServices không dập màn hình về đen
            }
        } else if (state == 1 || state == 3) {
            // ĐÁNH THỨC SÁNG MÀN HÌNH KHÓA: TRẢ VỀ IDLE NGAY LẬP TỨC (MỞ LẠI CAMERA VÀ CỬ CHỈ)
            restoreLockScreenActiveUI();
        }
    }
    %orig(state, source, YES, completion);
}

- (float)_factorToPublishForBacklightState:(long long)state {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        if (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies()) {
            return 0.0f;
        }
        return getAODPanelBrightnessFactor();
    }
    return %orig(state);
}

- (void)animateBacklightToFactor:(float)factor duration:(double)duration source:(long long)source completion:(id)completion {
    if (isAODMasterEnabled()) {
        if (factor > 0.05f) {
            restoreLockScreenActiveUI();
        } else if (gCurrentState == AODStateActive) {
            factor = (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies()) ? 0.0f : getAODPanelBrightnessFactor();
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
// CHÍNH SÁCH HỆ THỐNG & ĐÓN BẮT SỰ KIỆN WAKE TOÀN DIỆN (CHO PHÉP CAMERA MỞ KHÓA FACE ID 2D)
// -------------------------------------------------------------
%hook SBLowPowerModeAlwaysOnPolicy
- (BOOL)isAlwaysOnPolicyActive {
    return [[NSProcessInfo processInfo] isLowPowerModeEnabled] ? YES : %orig;
}
%end

%hook SBFocusModeAlwaysOnPolicy
- (BOOL)isAlwaysOnPolicyActive { return %orig; }
%end

%hook SBThermalAlwaysOnPolicy
- (BOOL)isAlwaysOnPolicyActive { return %orig; }
%end

%hook SBLockScreenManager

- (BOOL)shouldPreventBacklightBlankingForAlwaysOn { 
    if (shouldSuppressAODBySystemPolicies() || gCurrentState == AODStateProximityOff) return NO;
    return (isAODMasterEnabled() && gCurrentState == AODStateActive) ? YES : %orig; 
}

- (void)lockUIFromSource:(int)source withOptions:(id)options {
    if (isAODMasterEnabled() && shouldSuppressAODBySystemPolicies()) {
        gCurrentState = AODStateProximityOff;
    }
    %orig;
}

// BẮT MỌI SỰ KIỆN THỨC MÀN HÌNH KHÓA ĐỂ CAMERA HOẠT ĐỘNG VÀ CỬ CHỈ HOME KHÔNG BỊ LIỆT
- (void)_wakeScreenForTapToWake {
    restoreLockScreenActiveUI();
    %orig;
}

- (void)tapToWakeControllerDidRecognizeWakeGesture:(id)gesture {
    restoreLockScreenActiveUI();
    %orig;
}

- (void)unlockUIFromSource:(int)source withOptions:(id)options {
    restoreLockScreenActiveUI();
    %orig;
}

%end

// -------------------------------------------------------------
// CHẠM 2 LẦN BẬT SÁNG & TRẢ LẠI 100% CẢM ỨNG CỬ CHỈ CHO MÀN HÌNH KHÓA
// -------------------------------------------------------------
%hook SBTapToWakeController

- (BOOL)isTapToWakeSupported { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)shouldTapToWake { return isAODMasterEnabled() ? YES : %orig; }

- (void)setTapToWakeGestureRecognizer:(UITapGestureRecognizer *)gesture {
    if (isAODMasterEnabled() && [gesture isKindOfClass:[UITapGestureRecognizer class]]) {
        gesture.numberOfTapsRequired = 2; // Chỉ nhấp đúp 2 lần mới wake
    }
    %orig(gesture);
}

// CHỈ BẬT DIGITIZER TAP-TO-WAKE KHI Ở AOD TĨNH; MÀN HÌNH KHÓA SÁNG TRẢ LẠI CHO CỬ CHỈ HOME X
- (void)setDigitizerInTapToWakeMode:(BOOL)mode {
    if (isAODMasterEnabled()) {
        if (gCurrentState == AODStateActive) {
            %orig(YES);
            return;
        } else {
            %orig(NO);
            return;
        }
    }
    %orig(mode);
}

- (void)tapToWakeDidRecognize:(UITapGestureRecognizer *)gesture {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        if ([gesture state] == UIGestureRecognizerStateRecognized || [gesture state] == UIGestureRecognizerStateEnded) {
            restoreLockScreenActiveUI();
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
    // CHỈ chặn cảm ứng khi màn hình ĐANG Ở AOD TĨNH
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return YES;
    }
    // Màn hình khóa sáng: Trả quyền hoàn toàn cho cử chỉ vuốt Home Bar X fake
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

// -------------------------------------------------------------
// CÔ LẬP NÚT HOME VẬT LÝ KHI Ở AOD
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

// LỚP VIEW CONTROLLER CON TỰ DỰNG (DÙNG %subclass ĐỂ CHỐNG LỖI LINKER VÀ CHẠY 100% TRÊN MỌI MÁY)
%subclass AODRealInternalViewController : PSListController

%new
- (id)getAODVal:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)key, CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) val = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)key, CFSTR("com.jb.aodreal"), &valid);
    return @(valid ? (BOOL)val : YES);
}

%new
- (void)setAODVal:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)(value), CFSTR("com.apple.BacklightServices"));
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)(value), CFSTR("com.jb.aodreal"));

    if ([key isEqualToString:@"AlwaysOnDisplayEnabled"]) {
        CFPreferencesSetAppValue(CFSTR("enabled"), (__bridge CFPropertyListRef)(value), CFSTR("com.apple.BacklightServices"));
        CFPreferencesSetAppValue(CFSTR("enabled"), (__bridge CFPropertyListRef)(value), CFSTR("com.jb.aodreal"));
    }

    CFPreferencesAppSynchronize(CFSTR("com.apple.BacklightServices"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    loadAODPreferences();
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);
    
    [self reloadSpecifiers];
}

%new
- (id)getCustomHz:(PSSpecifier *)spec {
    return @(getCustomAODRefreshRate());
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
            [s setProperty:[NSString stringWithFormat:@"Hiện tại: %.0f Hz (Tần số quét màn hình khi hiển thị AOD tĩnh)", roundedHz] forKey:@"footerText"];
            SEL reloadSel = @selector(reloadSpecifier:animated:);
            if ([self respondsToSelector:reloadSel]) {
                void (*reloadFunc)(id, SEL, id, BOOL) = (void (*)(id, SEL, id, BOOL))objc_msgSend;
                reloadFunc(self, reloadSel, s, NO);
            }
            break;
        }
    }
}

%new
- (id)getCustomBrightness:(PSSpecifier *)spec {
    return @(getCustomAODBrightnessFactor() * 1000.0f);
}

%new
- (void)setCustomBrightness:(id)value spec:(PSSpecifier *)spec {
    float b = [value floatValue];
    if (b < 0.5f) b = 0.5f;
    if (b > 20.0f) b = 20.0f;

    gCachedBrightnessFactor = b / 1000.0f;
    CFPreferencesSetAppValue(CFSTR("CustomAODBrightness"), (__bridge CFPropertyListRef)(@(b)), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);

    for (PSSpecifier *s in [self specifiers]) {
        if ([[s propertyForKey:@"id"] isEqualToString:@"AOD_BRIGHTNESS_GROUP_ID"]) {
            [s setProperty:[NSString stringWithFormat:@"Mức sáng: %.1f (Kéo thanh trượt để tinh chỉnh độ sáng đèn nền vừa mắt)", b] forKey:@"footerText"];
            SEL reloadSel = @selector(reloadSpecifier:animated:);
            if ([self respondsToSelector:reloadSel]) {
                void (*reloadFunc)(id, SEL, id, BOOL) = (void (*)(id, SEL, id, BOOL))objc_msgSend;
                reloadFunc(self, reloadSel, s, NO);
            }
            break;
        }
    }
}

- (NSMutableArray *)specifiers {
    NSMutableArray *specs = [self valueForKey:@"_specifiers"];
    if (specs) return specs;

    specs = [NSMutableArray array];

    // Chú thích mở đầu trang con
    PSSpecifier *headerGroup = [%c(PSSpecifier) preferenceSpecifierNamed:nil target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
    [headerGroup setProperty:@"Màn hình Luôn bật làm mờ Màn hình khóa trong khi vẫn giữ hiển thị thông tin như thời gian, tiện ích và thông báo bằng cách sử dụng nguồn điện tối thiểu.\n\nMàn hình sẽ tự động tắt để tiết kiệm pin khi không sử dụng." forKey:@"footerText"];
    [specs addObject:headerGroup];

    // Nhóm tùy biến (Customize)
    PSSpecifier *customGroup = [%c(PSSpecifier) preferenceSpecifierNamed:@"TÙY CHỈNH" target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
    [specs addObject:customGroup];

    // Switch 1: Hiển thị hình nền
    PSSpecifier *wpSwitch = [%c(PSSpecifier) preferenceSpecifierNamed:@"Hiển thị hình nền" target:self set:@selector(setAODVal:specifier:) get:@selector(getAODVal:) detail:Nil cell:6 edit:Nil];
    [wpSwitch setProperty:@"ShowWallpaperInAlwaysOn" forKey:@"key"];
    [wpSwitch setProperty:@"AOD_WP_KEY" forKey:@"id"];
    [specs addObject:wpSwitch];

    // Switch 2: Làm mờ ảnh hình nền
    PSSpecifier *blurSwitch = [%c(PSSpecifier) preferenceSpecifierNamed:@"Làm mờ ảnh hình nền" target:self set:@selector(setAODVal:specifier:) get:@selector(getAODVal:) detail:Nil cell:6 edit:Nil];
    [blurSwitch setProperty:@"BlurWallpaperInAlwaysOn" forKey:@"key"];
    [blurSwitch setProperty:@"AOD_BLUR_KEY" forKey:@"id"];
    [specs addObject:blurSwitch];

    // Switch 3: Hiển thị thông báo
    PSSpecifier *notifSwitch = [%c(PSSpecifier) preferenceSpecifierNamed:@"Hiển thị thông báo" target:self set:@selector(setAODVal:specifier:) get:@selector(getAODVal:) detail:Nil cell:6 edit:Nil];
    [notifSwitch setProperty:@"ShowNotificationsInAlwaysOn" forKey:@"key"];
    [notifSwitch setProperty:@"AOD_NOTIF_KEY" forKey:@"id"];
    [specs addObject:notifSwitch];

    // Nhóm công tắc chính
    PSSpecifier *masterGroup = [%c(PSSpecifier) preferenceSpecifierNamed:nil target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
    [masterGroup setProperty:@"Khi tắt Màn hình Luôn bật, màn hình sẽ tắt hoàn toàn khi iPhone bị khóa." forKey:@"footerText"];
    [specs addObject:masterGroup];

    PSSpecifier *masterSwitch = [%c(PSSpecifier) preferenceSpecifierNamed:@"Màn hình Luôn bật" target:self set:@selector(setAODVal:specifier:) get:@selector(getAODVal:) detail:Nil cell:6 edit:Nil];
    [masterSwitch setProperty:@"AlwaysOnDisplayEnabled" forKey:@"key"];
    [masterSwitch setProperty:@"AOD_MASTER_SWITCH_KEY" forKey:@"id"];
    [specs addObject:masterSwitch];

    // Thanh trượt phần cứng (Hz & Độ sáng)
    if (isAODMasterEnabled()) {
        PSSpecifier *hzGroup = [%c(PSSpecifier) preferenceSpecifierNamed:@"TẦN SỐ QUÉT TĨNH (1 - 5 HZ)" target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
        float curHz = getCustomAODRefreshRate();
        [hzGroup setProperty:[NSString stringWithFormat:@"Hiện tại: %.0f Hz (Tần số quét màn hình khi hiển thị AOD tĩnh)", curHz] forKey:@"footerText"];
        [hzGroup setProperty:@"AOD_HZ_GROUP_ID" forKey:@"id"];
        [specs addObject:hzGroup];

        PSSpecifier *hzSlider = [%c(PSSpecifier) preferenceSpecifierNamed:nil target:self set:@selector(setCustomHz:spec:) get:@selector(getCustomHz:) detail:Nil cell:5 edit:Nil];
        [hzSlider setProperty:@"PSSliderTableCell" forKey:@"cellClass"];
        [hzSlider setProperty:@"CustomAODRefreshRate" forKey:@"key"];
        [hzSlider setProperty:@"AOD_CUSTOM_HZ_KEY" forKey:@"id"];
        [hzSlider setProperty:@1.0f forKey:@"min"];
        [hzSlider setProperty:@5.0f forKey:@"max"];
        [hzSlider setProperty:@YES forKey:@"isSegmented"];
        [hzSlider setProperty:@4 forKey:@"segmentCount"];
        [hzSlider setProperty:@YES forKey:@"showValue"];
        [specs addObject:hzSlider];

        PSSpecifier *brightGroup = [%c(PSSpecifier) preferenceSpecifierNamed:@"ĐỘ SÁNG MÀN HÌNH TĨNH AOD" target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
        float curBr = getCustomAODBrightnessFactor() * 1000.0f;
        [brightGroup setProperty:[NSString stringWithFormat:@"Mức sáng: %.1f (Kéo thanh trượt để tinh chỉnh độ sáng đèn nền vừa mắt)", curBr] forKey:@"footerText"];
        [brightGroup setProperty:@"AOD_BRIGHTNESS_GROUP_ID" forKey:@"id"];
        [specs addObject:brightGroup];

        PSSpecifier *brightSlider = [%c(PSSpecifier) preferenceSpecifierNamed:nil target:self set:@selector(setCustomBrightness:spec:) get:@selector(getCustomBrightness:) detail:Nil cell:5 edit:Nil];
        [brightSlider setProperty:@"PSSliderTableCell" forKey:@"cellClass"];
        [brightSlider setProperty:@"CustomAODBrightness" forKey:@"key"];
        [brightSlider setProperty:@"AOD_CUSTOM_BRIGHTNESS_KEY" forKey:@"id"];
        [brightSlider setProperty:@0.5f forKey:@"min"];
        [brightSlider setProperty:@20.0f forKey:@"max"];
        [brightSlider setProperty:@YES forKey:@"showValue"];
        [specs addObject:brightSlider];
    }

    [self setValue:specs forKey:@"_specifiers"];
    return specs;
}

%end

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

// HOOK TRỰC TIẾP VÀO BƯỚC NẠP PLIST CỦA PSLISTCONTROLLER ĐỂ CHÈN MỤC AOD CHUẨN XÁC
%hook PSListController

- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target bundle:(NSBundle *)bundle {
    NSMutableArray *specs = %orig(name, target, bundle);

    if ([name isEqualToString:@"Display"] || 
        [bundle.bundlePath.lowercaseString containsString:@"display.bundle"] || 
        [NSStringFromClass([self class]) containsString:@"Display"]) {
        
        static NSString *const kAODRowID = @"ALWAYS_ON_DISPLAY_ROW_ID";
        static NSString *const kAODGroupID = @"ALWAYS_ON_DISPLAY_GROUP_ID";

        for (PSSpecifier *s in specs) {
            if ([[s propertyForKey:@"id"] isEqualToString:kAODRowID]) {
                return specs;
            }
        }

        Class detailClass = NSClassFromString(@"DBSAlwaysOnViewController");
        if (!detailClass) {
            detailClass = %c(AODRealInternalViewController);
        }

        // Nhóm chú thích
        PSSpecifier *aodGroup = [%c(PSSpecifier) preferenceSpecifierNamed:nil target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
        [aodGroup setProperty:kAODGroupID forKey:@"id"];
        [aodGroup setProperty:@"Màn hình Luôn bật làm mờ Màn hình khóa trong khi vẫn giữ hiển thị thông tin như thời gian, tiện ích và thông báo bằng cách sử dụng nguồn điện tối thiểu." forKey:@"footerText"];

        // Hàng dẫn vào trang con AOD
        PSSpecifier *aodLink = [%c(PSSpecifier) preferenceSpecifierNamed:@"Màn hình Luôn bật"
                                                                  target:self 
                                                                     set:NULL 
                                                                     get:@selector(getAODLinkStatusText:) 
                                                                  detail:detailClass 
                                                                    cell:2 // PSLinkCell
                                                                    edit:Nil];
        [aodLink setProperty:kAODRowID forKey:@"id"];
        [aodLink setProperty:detailClass forKey:@"detail"];
        [aodLink setProperty:@YES forKey:@"isController"];
        [aodLink setProperty:@YES forKey:@"enabled"];

        // Chèn vào vị trí ngay sau mục "Đưa lên để bật"
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
            [specs insertObject:aodGroup atIndex:targetIndex];
            [specs insertObject:aodLink atIndex:targetIndex + 1];
        } else {
            [specs addObject:aodGroup];
            [specs addObject:aodLink];
        }
    }

    return specs;
}

- (NSMutableArray *)specifiers {
    NSMutableArray *specs = %orig;

    if ([NSStringFromClass([self class]) containsString:@"Display"]) {
        static NSString *const kAODRowID = @"ALWAYS_ON_DISPLAY_ROW_ID";
        static NSString *const kAODGroupID = @"ALWAYS_ON_DISPLAY_GROUP_ID";

        BOOL exists = NO;
        for (PSSpecifier *s in specs) {
            if ([[s propertyForKey:@"id"] isEqualToString:kAODRowID]) {
                exists = YES;
                break;
            }
        }

        if (!exists && specs) {
            NSMutableArray *mSpecs = [specs mutableCopy];
            Class detailClass = NSClassFromString(@"DBSAlwaysOnViewController");
            if (!detailClass) {
                detailClass = %c(AODRealInternalViewController);
            }

            PSSpecifier *aodGroup = [%c(PSSpecifier) preferenceSpecifierNamed:nil target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
            [aodGroup setProperty:kAODGroupID forKey:@"id"];
            [aodGroup setProperty:@"Màn hình Luôn bật làm mờ Màn hình khóa trong khi vẫn giữ hiển thị thông tin như thời gian, tiện ích và thông báo bằng cách sử dụng nguồn điện tối thiểu." forKey:@"footerText"];

            PSSpecifier *aodLink = [%c(PSSpecifier) preferenceSpecifierNamed:@"Màn hình Luôn bật"
                                                                      target:self 
                                                                         set:NULL 
                                                                         get:@selector(getAODLinkStatusText:) 
                                                                      detail:detailClass 
                                                                        cell:2 
                                                                        edit:Nil];
            [aodLink setProperty:kAODRowID forKey:@"id"];
            [aodLink setProperty:detailClass forKey:@"detail"];
            [aodLink setProperty:@YES forKey:@"isController"];
            [aodLink setProperty:@YES forKey:@"enabled"];

            NSInteger targetIndex = -1;
            for (NSInteger i = 0; i < (NSInteger)mSpecs.count; i++) {
                NSString *sid = [[[mSpecs objectAtIndex:i] propertyForKey:@"id"] description].uppercaseString;
                if ([sid containsString:@"RAISE_TO_WAKE"] || [sid containsString:@"WAKE"]) {
                    targetIndex = i + 1;
                    break;
                }
            }

            if (targetIndex >= 0 && targetIndex <= (NSInteger)mSpecs.count) {
                [mSpecs insertObject:aodGroup atIndex:targetIndex];
                [mSpecs insertObject:aodLink atIndex:targetIndex + 1];
            } else {
                [mSpecs addObject:aodGroup];
                [mSpecs addObject:aodLink];
            }

            [self setValue:mSpecs forKey:@"_specifiers"];
            return mSpecs;
        }
    }

    return specs;
}

%new
- (id)getAODLinkStatusText:(PSSpecifier *)spec {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(CFSTR("AlwaysOnDisplayEnabled"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) val = CFPreferencesGetAppBooleanValue(CFSTR("enabled"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) val = CFPreferencesGetAppBooleanValue(CFSTR("enabled"), CFSTR("com.jb.aodreal"), &valid);
    BOOL isEnabled = valid ? (BOOL)val : YES;
    return isEnabled ? @"Bật" : @"Tắt";
}

%end

// HOOK GỐC APPLE TRANG CON DBSAlwaysOnViewController (NẾU THIẾT BỊ TẢI ĐƯỢC)
%hook DBSAlwaysOnViewController

- (BOOL)shouldShowAlwaysOn {
    return YES;
}

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
    NSArray *origSpecs = %orig;
    NSMutableArray *specs = origSpecs ? [origSpecs mutableCopy] : [NSMutableArray array];

    Boolean valid = false;
    Boolean masterVal = CFPreferencesGetAppBooleanValue(CFSTR("AlwaysOnDisplayEnabled"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) masterVal = CFPreferencesGetAppBooleanValue(CFSTR("enabled"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) masterVal = CFPreferencesGetAppBooleanValue(CFSTR("enabled"), CFSTR("com.jb.aodreal"), &valid);
    BOOL isMasterOn = valid ? (BOOL)masterVal : YES;

    if (isMasterOn) {
        PSSpecifier *hzGroup = [%c(PSSpecifier) preferenceSpecifierNamed:@"TẦN SỐ QUÉT TĨNH (1 - 5 HZ)" target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
        float curHz = getCustomAODRefreshRate();
        [hzGroup setProperty:[NSString stringWithFormat:@"Hiện tại: %.0f Hz (Tần số quét màn hình khi hiển thị AOD tĩnh)", curHz] forKey:@"footerText"];
        [hzGroup setProperty:@"AOD_HZ_GROUP_ID" forKey:@"id"];
        [specs addObject:hzGroup];

        PSSpecifier *hzSlider = [%c(PSSpecifier) preferenceSpecifierNamed:nil target:self set:@selector(setCustomHz:spec:) get:@selector(getCustomHz:) detail:Nil cell:5 edit:Nil];
        [hzSlider setProperty:@"PSSliderTableCell" forKey:@"cellClass"];
        [hzSlider setProperty:@"CustomAODRefreshRate" forKey:@"key"];
        [hzSlider setProperty:@"AOD_CUSTOM_HZ_KEY" forKey:@"id"];
        [hzSlider setProperty:@1.0f forKey:@"min"];
        [hzSlider setProperty:@5.0f forKey:@"max"];
        [hzSlider setProperty:@YES forKey:@"isSegmented"];
        [hzSlider setProperty:@4 forKey:@"segmentCount"];
        [hzSlider setProperty:@YES forKey:@"showValue"];
        [specs addObject:hzSlider];

        PSSpecifier *brightGroup = [%c(PSSpecifier) preferenceSpecifierNamed:@"ĐỘ SÁNG MÀN HÌNH TĨNH AOD" target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
        float curBr = getCustomAODBrightnessFactor() * 1000.0f;
        [brightGroup setProperty:[NSString stringWithFormat:@"Mức sáng: %.1f (Kéo thanh trượt để tinh chỉnh độ sáng đèn nền vừa mắt)", curBr] forKey:@"footerText"];
        [brightGroup setProperty:@"AOD_BRIGHTNESS_GROUP_ID" forKey:@"id"];
        [specs addObject:brightGroup];

        PSSpecifier *brightSlider = [%c(PSSpecifier) preferenceSpecifierNamed:nil target:self set:@selector(setCustomBrightness:spec:) get:@selector(getCustomBrightness:) detail:Nil cell:5 edit:Nil];
        [brightSlider setProperty:@"PSSliderTableCell" forKey:@"cellClass"];
        [brightSlider setProperty:@"CustomAODBrightness" forKey:@"key"];
        [brightSlider setProperty:@"AOD_CUSTOM_BRIGHTNESS_KEY" forKey:@"id"];
        [brightSlider setProperty:@0.5f forKey:@"min"];
        [brightSlider setProperty:@20.0f forKey:@"max"];
        [brightSlider setProperty:@YES forKey:@"showValue"];
        [specs addObject:brightSlider];
    }

    [self setValue:specs forKey:@"_specifiers"];
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
            [s setProperty:[NSString stringWithFormat:@"Hiện tại: %.0f Hz (Tần số quét màn hình khi hiển thị AOD tĩnh)", roundedHz] forKey:@"footerText"];
            SEL reloadSel = @selector(reloadSpecifier:animated:);
            if ([self respondsToSelector:reloadSel]) {
                void (*reloadFunc)(id, SEL, id, BOOL) = (void (*)(id, SEL, id, BOOL))objc_msgSend;
                reloadFunc(self, reloadSel, s, NO);
            }
            break;
        }
    }
}

%new
- (id)getCustomHz:(PSSpecifier *)spec {
    return @(getCustomAODRefreshRate());
}

%new
- (void)setCustomBrightness:(id)value spec:(PSSpecifier *)spec {
    float b = [value floatValue];
    if (b < 0.5f) b = 0.5f;
    if (b > 20.0f) b = 20.0f;

    gCachedBrightnessFactor = b / 1000.0f;
    CFPreferencesSetAppValue(CFSTR("CustomAODBrightness"), (__bridge CFPropertyListRef)(@(b)), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);

    for (PSSpecifier *s in [self specifiers]) {
        if ([[s propertyForKey:@"id"] isEqualToString:@"AOD_BRIGHTNESS_GROUP_ID"]) {
            [s setProperty:[NSString stringWithFormat:@"Mức sáng: %.1f (Kéo thanh trượt để tinh chỉnh độ sáng đèn nền vừa mắt)", b] forKey:@"footerText"];
            SEL reloadSel = @selector(reloadSpecifier:animated:);
            if ([self respondsToSelector:reloadSel]) {
                void (*reloadFunc)(id, SEL, id, BOOL) = (void (*)(id, SEL, id, BOOL))objc_msgSend;
                reloadFunc(self, reloadSel, s, NO);
            }
            break;
        }
    }
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

static void AODPreferencesReloadCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    loadAODPreferences();
}

%ctor {
    @autoreleasepool {
        // 1. Khởi tạo bắt buộc cho nhóm mặc định (chứa %subclass và các hook ngoài group)
        %init;

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

        // 2. Khởi tạo theo từng tiến trình hệ thống
        if ([bundleID isEqualToString:@"com.apple.springboard"] || 
            [processName isEqualToString:@"SpringBoard"] || 
            [processName.lowercaseString isEqualToString:@"springboard"]) {
            
            gIsSpringBoardProcess = YES;
            gCurrentState = AODStateIdle;
            %init(Group_SpringBoard);
            
        } else if ([bundleID isEqualToString:@"com.apple.PosterBoard"] || 
                   [processName.lowercaseString containsString:@"posterboard"]) {
            
            %init(Group_PosterBoard);
            
        } else if ([processName isEqualToString:@"backboardd"]) {
            
            %init(Group_Backboardd);
            
        } else if ([bundleID isEqualToString:@"com.apple.Preferences"] || 
                   [processName.lowercaseString containsString:@"preferences"]) {
            
            // Hook MobileGestalt runtime
            void *gestaltHandle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
            if (gestaltHandle) {
                void *mgFunc = dlsym(gestaltHandle, "MGGetBoolAnswer");
                if (mgFunc) {
                    MSHookFunction(mgFunc, (void *)replaced_MGGetBoolAnswer, (void **)&orig_MGGetBoolAnswer);
                }
            }

            // Ép nạp các bundle hiển thị của Apple vào bộ nhớ Preferences
            [[NSBundle bundleWithPath:@"/System/Library/PreferenceBundles/Display.bundle"] load];
            dlopen("/System/Library/PreferenceBundles/Display.bundle/Display", RTLD_NOW | RTLD_GLOBAL);
            dlopen("/System/Library/PrivateFrameworks/DisplayAndBrightnessSettings.framework/DisplayAndBrightnessSettings", RTLD_NOW | RTLD_GLOBAL);
            dlopen("/System/Library/PrivateFrameworks/Settings/DisplayAndBrightnessSettings.framework/DisplayAndBrightnessSettings", RTLD_NOW | RTLD_GLOBAL);

            %init(Group_Preferences);
        }
    }
}
