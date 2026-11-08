#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAFrameRateRange.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <spawn.h>

// Khai báo hook MobileSubstrate/ElleKit cho MobileGestalt runtime
#if defined(__cplusplus)
extern "C" {
#endif
void MSHookFunction(void *symbol, void *replace, void **result);
#if defined(__cplusplus)
}
#endif

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
static float gCachedBrightnessFactor = 0.025f; // Chuẩn AOD gốc Apple (25/1000 = 2.5%)

// ĐỒNG BỘ TRẠNG THÁI LIÊN TIẾN TRÌNH (SPRINGBOARD <-> BACKBOARDD)
static inline void setAODStateGlobal(AODState newState) {
    if (gCurrentState == newState) return;
    gCurrentState = newState;
    if (gIsSpringBoardProcess) {
        if (newState == AODStateActive) {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/state.active"), NULL, NULL, YES);
        } else if (newState == AODStateIdle) {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/state.idle"), NULL, NULL, YES);
        }
    }
}

static inline void loadAODPreferences(void) {
    CFPreferencesAppSynchronize(CFSTR("com.apple.BacklightServices"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));

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

    // 6. Nấc độ sáng panel tĩnh (Nhân 1000: 25.0f tương đương 0.025f - chuẩn AOD gốc Apple)
    CFPropertyListRef brVal = CFPreferencesCopyAppValue(CFSTR("CustomAODBrightness"), CFSTR("com.jb.aodreal"));
    if (brVal) {
        if (CFGetTypeID(brVal) == CFNumberGetTypeID()) {
            float b = [(__bridge NSNumber *)brVal floatValue];
            if (b >= 5.0f && b <= 50.0f) {
                gCachedBrightnessFactor = b / 1000.0f;
            }
        }
        CFRelease(brVal);
    } else {
        gCachedBrightnessFactor = 0.025f; // Mặc định sáng rõ nét ngang AOD Apple
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

// CHÍNH SÁCH NGẮT AOD TỰ ĐỘNG CHUẨN GỐC (DÙNG UIKIT THUẦN - KHÔNG XUNG ĐỘT MODULE C++)
static inline BOOL shouldSuppressAODBySystemPolicies(void) {
    if ([[NSProcessInfo processInfo] isLowPowerModeEnabled]) {
        return YES;
    }

    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    float level = [UIDevice currentDevice].batteryLevel;
    UIDeviceBatteryState state = [UIDevice currentDevice].batteryState;

    // Đang cắm sạc thì không chặn AOD
    if (state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull) {
        return NO;
    }

    // Pin dưới hoặc bằng 5% thì ngắt AOD để bảo toàn nguồn
    if (level >= 0.0f && level <= 0.05f) {
        return YES;
    }

    return NO;
}

//==============================================================
// 1. KHAI BÁO CÁC LỚP VÀ GIAO DIỆN HỆ THỐNG
//==============================================================

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
// 👈 THÊM 2 dòng này vào PSListController luôn cho chắc (dùng ở nhiều nơi)
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
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
// 👈 THÊM 2 DÒNG NÀY (đây chính là nguyên nhân lỗi compile)
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
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
// 2. TẦNG DRIVER & PHẦN CỨNG (BACKBOARDD) - ĐỒNG BỘ NGUỒN VÀ TẦN SỐ QUÉT
//==============================================================

%group Group_Backboardd

static BOOL gBackboarddInAOD = NO;

// Nhận tín hiệu IPC từ SpringBoard
static void BackboarddAODStateActive(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    gBackboarddInAOD = YES;
}

static void BackboarddAODStateIdle(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    gBackboarddInAOD = NO;
    // Ngay lập tức mở lại tần số quét 60Hz gốc của iOS để chống lag
    @try {
        Class caServerClass = NSClassFromString(@"CAWindowServer");
        if (caServerClass && [caServerClass respondsToSelector:@selector(serverIfRunning)]) {
            id server = [caServerClass performSelector:@selector(serverIfRunning)];
            NSArray *displays = [server valueForKey:@"displays"];
            if (displays && displays.count > 0) {
                CAWindowServerDisplay *mainDisplay = [displays objectAtIndex:0];
                if ([mainDisplay respondsToSelector:@selector(setRefreshRate:)]) {
                    [mainDisplay setRefreshRate:0.0f]; // 0.0f = auto / full rate gốc hệ thống
                }
            }
        }
    } @catch (NSException *e) {}
}

// 1. GIỮ NGUỒN SÁNG MÀN HÌNH KHI ĐANG Ở AOD TĨNH
%hook CBController

- (void)setPowerState:(BOOL)state completion:(id)completion {
    if (isAODMasterEnabled() && !shouldSuppressAODBySystemPolicies()) {
        if (!state && gBackboarddInAOD) {
            // Khi hệ thống yêu cầu ngắt màn hình lúc vào AOD, giữ nguồn sáng tối thiểu
            %orig(YES, completion);
            return;
        }
    }
    %orig(state, completion);
}

%end

// 2. ĐIỀU KHIỂN TẦN SỐ QUÉT: CHỈ HẠ HZ KHI Ở AOD, MỞ KHÓA TRẢ LẠI 60HZ GỐC
%hook CAWindowServerDisplay

- (float)refreshRate {
    if (isAODMasterEnabled() && gBackboarddInAOD && !shouldSuppressAODBySystemPolicies()) {
        return getCustomAODRefreshRate(); // 1.0f -> 5.0f Hz tùy chỉnh
    }
    return %orig; // Màn hình sáng / HomeScreen: Trả về tốc độ mượt gốc
}

- (void)setRefreshRate:(float)rate {
    if (isAODMasterEnabled() && gBackboarddInAOD && !shouldSuppressAODBySystemPolicies()) {
        %orig(getCustomAODRefreshRate());
        return;
    }
    %orig(rate);
}

- (BOOL)blankingRemovesPower {
    if (isAODMasterEnabled() && gBackboarddInAOD && !shouldSuppressAODBySystemPolicies()) {
        return NO;
    }
    return %orig;
}

- (void)setBlankingRemovesPower:(BOOL)val {
    if (isAODMasterEnabled() && gBackboarddInAOD && !shouldSuppressAODBySystemPolicies()) {
        %orig(NO);
        return;
    }
    %orig(val);
}

- (BOOL)isBlanked {
    if (isAODMasterEnabled() && gBackboarddInAOD && !shouldSuppressAODBySystemPolicies()) {
        return NO;
    }
    return %orig;
}

- (void)setBlanked:(BOOL)blanked {
    if (isAODMasterEnabled() && blanked && gBackboarddInAOD && !shouldSuppressAODBySystemPolicies()) {
        %orig(NO);
        return;
    }
    %orig(blanked);
}

%end

// 3. CHẶN BLANKING MÀN HÌNH TỪ DISPLAY MANAGER CỦA BACKBOARDD
%hook BKDisplayRenderOverlay
- (BOOL)disablesDisplayBlanking { 
    return (isAODMasterEnabled() && gBackboarddInAOD && !shouldSuppressAODBySystemPolicies()) ? YES : %orig; 
}
%end

%hook BKDisplayManager
- (void)setBlanked:(BOOL)blanked withReason:(id)reason {
    if (isAODMasterEnabled() && blanked && gBackboarddInAOD && !shouldSuppressAODBySystemPolicies()) {
        %orig(NO, reason);
        return;
    }
    %orig(blanked, reason);
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
static BOOL gIsAODTransitioning = NO;

// Helper truy xuất view controller an toàn qua KVC / Runtime
static inline UIViewController *safeGetVC(id target, NSString *key) {
    @try {
        return [target valueForKey:key];
    } @catch (NSException *e) {
        return nil;
    }
}

// HÀM KHÔI PHỤC NGAY LẬP TỨC 100% GIAO DIỆN KHI THỨC MÀN HÌNH HOẶC MỞ KHÓA
static void restoreLockScreenActiveUI(void) {
    if (gCurrentState == AODStateIdle && !gIsAODTransitioning) return;
    
    gCurrentState = AODStateIdle;
    gIsAODTransitioning = NO;
    gCurrentAODProgress = 1.0f;

    // Bắn thông báo Darwin để Backboardd lập tức trả lại 60Hz/120Hz
    setAODStateGlobal(AODStateIdle);

    void (^restoreBlock)(void) = ^{
        CSCoverSheetViewController *csvc = gCoverSheetVC;
        if (!csvc) return;

        csvc.view.transform = CGAffineTransformIdentity;
        csvc.view.backgroundColor = [UIColor clearColor];

        @try {
            if ([csvc respondsToSelector:@selector(_animateView:toWhitePointReduced:withDuration:withDispatchGroup:)]) {
                [csvc _animateView:csvc.view toWhitePointReduced:NO withDuration:0.15f withDispatchGroup:nil];
            }

            UIViewController *dateVC = safeGetVC(csvc, @"_dateTimeViewController");
            if (dateVC && dateVC.view) {
                dateVC.view.transform = CGAffineTransformIdentity;
            }

            UIViewController *statusBarVC = safeGetVC(csvc, @"_statusBarViewController");
            if (statusBarVC && statusBarVC.view) {
                statusBarVC.view.alpha = 1.0f;
                statusBarVC.view.hidden = NO;
            }

            UIViewController *homeAffordanceVC = safeGetVC(csvc, @"_homeAffordanceViewController");
            if (homeAffordanceVC && homeAffordanceVC.view) {
                homeAffordanceVC.view.alpha = 1.0f;
                homeAffordanceVC.view.hidden = NO;
            }

            UIViewController *quickActionsVC = safeGetVC(csvc, @"_quickActionsViewController");
            if (quickActionsVC && quickActionsVC.view) {
                quickActionsVC.view.alpha = 1.0f;
                quickActionsVC.view.hidden = NO;
            }

            UIViewController *combinedListVC = safeGetVC(csvc, @"_combinedListViewController");
            if (combinedListVC && combinedListVC.view) {
                combinedListVC.view.transform = CGAffineTransformIdentity;
                combinedListVC.view.alpha = 1.0f;
                combinedListVC.view.hidden = NO;
            }
        } @catch (NSException *e) {}

        if ([csvc respondsToSelector:@selector(_updateWallpaperEffectView)]) {
            [csvc _updateWallpaperEffectView];
        }
    };

    if ([NSThread isMainThread]) {
        restoreBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), restoreBlock);
    }
}

// -------------------------------------------------------------
// KHỞI ĐỘNG AN TOÀN
// -------------------------------------------------------------
%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    gSpringBoardDidFinishLaunching = YES;
}

