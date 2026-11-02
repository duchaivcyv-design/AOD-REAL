#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAFrameRateRange.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>

//==============================================================
// 0. BỘ ĐIỀU PHỐI TRẠNG THÁI & ĐỌC CÀI ĐẶT CHUẨN XÁC
//==============================================================

typedef NS_ENUM(NSInteger, AODState) {
    AODStateIdle = 0,       // Màn hình sáng bình thường / Đang dùng
    AODStateTransitioning,  // Đang chạy animation lặn dần vào AOD (0.45s)
    AODStateActive,        // Đang hiển thị AOD tĩnh
    AODStateProximityOff   // Đang đút túi / Úp màn hình (Tắt đèn nền về 0)
};

static AODState gCurrentState = AODStateIdle;
static CGFloat gCurrentAODProgress = 1.0f;
static NSInteger gBurnInShiftStep = 0;
static id gInjectedSessionProvider = nil;

// 1. Công tắc tổng Always On Display ở trên cùng
static inline BOOL isTopAODMasterEnabled(void) {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(CFSTR("AlwaysOnDisplayEnabled"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) {
        val = CFPreferencesGetAppBooleanValue(CFSTR("enabled"), CFSTR("com.apple.BacklightServices"), &valid);
    }
    if (!valid) {
        val = CFPreferencesGetAppBooleanValue(CFSTR("AlwaysOnDisplayEnabled"), CFSTR("com.jb.aodreal"), &valid);
    }
    return valid ? (BOOL)val : YES;
}

// 2. Nhóm Customize: Show Wallpaper
static inline BOOL isWallpaperEnabled(void) {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(CFSTR("ShowWallpaperInAlwaysOn"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) {
        val = CFPreferencesGetAppBooleanValue(CFSTR("ShowWallpaperInAlwaysOn"), CFSTR("com.jb.aodreal"), &valid);
    }
    return valid ? (BOOL)val : YES;
}

// 3. Nhóm Customize: Blur Wallpaper Photo
static inline BOOL isBlurWallpaperEnabled(void) {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(CFSTR("BlurWallpaperInAlwaysOn"), CFSTR("com.jb.aodreal"), &valid);
    return valid ? (BOOL)val : NO;
}

// 4. Nhóm Customize: Show Notifications
static inline BOOL isNotificationsEnabled(void) {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(CFSTR("ShowNotificationsInAlwaysOn"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) {
        val = CFPreferencesGetAppBooleanValue(CFSTR("ShowNotificationsInAlwaysOn"), CFSTR("com.jb.aodreal"), &valid);
    }
    return valid ? (BOOL)val : YES;
}

// 5. Công tắc Always On Display ở nhóm dưới cùng
static inline BOOL isBottomAODEnabled(void) {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(CFSTR("BottomAlwaysOnEnabled"), CFSTR("com.jb.aodreal"), &valid);
    return valid ? (BOOL)val : YES;
}

// Kiểm tra toàn cục: Khi cả 2 công tắc AOD đều cho phép chạy
static inline BOOL isAODFullyActive(void) {
    return isTopAODMasterEnabled() && isBottomAODEnabled();
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

static inline float getAODPanelBrightnessFactor(void) {
    CFPropertyListRef val = CFPreferencesCopyAppValue(CFSTR("CustomAODBrightness"), CFSTR("com.jb.aodreal"));
    if (val && CFGetTypeID(val) == CFNumberGetTypeID()) {
        float level = [(__bridge NSNumber *)val floatValue];
        CFRelease(val);
        if (level >= 1.0f && level <= 30.0f) return level / 1000.0f;
    }
    if (val) CFRelease(val);
    return 0.08f; // Đảm bảo đồng hồ, widget sáng rực rỡ, không bị chìm tối
}

//==============================================================
// 1. KHAI BÁO CÁC LỚP VÀ GIAO DIỆN HỆ THỐNG
//==============================================================

@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)title target:(id)target set:(SEL)set get:(SEL)get detail:(Class)detail cell:(long long)cell edit:(Class)edit;
+ (instancetype)groupSpecifierWithName:(NSString *)title;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end

@interface PSListController : UIViewController
- (NSMutableArray *)specifiers;
- (void)insertSpecifier:(PSSpecifier *)specifier atIndex:(NSInteger)index animated:(BOOL)animated;
- (void)addSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
- (void)reloadSpecifiers;
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
- (void)_updateWallpaperEffectView;
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
- (void)updateTimeNow;
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
    if (isAODFullyActive() && !state && gCurrentState != AODStateProximityOff) {
        %orig(YES, completion); // Bảo toàn nguồn đèn nền panel
        return;
    }
    %orig(state, completion);
}
%end

%hook CAWindowServerDisplay
- (BOOL)blankingRemovesPower {
    if (isAODFullyActive() && gCurrentState != AODStateProximityOff) {
        return NO;
    }
    return %orig;
}

- (void)setBlankingRemovesPower:(BOOL)val {
    if (isAODFullyActive() && gCurrentState != AODStateProximityOff) {
        %orig(NO);
        return;
    }
    %orig(val);
}

- (BOOL)disabled {
    if (isAODFullyActive() && gCurrentState != AODStateProximityOff && gCurrentState != AODStateIdle) {
        return NO;
    }
    return %orig;
}

- (void)setDisabled:(BOOL)val {
    if (isAODFullyActive() && val && gCurrentState != AODStateProximityOff) {
        %orig(NO);
        return;
    }
    %orig(val);
}

- (BOOL)isBlanked {
    if (isAODFullyActive() && gCurrentState != AODStateProximityOff && gCurrentState != AODStateIdle) {
        return NO;
    }
    return %orig;
}

- (void)setBlanked:(BOOL)blanked {
    if (isAODFullyActive() && blanked && gCurrentState != AODStateProximityOff) {
        %orig(NO);
        return;
    }
    %orig(blanked);
}

- (BOOL)disablesUpdates {
    if (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return NO;
    }
    return %orig;
}

- (void)setDisablesUpdates:(BOOL)val {
    if (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        %orig(NO);
        return;
    }
    %orig(val);
}

- (BOOL)isFlipBookActive {
    if (isAODFullyActive() && gCurrentState != AODStateIdle && gCurrentState != AODStateProximityOff) {
        return YES;
    }
    return %orig;
}

- (BOOL)isFlipBookEnabled { return isAODFullyActive() ? YES : %orig; }
- (void)setFlipBookEnabled:(BOOL)val { %orig(isAODFullyActive() ? YES : val); }

- (BOOL)isFlipBookSuppressed {
    if (isAODFullyActive() && gCurrentState != AODStateProximityOff) {
        return NO;
    }
    return %orig;
}

- (void)setFlipBookSuppressed:(BOOL)suppressed {
    if (isAODFullyActive() && gCurrentState != AODStateProximityOff && suppressed) {
        %orig(NO);
        return;
    }
    %orig(suppressed);
}

- (void)powerStateDidChange:(id)arg1 {
    if (isAODFullyActive() && gCurrentState != AODStateIdle && gCurrentState != AODStateProximityOff) {
        return;
    }
    %orig(arg1);
}
%end

%hook BKDisplayRenderOverlay
- (BOOL)disablesDisplayBlanking { return isAODFullyActive() ? YES : %orig; }
%end

%hook BKDisplayManager
- (void)setBlanked:(BOOL)blanked withReason:(id)reason {
    if (isAODFullyActive() && blanked) {
        if (gCurrentState != AODStateProximityOff) {
            %orig(NO, reason);
            return;
        }
    }
    %orig(blanked, reason);
}
%end

%hook BLSHBacklightStateMachine
- (BOOL)isAlwaysOnEnabled { return isAODFullyActive() ? YES : %orig; }

- (BOOL)isAlwaysOnSuppressed {
    if (isAODFullyActive()) {
        return (gCurrentState == AODStateProximityOff) ? YES : NO;
    }
    return %orig;
}

- (BOOL)isAlwaysOnDisabledByAssertion { return %orig; }

- (long long)backlightState {
    long long state = %orig;
    if (isAODFullyActive() && state == 0) {
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
- (BOOL)isAlwaysOnEnabled { return isAODFullyActive() ? YES : %orig; }
- (BOOL)isAlwaysOnSuppressed {
    if (isAODFullyActive()) {
        return (gCurrentState == AODStateProximityOff) ? YES : NO;
    }
    return %orig;
}
%end

%hook BLSHXPCBacklightProxyHost
- (BOOL)isAlwaysOnEnabled { return isAODFullyActive() ? YES : %orig; }
%end

%hook BLSHFlipbookSpecification
- (double)framesPerSecond {
    if (isAODFullyActive()) return (double)getCustomAODRefreshRate();
    return %orig;
}
%end

%hook BLSHAlwaysOnPresentationEngine
- (BOOL)isSuppressed {
    if (isAODFullyActive()) return (gCurrentState == AODStateProximityOff) ? YES : %orig;
    return %orig;
}

- (void)setSuppressed:(BOOL)suppressed {
    if (isAODFullyActive() && gCurrentState != AODStateProximityOff && suppressed) {
        %orig(NO);
        return;
    }
    %orig(suppressed);
}

- (BOOL)isUsingPseudoFlipbook { return isAODFullyActive() ? YES : %orig; }
- (BOOL)alwaysFillFlipbook { return isAODFullyActive() ? YES : %orig; }

- (void)startLiveUpdates {
    %orig;
    if (isAODFullyActive()) {
        @try {
            [self startFlipbookAndEnsureCurrent];
        } @catch (NSException *e) {}
    }
}
%end

%hook BLSHBacklightSceneHostEnvironment
- (BOOL)supportsAlwaysOn { return isAODFullyActive() ? YES : %orig; }
- (BOOL)isAlwaysOnActive { return (isAODFullyActive() && gCurrentState != AODStateProximityOff) ? YES : %orig; }
- (BOOL)isClientActive { return isAODFullyActive() ? YES : %orig; }
- (long long)visualState {
    long long state = %orig;
    if (isAODFullyActive() && state == 0 && gCurrentState != AODStateProximityOff) return 2;
    return state;
}
%end

%end // Group_Backboardd

//==============================================================
// 3. TẦNG SPRINGBOARD: KHOÁ ĐỘ TƯƠNG PHẢN ĐỒNG HỒ & CÔNG TẮC
//==============================================================

%group Group_SpringBoard

static CSCoverSheetViewController *gCoverSheetVC = nil;
static CSCombinedListViewController *gCombinedListVC = nil;
static id gCachedFlipbookSpec = nil;

%hook CSCoverSheetViewController
- (void)viewDidLoad {
    %orig;
    gCoverSheetVC = self;
}

- (BOOL)isAlwaysOnPresentation { 
    return (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) ? YES : %orig; 
}

- (BOOL)shouldDimForAlwaysOn { 
    return (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) ? YES : %orig; 
}

- (BOOL)coverSheetIsObscured {
    if (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) return NO;
    return %orig;
}

- (long long)backlightLuminance {
    if (isAODFullyActive()) {
        if (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning) return 1;
    }
    return %orig;
}

// CÔNG TẮC GỐC SHOW WALLPAPER: Gạt tắt là ĐEN TUYỀN 100%
- (void)_updateWallpaperEffectView {
    %orig;
    if (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        UIView *floatingLayer = nil;
        UIView *effectView = nil;
        @try {
            floatingLayer = [self valueForKey:@"_wallpaperFloatingLayerContainerView"];
            effectView = [self valueForKey:@"_wallpaperEffectView"];
        } @catch (NSException *e) {}
        
        if (!isWallpaperEnabled()) {
            // TẮT HÌNH NỀN: Nền đen tuyệt đối, triệt tiêu toàn bộ ảnh
            if (floatingLayer) floatingLayer.alpha = 0.0f;
            if (effectView) {
                effectView.backgroundColor = [UIColor blackColor];
                effectView.alpha = 1.0f;
            }
            self.view.backgroundColor = [UIColor blackColor];
        } else {
            // HIỆN HÌNH NỀN:
            if (floatingLayer) floatingLayer.alpha = 1.0f;
            if (effectView) {
                if (isBlurWallpaperEnabled()) {
                    effectView.alpha = 0.85f; // Làm mờ hình nền
                } else {
                    effectView.backgroundColor = [UIColor clearColor];
                    effectView.alpha = 0.0f; // Nền trong tự nhiên
                }
            }
        }
    }
}

- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession {
    NSArray *entries = %orig;
    if (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
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

// CÔNG TẮC GỐC SHOW NOTIFICATIONS: Gạt tắt là ẨN SẠCH THÔNG BÁO
%hook CSCombinedListViewController
- (void)viewDidLoad {
    %orig;
    gCombinedListVC = self;
}

- (BOOL)showNotificationsInAlwaysOn {
    if (isAODFullyActive()) {
        return isNotificationsEnabled();
    }
    return %orig;
}

- (void)setShowNotificationsInAlwaysOn:(BOOL)show {
    if (isAODFullyActive()) {
        show = isNotificationsEnabled();
    }
    %orig(show);
}

- (void)_setNotificationListHidden:(BOOL)hidden forReason:(id)reason {
    if (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        if (!isNotificationsEnabled()) {
            %orig(YES, @"AODPreferencesSuppression");
            self.view.alpha = 0.0f;
            return;
        }
    }
    %orig(hidden, reason);
    if (isNotificationsEnabled()) {
        self.view.alpha = 1.0f;
    }
}

- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession {
    if (isAODFullyActive() && !isNotificationsEnabled()) return @[];
    return %orig;
}
%end

%hook CSBackgroundContentViewController
- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession {
    if (isAODFullyActive() && !isWallpaperEnabled()) return @[];
    return %orig;
}
%end

%hook CSComplicationContainerViewController
- (NSArray *)sceneHostEnvironmentEntriesForBacklightSession {
    return %orig;
}

- (id)vibrancyConfiguration {
    id orig = %orig;
    if (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        // Giữ Widget sáng rõ, không bị mờ đục
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

// ĐỒNG HỒ & WIDGET SÁNG RỰC RỠ: Không bị dìm tối theo hình nền
%hook SBFLockScreenDateView
- (id)vibrancyConfiguration {
    id orig = %orig;
    if (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        // Cưỡng chế giữ độ tương phản cao và độ chói tối đa cho số đồng hồ & ngày tháng
        if (orig && [orig respondsToSelector:@selector(copyWithLuminanceReduced:)]) {
            return [orig performSelector:@selector(copyWithLuminanceReduced:) withObject:@(NO)];
        }
    }
    return orig;
}

- (_UILegibilitySettings *)legibilitySettings {
    _UILegibilitySettings *orig = %orig;
    if (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        // Trả về Legibility phong cách sáng trắng tương phản cao (High Contrast White)
        return [%c(_UILegibilitySettings) sharedInstanceForStyle:1];
    }
    return orig;
}
%end

%hook SBFLockScreenDateViewController
- (_UILegibilitySettings *)legibilitySettings {
    if (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return [%c(_UILegibilitySettings) sharedInstanceForStyle:1];
    }
    return %orig;
}
%end

%hook SBLockScreenViewControllerBase
- (void)setBacklightLevel:(float)level {
    if (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        %orig(getAODPanelBrightnessFactor() * 100.0f);
        return;
    }
    %orig(level);
}
%end

%hook SBDashBoardLockScreenEnvironment
- (void)setBacklightLevel:(float)level {
    if (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        %orig(getAODPanelBrightnessFactor() * 100.0f);
        return;
    }
    %orig(level);
}
%end

%hook UIApplication
- (void)setBacklightLevel:(float)level {
    if (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        %orig(getAODPanelBrightnessFactor() * 100.0f);
        return;
    }
    %orig(level);
}
%end

// ĐIỀU PHỐI ĐỘ SÁNG THỰC TẾ & CHUYỂN CẢNH MƯỢT MÀ
%hook SBBacklightController
- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion {
    if (isAODFullyActive() && state == 0) {
        if (gCurrentState != AODStateProximityOff) {
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
    if (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return getAODPanelBrightnessFactor(); // Đảm bảo mức sáng đủ nuôi đồng hồ
    }
    return %orig(state);
}

- (void)animateBacklightToFactor:(float)factor duration:(double)duration source:(long long)source completion:(id)completion {
    if (isAODFullyActive()) {
        if (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning) {
            if (factor <= 0.05f) {
                factor = getAODPanelBrightnessFactor();
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
- (BOOL)supportsAlwaysOn { return isAODFullyActive() ? YES : %orig; }

- (BOOL)isDisplayBlanked {
    if (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) return NO;
    return %orig;
}

- (long long)visualState {
    if (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) return 2;
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

- (BOOL)deviceSupportsAlwaysOn { return isAODFullyActive() ? YES : %orig; }
- (BOOL)isAlwaysOnEnabled { return isAODFullyActive() ? YES : %orig; }

- (id)flipbookSpecification {
    id orig = %orig;
    if (orig) return orig;
    
    if (isAODFullyActive()) {
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
                        double fps = 10.0; // Render ổn định, không giật lag
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
    if (isAODFullyActive()) {
        if (gInjectedSessionProvider) return gInjectedSessionProvider;
        Class providerClass = NSClassFromString(@"SBBacklightEnvironmentSessionProvider");
        if (providerClass && [providerClass respondsToSelector:@selector(sharedInstance)]) {
            return [providerClass performSelector:@selector(sharedInstance)];
        }
    }
    return orig;
}

- (BOOL)isShowingBlankingWindow {
    if (isAODFullyActive() && gCurrentState != AODStateProximityOff) return NO;
    return %orig;
}

- (void)showBlankingWindow:(BOOL)show withFadeDuration:(double)duration {
    if (isAODFullyActive() && show && gCurrentState != AODStateProximityOff) return;
    %orig(show, duration);
}

- (void)_setBlankingWindowVisible:(BOOL)visible fadeDuration:(double)duration {
    if (isAODFullyActive() && visible && gCurrentState != AODStateProximityOff) return;
    %orig(visible, duration);
}

- (BOOL)isUsingAlwaysOnBrightnessCurve {
    if (isAODFullyActive() && gCurrentState != AODStateProximityOff) return YES;
    return %orig;
}
%end

%hook SBLockScreenManager
- (BOOL)shouldPreventBacklightBlankingForAlwaysOn { 
    return (isAODFullyActive() && gCurrentState != AODStateProximityOff) ? YES : %orig; 
}

- (void)lockUIFromSource:(int)source withOptions:(id)options {
    if (isAODFullyActive()) {
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
- (BOOL)isTapToWakeSupported { return isAODFullyActive() ? YES : %orig; }
- (BOOL)shouldTapToWake { return isAODFullyActive() ? YES : %orig; }

- (void)tapToWakeDidRecognize:(id)arg1 {
    if (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        [[%c(SBLockScreenManager) sharedInstance] _wakeScreenForTapToWake];
    }
    %orig(arg1);
}
%end

// CẢM BIẾN TIỆM CẬN: Đút túi/úp mặt thì dập tắt hẳn (0.0), nhấc ra thì tự bật lại
%hook SBProximitySensorManager
- (void)_setObjectInProximity:(BOOL)inProximity detectionMode:(int)mode {
    %orig(inProximity, mode);
    if (!isAODFullyActive() || gCurrentState == AODStateIdle) return;
    
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
    if (isAODFullyActive() && gCurrentState == AODStateActive) {
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
// 4. TẦNG POSTERBOARD: LÀM TỐI HÌNH NỀN ĐỘC LẬP
//==============================================================

%group Group_PosterBoard

%hook PRPosterEnvironmentImpl
- (CGFloat)backlightProgress {
    if (isAODFullyActive()) {
        if (!isWallpaperEnabled()) return 0.0f; // Tắt hình nền
        if (gCurrentState == AODStateActive) return 0.0f;
        if (gCurrentState == AODStateTransitioning) return gCurrentAODProgress;
    }
    return %orig;
}

- (CGFloat)linearBacklightProgress {
    if (isAODFullyActive()) {
        if (!isWallpaperEnabled()) return 0.0f;
        if (gCurrentState == AODStateActive) return 0.0f;
        if (gCurrentState == AODStateTransitioning) return gCurrentAODProgress;
    }
    return %orig;
}

- (long long)luminance {
    if (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return 1;
    }
    return %orig;
}

- (BOOL)isLowLuminance {
    if (isAODFullyActive() && (gCurrentState == AODStateActive || gCurrentState == AODStateTransitioning)) {
        return YES;
    }
    return %orig;
}
%end

%end // Group_PosterBoard

//==============================================================
// 5. TẦNG PREFERENCES: CHUẨN XÁC 5 CÔNG TẮC THEO VIDEO MẪU
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

// XÂY DỰNG LẠI DANH SÁCH ĐÚNG CHUẨN 5 CÔNG TẮC THEO VIDEO MẪU
%hook DBSAlwaysOnViewController

- (NSMutableArray *)specifiers {
    NSMutableArray *specs = [NSMutableArray array];

    // --- NHÓM 1: CÔNG TẮC TỔNG ALWAYS ON DISPLAY ---
    PSSpecifier *topGroup = [%c(PSSpecifier) groupSpecifierWithName:@""];
    [topGroup setProperty:@"Always On Display dims the Lock Screen while keeping information like the time, widgets, and notifications visible." forKey:@"footerText"];
    [specs addObject:topGroup];

    PSSpecifier *topAOD = [%c(PSSpecifier) preferenceSpecifierNamed:@"Always On Display"
                                                             target:self
                                                                set:@selector(setTopAOD:spec:)
                                                                get:@selector(getTopAOD:)
                                                             detail:Nil
                                                               cell:6
                                                               edit:Nil];
    [topAOD setProperty:@"TOP_ALWAYS_ON_KEY" forKey:@"id"];
    [specs addObject:topAOD];

    // --- NHÓM 2: CUSTOMIZE (CHỨA ĐỦ 3 CÔNG TẮC THEO VIDEO MẪU) ---
    PSSpecifier *customizeGroup = [%c(PSSpecifier) groupSpecifierWithName:@"Customize"];
    [customizeGroup setProperty:@"The display will turn off automatically to save battery life when not in use." forKey:@"footerText"];
    [specs addObject:customizeGroup];

    // 1. Show Wallpaper
    PSSpecifier *wallpaperSpec = [%c(PSSpecifier) preferenceSpecifierNamed:@"Show Wallpaper"
                                                                    target:self
                                                                       set:@selector(setWallpaperSpec:spec:)
                                                                       get:@selector(getWallpaperSpec:)
                                                                    detail:Nil
                                                                      cell:6
                                                                      edit:Nil];
    [wallpaperSpec setProperty:@"SHOW_WALLPAPER_KEY" forKey:@"id"];
    [specs addObject:wallpaperSpec];

    // 2. Blur Wallpaper Photo
    PSSpecifier *blurSpec = [%c(PSSpecifier) preferenceSpecifierNamed:@"Blur Wallpaper Photo"
                                                               target:self
                                                                  set:@selector(setBlurSpec:spec:)
                                                                  get:@selector(getBlurSpec:)
                                                               detail:Nil
                                                                 cell:6
                                                                 edit:Nil];
    [blurSpec setProperty:@"BLUR_WALLPAPER_KEY" forKey:@"id"];
    [specs addObject:blurSpec];

    // 3. Show Notifications
    PSSpecifier *notiSpec = [%c(PSSpecifier) preferenceSpecifierNamed:@"Show Notifications"
                                                               target:self
                                                                  set:@selector(setNotiSpec:spec:)
                                                                  get:@selector(getNotiSpec:)
                                                               detail:Nil
                                                                 cell:6
                                                                 edit:Nil];
    [notiSpec setProperty:@"SHOW_NOTIFICATIONS_KEY" forKey:@"id"];
    [specs addObject:notiSpec];

    // --- NHÓM 3: CÔNG TẮC DƯỚI CÙNG (ALWAYS ON DISPLAY) ---
    PSSpecifier *bottomGroup = [%c(PSSpecifier) groupSpecifierWithName:@""];
    [bottomGroup setProperty:@"When Always On Display is off, your screen will turn off when iPhone is locked." forKey:@"footerText"];
    [specs addObject:bottomGroup];

    PSSpecifier *bottomAOD = [%c(PSSpecifier) preferenceSpecifierNamed:@"Always On Display"
                                                                target:self
                                                                   set:@selector(setBottomAOD:spec:)
                                                                   get:@selector(getBottomAOD:)
                                                                detail:Nil
                                                                  cell:6
                                                                  edit:Nil];
    [bottomAOD setProperty:@"BOTTOM_ALWAYS_ON_KEY" forKey:@"id"];
    [specs addObject:bottomAOD];

    // --- NHÓM 4: CẤU HÌNH PHẦN CỨNG TẦNG SÂU (GIỮ NGUYÊN KHÔNG CẮT BỎ) ---
    PSSpecifier *hardwareGroup = [%c(PSSpecifier) groupSpecifierWithName:@"CẤU HÌNH PHẦN CỨNG TẦNG SÂU (2-30)"];
    [hardwareGroup setProperty:@"Ép phần cứng hạ xung nhịp và độ sáng xuống mức tối thiểu khi khóa màn hình." forKey:@"footerText"];
    [specs addObject:hardwareGroup];

    PSSpecifier *hzSlider = [%c(PSSpecifier) preferenceSpecifierNamed:@"Tần số quét tĩnh (2-30 Hz)"
                                                               target:self set:@selector(setCustomHz:spec:) get:@selector(getCustomHz:) detail:Nil cell:5 edit:Nil];
    [hzSlider setProperty:@"AOD_CUSTOM_HZ_KEY" forKey:@"id"];
    [hzSlider setProperty:@(2.0f) forKey:@"min"];
    [hzSlider setProperty:@(30.0f) forKey:@"max"];
    [hzSlider setProperty:@YES forKey:@"showValue"];
    [specs addObject:hzSlider];

    PSSpecifier *brightSlider = [%c(PSSpecifier) preferenceSpecifierNamed:@"Độ sáng AOD (Mức 1-30)"
                                                                   target:self set:@selector(setCustomBrightness:spec:) get:@selector(getCustomBrightness:) detail:Nil cell:5 edit:Nil];
    [brightSlider setProperty:@"AOD_CUSTOM_BRIGHTNESS_KEY" forKey:@"id"];
    [brightSlider setProperty:@(1.0f) forKey:@"min"];
    [brightSlider setProperty:@(30.0f) forKey:@"max"];
    [brightSlider setProperty:@YES forKey:@"showValue"];
    [specs addObject:brightSlider];

    return specs;
}

// GETTER & SETTER CHO CÁC CÔNG TẮC & SLIDER

%new
- (void)setTopAOD:(id)value spec:(PSSpecifier *)spec {
    CFPreferencesSetAppValue(CFSTR("AlwaysOnDisplayEnabled"), (__bridge CFPropertyListRef)(value), CFSTR("com.apple.BacklightServices"));
    CFPreferencesSetAppValue(CFSTR("AlwaysOnDisplayEnabled"), (__bridge CFPropertyListRef)(value), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.BacklightServices"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);
}

%new
- (id)getTopAOD:(PSSpecifier *)spec { return @(isTopAODMasterEnabled()); }

%new
- (void)setWallpaperSpec:(id)value spec:(PSSpecifier *)spec {
    CFPreferencesSetAppValue(CFSTR("ShowWallpaperInAlwaysOn"), (__bridge CFPropertyListRef)(value), CFSTR("com.apple.BacklightServices"));
    CFPreferencesSetAppValue(CFSTR("ShowWallpaperInAlwaysOn"), (__bridge CFPropertyListRef)(value), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.BacklightServices"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);
}

%new
- (id)getWallpaperSpec:(PSSpecifier *)spec { return @(isWallpaperEnabled()); }

%new
- (void)setBlurSpec:(id)value spec:(PSSpecifier *)spec {
    CFPreferencesSetAppValue(CFSTR("BlurWallpaperInAlwaysOn"), (__bridge CFPropertyListRef)(value), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);
}

%new
- (id)getBlurSpec:(PSSpecifier *)spec { return @(isBlurWallpaperEnabled()); }

%new
- (void)setNotiSpec:(id)value spec:(PSSpecifier *)spec {
    CFPreferencesSetAppValue(CFSTR("ShowNotificationsInAlwaysOn"), (__bridge CFPropertyListRef)(value), CFSTR("com.apple.BacklightServices"));
    CFPreferencesSetAppValue(CFSTR("ShowNotificationsInAlwaysOn"), (__bridge CFPropertyListRef)(value), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.BacklightServices"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);
}

%new
- (id)getNotiSpec:(PSSpecifier *)spec { return @(isNotificationsEnabled()); }

%new
- (void)setBottomAOD:(id)value spec:(PSSpecifier *)spec {
    CFPreferencesSetAppValue(CFSTR("BottomAlwaysOnEnabled"), (__bridge CFPropertyListRef)(value), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);
}

%new
- (id)getBottomAOD:(PSSpecifier *)spec { return @(isBottomAODEnabled()); }

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
- (id)getCustomBrightness:(PSSpecifier *)spec { return @(getAODPanelBrightnessFactor() * 1000.0f); }

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