%end

// -------------------------------------------------------------
// ĐIỀU PHỐI STATUS BAR COVERSHEET
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
// COVERSHEET: LẶN ĐỒNG HỒ CO NHẸ (0.965), ĐỤC TRẮNG
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
        setAODStateGlobal(AODStateProximityOff);
        return;
    }

    if (inactive) {
        if (gIsAODTransitioning) return;
        gIsAODTransitioning = YES;

        // 1. Ẩn dứt khoát controls phụ trợ ngay lập tức tại 0ms
        UIViewController *statusBarVC = safeGetVC(self, @"_statusBarViewController");
        UIViewController *homeAffordanceVC = safeGetVC(self, @"_homeAffordanceViewController");
        UIViewController *quickActionsVC = safeGetVC(self, @"_quickActionsViewController");
        
        if (statusBarVC && statusBarVC.view) { statusBarVC.view.alpha = 0.0f; statusBarVC.view.hidden = YES; }
        if (homeAffordanceVC && homeAffordanceVC.view) { homeAffordanceVC.view.alpha = 0.0f; homeAffordanceVC.view.hidden = YES; }
        if (quickActionsVC && quickActionsVC.view) { quickActionsVC.view.alpha = 0.0f; quickActionsVC.view.hidden = YES; }

        // 2. Chạy animation thu nhỏ nhẹ và giảm White Point (0.45s mượt mà)
        [UIView animateWithDuration:0.45f delay:0.0f options:UIViewAnimationOptionCurveEaseInOut animations:^{
            self.view.transform = CGAffineTransformMakeScale(0.985f, 0.985f);

            UIViewController *dateVC = safeGetVC(self, @"_dateTimeViewController");
            if (dateVC && dateVC.view) {
                dateVC.view.transform = CGAffineTransformMakeScale(0.965f, 0.965f);
            }

            UIViewController *combinedListVC = safeGetVC(self, @"_combinedListViewController");
            if (combinedListVC && combinedListVC.view) {
                combinedListVC.view.transform = CGAffineTransformMakeScale(0.975f, 0.975f);
                combinedListVC.view.alpha = isNotificationsEnabled() ? 0.85f : 0.0f;
            }

            if ([self respondsToSelector:@selector(_animateView:toWhitePointReduced:withDuration:withDispatchGroup:)]) {
                [self _animateView:self.view toWhitePointReduced:YES withDuration:0.45f withDispatchGroup:nil];
            }
            [self _updateWallpaperEffectView];
        } completion:^(BOOL finished) {
            gIsAODTransitioning = NO;
            if (gCurrentState == AODStateActive) {
                UIViewController *combinedListVC = safeGetVC(self, @"_combinedListViewController");
                if (combinedListVC && combinedListVC.view) {
                    combinedListVC.view.hidden = !isNotificationsEnabled();
                    combinedListVC.view.alpha = isNotificationsEnabled() ? 1.0f : 0.0f;
                }
            }
        }];
    } else {
        restoreLockScreenActiveUI();
    }
}

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

    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        if (!isWallpaperEnabled()) {
            if (floatingLayer) { floatingLayer.alpha = 0.0f; floatingLayer.hidden = YES; }
            if (bgView) { bgView.alpha = 0.0f; bgView.hidden = YES; }
            if (posterPortalView) { posterPortalView.alpha = 0.0f; posterPortalView.hidden = YES; }
            if (effectView) {
                effectView.hidden = NO;
                effectView.backgroundColor = [UIColor blackColor];
                effectView.alpha = 1.0f;
            }
            self.view.backgroundColor = [UIColor blackColor];
        } else {
            if (floatingLayer) { floatingLayer.hidden = NO; floatingLayer.alpha = 1.0f; }
            if (bgView) { bgView.hidden = NO; bgView.alpha = 1.0f; }
            if (posterPortalView) { posterPortalView.hidden = NO; posterPortalView.alpha = 1.0f; }
            if (effectView) {
                effectView.hidden = NO;
                effectView.backgroundColor = isBlurWallpaperEnabled() ? [UIColor colorWithWhite:0.0f alpha:0.45f] : [UIColor clearColor];
                effectView.alpha = isBlurWallpaperEnabled() ? 1.0f : 0.0f;
            }
            self.view.backgroundColor = [UIColor clearColor];
        }
    } else {
        if (floatingLayer) { floatingLayer.hidden = NO; floatingLayer.alpha = 1.0f; }
        if (bgView) { bgView.hidden = NO; bgView.alpha = 1.0f; }
        if (posterPortalView) { posterPortalView.hidden = NO; posterPortalView.alpha = 1.0f; }
        if (effectView) {
            effectView.backgroundColor = [UIColor clearColor];
            effectView.alpha = 0.0f;
        }
        self.view.backgroundColor = [UIColor clearColor];
        self.view.transform = CGAffineTransformIdentity;
    }
}

%end

// -------------------------------------------------------------
// QUẢN LÝ DANH SÁCH THÔNG BÁO
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
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        %orig(!isNotificationsEnabled(), reason);
        return;
    }
    %orig(hidden, reason);
}

%end

// TRIỆT TIÊU HÌNH NỀN SÓT KHI TẮT HÌNH NỀN
%hook CSBackgroundContentViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    if (isAODMasterEnabled() && !isWallpaperEnabled() && gCurrentState == AODStateActive) {
        self.view.alpha = 0.0f;
        self.view.hidden = YES;
    }
}

%end

// -------------------------------------------------------------
// ĐỒNG HỒ & WIDGET: ÉP ĐỤC TRẮNG NGUYÊN BẢN, TRIỆT TIÊU VIBRANCY
// -------------------------------------------------------------
%hook SBFLockScreenDateView

- (id)vibrancyConfiguration {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return nil;
    }
    return %orig;
}

- (_UILegibilitySettings *)legibilitySettings {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return [%c(_UILegibilitySettings) sharedInstanceForStyle:1];
    }
    return %orig;
}

- (void)setTextColor:(UIColor *)color {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        %orig([UIColor colorWithWhite:1.0f alpha:0.95f]);
        return;
    }
    %orig(color);
}

%end

%hook SBFLockScreenDateViewController

- (BOOL)restrictsVibrancy {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return YES;
    }
    return %orig;
}

- (_UILegibilitySettings *)legibilitySettings {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
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
        
        [UIView animateWithDuration:0.3f delay:0.0 options:UIViewAnimationOptionCurveLinear animations:^{
            self.view.transform = CGAffineTransformConcat(
                CGAffineTransformMakeScale(0.965f, 0.965f), 
                CGAffineTransformMakeTranslation(dx, dy)
            );
        } completion:nil];
    } else {
        self.view.transform = CGAffineTransformIdentity;
    }
}

%end

// -------------------------------------------------------------
// ĐIỀU PHỐI ĐỘ SÁNG MÀN HÌNH VÀ VÒNG ĐỜI AOD (BẢO VỆ NGUỒN SÁNG TỨC THÌ)
// -------------------------------------------------------------
%hook SBBacklightController

- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion {
    if (isAODMasterEnabled()) {
        if (state == 0) {
            // Nhấn nút nguồn tắt màn hình -> BẮT BUỘC BẮN TÍN HIỆU ACTIVE TỨC THÌ ĐỂ BACKBOARDD GIỮ NGUỒN ĐIỆN
            if (!shouldSuppressAODBySystemPolicies() && gCurrentState != AODStateProximityOff) {
                setAODStateGlobal(AODStateActive);

                CSCoverSheetViewController *csvc = gCoverSheetVC;
                if (csvc && [csvc respondsToSelector:@selector(_updateAppearanceForAODTransitionToInactive:)]) {
                    [csvc _updateAppearanceForAODTransitionToInactive:YES];
                }
                
                // Giữ backlight ở state 2 (dimmed) thay vì 0 (screen off hoàn toàn)
                %orig(2, source, YES, completion);
                return;
            }
        } else if (state == 1 || state == 3) {
            restoreLockScreenActiveUI();
        }
    }
    %orig(state, source, animated, completion);
}

- (float)_factorToPublishForBacklightState:(long long)state {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies()) ? 0.0f : getAODPanelBrightnessFactor();
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

// -------------------------------------------------------------
// CHỐNG BLANKING WINDOW TẮT ĐEN MÀN HÌNH Ở SPRINGBOARD
// -------------------------------------------------------------
%hook SBBacklightPlatformProvider

- (BOOL)isShowingBlankingWindow {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) {
        return NO;
    }
    return %orig;
}

- (void)showBlankingWindow:(BOOL)show withFadeDuration:(double)duration {
    if (isAODMasterEnabled() && show && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) {
        return;
    }
    %orig(show, duration);
}

- (void)_setBlankingWindowVisible:(BOOL)visible fadeDuration:(double)duration {
    if (isAODMasterEnabled() && visible && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) {
        return;
    }
    %orig(visible, duration);
}

%end

// -------------------------------------------------------------
// ĐÓN BẮT SỰ KIỆN MỞ KHÓA MÀN HÌNH CHÍNH
// -------------------------------------------------------------
%hook SBLockScreenManager

- (BOOL)shouldPreventBacklightBlankingForAlwaysOn {
    if (shouldSuppressAODBySystemPolicies() || gCurrentState == AODStateProximityOff) return NO;
    return (isAODMasterEnabled() && gCurrentState == AODStateActive) ? YES : %orig;
}

- (void)unlockUIFromSource:(int)source withOptions:(id)options {
    restoreLockScreenActiveUI();
    %orig(source, options);
}

- (void)_wakeScreenForTapToWake {
    restoreLockScreenActiveUI();
    %orig;
}

- (void)tapToWakeControllerDidRecognizeWakeGesture:(id)gesture {
    restoreLockScreenActiveUI();
    %orig;
}

%end

// -------------------------------------------------------------
// CHẠM 2 LẦN ĐỂ ĐÁNH THỨC (DOUBLE TAP TO WAKE)
// -------------------------------------------------------------
%hook SBTapToWakeController

- (BOOL)isTapToWakeSupported { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)shouldTapToWake { return isAODMasterEnabled() ? YES : %orig; }

- (void)setTapToWakeGestureRecognizer:(UITapGestureRecognizer *)gesture {
    if (isAODMasterEnabled() && [gesture isKindOfClass:[UITapGestureRecognizer class]]) {
        gesture.numberOfTapsRequired = 2; // Yêu cầu 2 chạm để tránh cấn túi
    }
    %orig(gesture);
}

- (void)setDigitizerInTapToWakeMode:(BOOL)mode {
    if (isAODMasterEnabled()) {
        %orig(gCurrentState == AODStateActive);
        return;
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
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return YES;
    }
    return %orig;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

%end

// -------------------------------------------------------------
// CẢM BIẾN TIỆM CẬN (PROXIMITY SENSOR)
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
        setAODStateGlobal(AODStateProximityOff);
        [[%c(SBBacklightController) sharedInstance] setBacklightState:0 source:1 animated:NO completion:nil];
    } else {
        if (!shouldSuppressAODBySystemPolicies()) {
            gCurrentState = AODStateActive;
            setAODStateGlobal(AODStateActive);
            [[%c(SBBacklightController) sharedInstance] setBacklightState:2 source:1 animated:YES completion:nil];
        }
    }
}

%end

// -------------------------------------------------------------
// KHÓA PHÍM VẬT LÝ KHI ĐANG Ở CHẾ ĐỘ AOD
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

static BOOL gPosterBoardInAOD = NO;

static void PosterBoardAODStateActive(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    gPosterBoardInAOD = YES;
}

static void PosterBoardAODStateIdle(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    gPosterBoardInAOD = NO;
}

%hook PRPosterEnvironmentImpl

- (CGFloat)backlightProgress {
    if (isAODMasterEnabled() && gPosterBoardInAOD) {
        if (!isWallpaperEnabled()) return 0.0f;
        return 0.20f;
    }
    return %orig;
}

- (CGFloat)linearBacklightProgress {
    if (isAODMasterEnabled() && gPosterBoardInAOD) {
        if (!isWallpaperEnabled()) return 0.0f;
        return 0.20f;
    }
    return %orig;
}

- (long long)luminance {
    if (isAODMasterEnabled() && gPosterBoardInAOD) {
        if (!isWallpaperEnabled()) return 0;
        return 1;
    }
    return %orig;
}

- (BOOL)isLowLuminance {
    if (isAODMasterEnabled() && gPosterBoardInAOD) {
        return YES;
    }
    return %orig;
}

- (BOOL)isLegibilityBlurEnabled {
    if (isAODMasterEnabled() && isBlurWallpaperEnabled() && gPosterBoardInAOD) {
        return YES;
    }
    return %orig;
}

%end

%hook PRPosterLockPosterAppearance

- (BOOL)isLegibilityBlurEnabled {
    if (isAODMasterEnabled() && isBlurWallpaperEnabled() && gPosterBoardInAOD) {
        return YES;
    }
    return %orig;
}

- (BOOL)allowsModifyingLegibilityBlur {
    return YES;
}

%end

%hook PRPosterConfiguration

- (BOOL)isLegibilityBlurEnabled {
    if (isAODMasterEnabled() && isBlurWallpaperEnabled() && gPosterBoardInAOD) {
        return YES;
    }
    return %orig;
}

%end

%end // Group_PosterBoard


//==============================================================
// 5. TẦNG PREFERENCES: CHUẨN GỐC APPLE, KHÔNG CHỮ BẬT/TẮT NGOÀI & BUNG ĐỦ MENU CON
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

// KHỞI TẠO CLASS TRANG CON BẰNG %subclass ĐỂ TỰ ĐĂNG KÝ BẢNG RUNTIME CHO PREFERENCES
%subclass AODRealPreferencesController : PSListController

- (id)specifiers {
    NSMutableArray *specs = [(id)self valueForKey:@"_specifiers"];
    if (specs && specs.count > 0) return specs;

    specs = [NSMutableArray array];

    // Khối Header
    PSSpecifier *headerGroup = [%c(PSSpecifier) preferenceSpecifierNamed:nil target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
    [headerGroup setProperty:@"Màn hình Luôn bật làm mờ Màn hình khóa trong khi vẫn giữ hiển thị thông tin như thời gian, tiện ích và thông báo bằng cách sử dụng nguồn điện tối thiểu.\n\nMàn hình sẽ tự động tắt để tiết kiệm pin khi không sử dụng." forKey:@"footerText"];
    [specs addObject:headerGroup];

    Boolean valid = false;
    Boolean masterVal = CFPreferencesGetAppBooleanValue(CFSTR("AlwaysOnDisplayEnabled"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) masterVal = CFPreferencesGetAppBooleanValue(CFSTR("enabled"), CFSTR("com.jb.aodreal"), &valid);
    BOOL isMasterOn = valid ? (BOOL)masterVal : YES;

    // Khối Tùy chỉnh (Hình nền, Làm mờ, Thông báo)
    if (isMasterOn) {
        PSSpecifier *customGroup = [%c(PSSpecifier) preferenceSpecifierNamed:@"TÙY CHỈNH" target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
        [specs addObject:customGroup];

        PSSpecifier *wpSwitch = [%c(PSSpecifier) preferenceSpecifierNamed:@"Hiển thị hình nền" target:self set:@selector(setPrefValue:specifier:) get:@selector(getPrefValue:) detail:Nil cell:6 edit:Nil];
        [wpSwitch setProperty:@"ShowWallpaperInAlwaysOn" forKey:@"key"];
        [specs addObject:wpSwitch];

        PSSpecifier *blurSwitch = [%c(PSSpecifier) preferenceSpecifierNamed:@"Làm mờ ảnh hình nền" target:self set:@selector(setPrefValue:specifier:) get:@selector(getPrefValue:) detail:Nil cell:6 edit:Nil];
        [blurSwitch setProperty:@"BlurWallpaperInAlwaysOn" forKey:@"key"];
        [specs addObject:blurSwitch];

        PSSpecifier *notifSwitch = [%c(PSSpecifier) preferenceSpecifierNamed:@"Hiển thị thông báo" target:self set:@selector(setPrefValue:specifier:) get:@selector(getPrefValue:) detail:Nil cell:6 edit:Nil];
        [notifSwitch setProperty:@"ShowNotificationsInAlwaysOn" forKey:@"key"];
        [specs addObject:notifSwitch];
    }

    // Khối Switch chính
    PSSpecifier *masterGroup = [%c(PSSpecifier) preferenceSpecifierNamed:nil target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
    [masterGroup setProperty:@"Khi tắt Màn hình Luôn bật, màn hình sẽ tắt hoàn toàn khi iPhone bị khóa." forKey:@"footerText"];
    [specs addObject:masterGroup];

    PSSpecifier *masterSwitch = [%c(PSSpecifier) preferenceSpecifierNamed:@"Màn hình Luôn bật" target:self set:@selector(setPrefValue:specifier:) get:@selector(getPrefValue:) detail:Nil cell:6 edit:Nil];
    [masterSwitch setProperty:@"AlwaysOnDisplayEnabled" forKey:@"key"];
    [specs addObject:masterSwitch];

    // Khối Tần số quét và Độ sáng
    if (isMasterOn) {
        PSSpecifier *hzGroup = [%c(PSSpecifier) preferenceSpecifierNamed:@"TẦN SỐ QUÉT TĨNH (1 - 5 HZ)" target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
        float curHz = getCustomAODRefreshRate();
        [hzGroup setProperty:[NSString stringWithFormat:@"Hiện tại: %.0f Hz (Tần số quét màn hình khi hiển thị AOD tĩnh)", curHz] forKey:@"footerText"];
        [hzGroup setProperty:@"AOD_HZ_GROUP_ID" forKey:@"id"];
        [specs addObject:hzGroup];

        PSSpecifier *hzSlider = [%c(PSSpecifier) preferenceSpecifierNamed:nil target:self set:@selector(setCustomHz:specifier:) get:@selector(getCustomHz:) detail:Nil cell:5 edit:Nil];
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

        PSSpecifier *brightSlider = [%c(PSSpecifier) preferenceSpecifierNamed:nil target:self set:@selector(setCustomBrightness:specifier:) get:@selector(getCustomBrightness:) detail:Nil cell:5 edit:Nil];
        [brightSlider setProperty:@"PSSliderTableCell" forKey:@"cellClass"];
        [brightSlider setProperty:@"CustomAODBrightness" forKey:@"key"];
        [brightSlider setProperty:@"AOD_CUSTOM_BRIGHTNESS_KEY" forKey:@"id"];
        [brightSlider setProperty:@5.0f forKey:@"min"];
        [brightSlider setProperty:@50.0f forKey:@"max"];
        [brightSlider setProperty:@YES forKey:@"showValue"];
        [specs addObject:brightSlider];
    }

    [(id)self setValue:specs forKey:@"_specifiers"];
    return specs;
}

%new
- (id)getPrefValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)key, CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) val = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)key, CFSTR("com.jb.aodreal"), &valid);
    return @(valid ? (BOOL)val : YES);
}

%new
- (void)setPrefValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
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
    [(id)self reloadSpecifiers];
}

%new
- (id)getCustomHz:(PSSpecifier *)specifier {
    return @(getCustomAODRefreshRate());
}

%new
- (void)setCustomHz:(id)value specifier:(PSSpecifier *)spec {
    float roundedHz = roundf([value floatValue]);
    if (roundedHz < 1.0f) roundedHz = 1.0f;
    if (roundedHz > 5.0f) roundedHz = 5.0f;

    gCachedCustomHz = roundedHz;
    CFPreferencesSetAppValue(CFSTR("CustomAODRefreshRate"), (__bridge CFPropertyListRef)(@(roundedHz)), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);

    for (PSSpecifier *s in [(id)self specifiers]) {
        if ([[s propertyForKey:@"id"] isEqualToString:@"AOD_HZ_GROUP_ID"]) {
            [s setProperty:[NSString stringWithFormat:@"Hiện tại: %.0f Hz (Tần số quét màn hình khi hiển thị AOD tĩnh)", roundedHz] forKey:@"footerText"];
            break;
        }
    }
}

%new
- (id)getCustomBrightness:(PSSpecifier *)spec {
    return @(getCustomAODBrightnessFactor() * 1000.0f);
}

%new
- (void)setCustomBrightness:(id)value specifier:(PSSpecifier *)spec {
    float b = [value floatValue];
    if (b < 5.0f) b = 5.0f;
    if (b > 50.0f) b = 50.0f;

    gCachedBrightnessFactor = b / 1000.0f;
    CFPreferencesSetAppValue(CFSTR("CustomAODBrightness"), (__bridge CFPropertyListRef)(@(b)), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);

    for (PSSpecifier *s in [(id)self specifiers]) {
        if ([[s propertyForKey:@"id"] isEqualToString:@"AOD_BRIGHTNESS_GROUP_ID"]) {
            [s setProperty:[NSString stringWithFormat:@"Mức sáng: %.1f (Kéo thanh trượt để tinh chỉnh độ sáng đèn nền vừa mắt)", b] forKey:@"footerText"];
            break;
        }
    }
}

%end

%group Group_Preferences

%hook BLSBacklight
+ (BOOL)isAlwaysOnEnabledByHardware { return YES; }
+ (BOOL)isAlwaysOnEnabled { return YES; }
%end

%hook BLSAlwaysOnFrequencyConfiguration
- (BOOL)isAlwaysOnEnabled { return YES; }
%end

%hook CBDisplayModule
+ (BOOL)isAlwaysOnDisplaySupported { return YES; }
%end

// HOOK VÀO TRANG MÀN HÌNH ĐỂ TỰ ĐỘNG CHÈN LINK CELL DẪN VÀO TRANG CON
%hook PSListController

- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target bundle:(NSBundle *)bundle {
    NSMutableArray *specs = %orig(name, target, bundle);

    if ([name isEqualToString:@"Display"] || 
        [bundle.bundlePath.lowercaseString containsString:@"display.bundle"] || 
        [NSStringFromClass([self class]) containsString:@"Display"]) {
        
        static NSString *const kAODRowID = @"ALWAYS_ON_DISPLAY_ROW_ID";
        for (PSSpecifier *s in specs) {
            if ([[s propertyForKey:@"id"] isEqualToString:kAODRowID]) {
                return specs;
            }
        }

        Class detailClass = NSClassFromString(@"AODRealPreferencesController");

        if (detailClass) {
            // GÁN TRỰC TIẾP DETAIL CLASS: TỰ ĐỘNG DỰNG UITABLEVIEW ĐẦY ĐỦ, KHÔNG CẦN ACTION THỦ CÔNG
            PSSpecifier *aodLink = [%c(PSSpecifier) preferenceSpecifierNamed:@"Màn hình Luôn bật"
                                                                      target:self 
                                                                         set:NULL 
                                                                         get:NULL 
                                                                      detail:detailClass 
                                                                        cell:2 // PSLinkCell
                                                                        edit:Nil];
            [aodLink setProperty:kAODRowID forKey:@"id"];
            [aodLink setProperty:detailClass forKey:@"detail"];
            [aodLink setProperty:@YES forKey:@"isController"];
            [aodLink setProperty:@YES forKey:@"enabled"];

            // Tìm vị trí hàng "Đưa lên để bật"
            NSInteger rtwIndex = -1;
            for (NSInteger i = 0; i < (NSInteger)specs.count; i++) {
                PSSpecifier *cur = [specs objectAtIndex:i];
                NSString *sid = [[cur propertyForKey:@"id"] description].uppercaseString;
                if ([sid containsString:@"RAISE_TO_WAKE"] || [sid containsString:@"WAKE"]) {
                    rtwIndex = i;
                    break;
                }
            }

            // Chèn ngay sau "Đưa lên để bật" để nằm chung một khối
            if (rtwIndex >= 0) {
                [specs insertObject:aodLink atIndex:rtwIndex + 1];

                // Cập nhật dòng chữ footer chuẩn Apple
                for (NSInteger j = rtwIndex; j >= 0; j--) {
                    PSSpecifier *s = [specs objectAtIndex:j];
                    id cellVal = [s propertyForKey:@"cell"];
                    if ([cellVal respondsToSelector:@selector(intValue)] && [cellVal intValue] == 0) {
                        [s setProperty:@"Màn hình Luôn bật làm mờ Màn hình khóa trong khi vẫn giữ hiển thị thông tin như thời gian, tiện ích và thông báo bằng cách sử dụng nguồn điện tối thiểu." forKey:@"footerText"];
                        break;
                    }
                }
            } else {
                [specs addObject:aodLink];
            }
        }
    }

    return specs;
}

- (NSMutableArray *)specifiers {
    NSMutableArray *specs = %orig;

    if ([NSStringFromClass([self class]) containsString:@"Display"]) {
        static NSString *const kAODRowID = @"ALWAYS_ON_DISPLAY_ROW_ID";

        BOOL exists = NO;
        for (PSSpecifier *s in specs) {
            if ([[s propertyForKey:@"id"] isEqualToString:kAODRowID]) {
                exists = YES;
                break;
            }
        }

        if (!exists && specs) {
            Class detailClass = NSClassFromString(@"AODRealPreferencesController");
            if (detailClass) {
                NSMutableArray *mSpecs = [specs mutableCopy];
                PSSpecifier *aodLink = [%c(PSSpecifier) preferenceSpecifierNamed:@"Màn hình Luôn bật"
                                                                          target:self 
                                                                             set:NULL 
                                                                             get:NULL 
                                                                          detail:detailClass 
                                                                            cell:2 
                                                                            edit:Nil];
                [aodLink setProperty:kAODRowID forKey:@"id"];
                [aodLink setProperty:detailClass forKey:@"detail"];
                [aodLink setProperty:@YES forKey:@"isController"];
                [aodLink setProperty:@YES forKey:@"enabled"];

                NSInteger rtwIndex = -1;
                for (NSInteger i = 0; i < (NSInteger)mSpecs.count; i++) {
                    NSString *sid = [[[mSpecs objectAtIndex:i] propertyForKey:@"id"] description].uppercaseString;
                    if ([sid containsString:@"RAISE_TO_WAKE"] || [sid containsString:@"WAKE"]) {
                        rtwIndex = i;
                        break;
                    }
                }

                if (rtwIndex >= 0) {
                    [mSpecs insertObject:aodLink atIndex:rtwIndex + 1];

                    for (NSInteger j = rtwIndex; j >= 0; j--) {
                        PSSpecifier *s = [mSpecs objectAtIndex:j];
                        id cellVal = [s propertyForKey:@"cell"];
                        if ([cellVal respondsToSelector:@selector(intValue)] && [cellVal intValue] == 0) {
                            [s setProperty:@"Màn hình Luôn bật làm mờ Màn hình khóa trong khi vẫn giữ hiển thị thông tin như thời gian, tiện ích và thông báo bằng cách sử dụng nguồn điện tối thiểu." forKey:@"footerText"];
                            break;
                        }
                    }
                } else {
                    [mSpecs addObject:aodLink];
                }

                [self setValue:mSpecs forKey:@"_specifiers"];
                return mSpecs;
            }
        }
    }

    return specs;
}

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

        if ([bundleID isEqualToString:@"com.apple.springboard"] || 
            [processName isEqualToString:@"SpringBoard"] || 
            [processName.lowercaseString isEqualToString:@"springboard"]) {
            
            gIsSpringBoardProcess = YES;
            gCurrentState = AODStateIdle;
            %init(Group_SpringBoard);
            
        } else if ([bundleID isEqualToString:@"com.apple.PosterBoard"] || 
                   [processName.lowercaseString containsString:@"posterboard"]) {
            
            // Đăng ký nhận thông báo IPC từ SpringBoard để PosterBoard làm tối nền chính xác
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL,
                (CFNotificationCallback)PosterBoardAODStateActive,
                CFSTR("com.jb.aodreal/state.active"),
                NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately
            );

            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL,
                (CFNotificationCallback)PosterBoardAODStateIdle,
                CFSTR("com.jb.aodreal/state.idle"),
                NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately
            );

            %init(Group_PosterBoard);
            
        } else if ([processName isEqualToString:@"backboardd"]) {
            
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL,
                (CFNotificationCallback)BackboarddAODStateActive,
                CFSTR("com.jb.aodreal/state.active"),
                NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately
            );

            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL,
                (CFNotificationCallback)BackboarddAODStateIdle,
                CFSTR("com.jb.aodreal/state.idle"),
                NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately
            );

            %init(Group_Backboardd);
            
        } else if ([bundleID isEqualToString:@"com.apple.Preferences"] || 
                   [processName.lowercaseString containsString:@"preferences"]) {
            
            // 1. Hook MobileGestalt
            void *gestaltHandle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
            if (gestaltHandle) {
                void *mgFunc = dlsym(gestaltHandle, "MGGetBoolAnswer");
                if (mgFunc) {
                    MSHookFunction(mgFunc, (void *)replaced_MGGetBoolAnswer, (void **)&orig_MGGetBoolAnswer);
                }
            }

            // 2. Ép nạp thẳng các bundle gốc của Apple
            [[NSBundle bundleWithPath:@"/System/Library/PreferenceBundles/Display.bundle"] load];
            dlopen("/System/Library/PreferenceBundles/Display.bundle/Display", RTLD_NOW | RTLD_GLOBAL);
            dlopen("/System/Library/PrivateFrameworks/DisplayAndBrightnessSettings.framework/DisplayAndBrightnessSettings", RTLD_NOW | RTLD_GLOBAL);
            dlopen("/System/Library/PrivateFrameworks/Settings/DisplayAndBrightnessSettings.framework/DisplayAndBrightnessSettings", RTLD_NOW | RTLD_GLOBAL);

            // 3. Khởi tạo Group_Preferences (Theos tự quản lý đăng ký runtime cho %subclass AODRealPreferencesController)
            %init(Group_Preferences);
        }
    }
}
