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
// 0. BỘ ĐIỀU PHỐI TRẠNG THÁI & ĐỌC CÀI ĐẶT
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
    if (!valid) masterVal = CFPreferencesGetAppBooleanValue(CFSTR("enabled"), CFSTR("com.jb.aodreal"), &valid);
    gCachedAODEnabled = valid ? (BOOL)masterVal : YES;

    valid = false;
    Boolean wpVal = CFPreferencesGetAppBooleanValue(CFSTR("ShowWallpaperInAlwaysOn"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) wpVal = CFPreferencesGetAppBooleanValue(CFSTR("ShowWallpaperInAlwaysOn"), CFSTR("com.jb.aodreal"), &valid);
    gCachedWallpaperEnabled = valid ? (BOOL)wpVal : YES;

    valid = false;
    Boolean notiVal = CFPreferencesGetAppBooleanValue(CFSTR("ShowNotificationsInAlwaysOn"), CFSTR("com.apple.BacklightServices"), &valid);
    if (!valid) notiVal = CFPreferencesGetAppBooleanValue(CFSTR("ShowNotificationsInAlwaysOn"), CFSTR("com.jb.aodreal"), &valid);
    gCachedNotificationsEnabled = valid ? (BOOL)notiVal : YES;

    CFPropertyListRef hzVal = CFPreferencesCopyAppValue(CFSTR("CustomAODRefreshRate"), CFSTR("com.jb.aodreal"));
    if (hzVal) { if (CFGetTypeID(hzVal) == CFNumberGetTypeID()) { float r = [(__bridge NSNumber *)hzVal floatValue]; if (r >= 1.0f && r <= 5.0f) gCachedCustomHz = r; } CFRelease(hzVal); }
    else gCachedCustomHz = 1.0f;

    CFPropertyListRef brVal = CFPreferencesCopyAppValue(CFSTR("CustomAODBrightness"), CFSTR("com.jb.aodreal"));
    if (brVal) { if (CFGetTypeID(brVal) == CFNumberGetTypeID()) { float b = [(__bridge NSNumber *)brVal floatValue]; if (b >= 0.5f && b <= 20.0f) gCachedBrightnessFactor = b / 1000.0f; } CFRelease(brVal); }
    else gCachedBrightnessFactor = 0.005f;
}

static inline BOOL isAODMasterEnabled(void) { 
    if (gIsSpringBoardProcess && !gSpringBoardDidFinishLaunching) return NO;
    return gCachedAODEnabled; 
}
static inline BOOL isWallpaperEnabled(void) { return gCachedWallpaperEnabled; }
static inline BOOL isNotificationsEnabled(void) { return gCachedNotificationsEnabled; }
static inline float getCustomAODRefreshRate(void) { return gCachedCustomHz; }
static inline float getAODPanelBrightnessFactor(void) { return gCachedBrightnessFactor; }

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
                    if (state && CFStringCompare(state, CFSTR(kIOPSACPowerValue), 0) == kCFCompareEqualTo) { CFRelease(powerSourcesList); CFRelease(powerInfo); return NO; }
                    CFNumberRef curCapNum = (CFNumberRef)CFDictionaryGetValue(desc, CFSTR(kIOPSCurrentCapacityKey));
                    if (curCapNum) { int cur=0; CFNumberGetValue(curCapNum, kCFNumberIntType, &cur); if (cur <= 5) { CFRelease(powerSourcesList); CFRelease(powerInfo); return YES; } }
                }
            }
            CFRelease(powerSourcesList);
        }
        CFRelease(powerInfo);
    }
    return NO;
}

//==============================================================
// 1. KHAI BÁO CÁC LỚP VÀ GIAO DIỆN HỆ THỐNG (BỔ SUNG PAPERBOARD & CLOCKANGEL)
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
@end
@interface DBSAlwaysOnViewController : PSListController
- (id)isAlwaysOnEnabled:(PSSpecifier *)specifier;
- (void)setAlwaysOnDisplayEnabled:(id)value specifier:(PSSpecifier *)specifier;
- (void)setCustomHz:(id)value spec:(PSSpecifier *)spec;
- (id)getCustomHz:(PSSpecifier *)spec;
@end
@interface BLSHFlipbookSpecification : NSObject
- (double)framesPerSecond;
- (double)minimumGapDuration;
@end
@interface SBBacklightPlatformProvider : NSObject
- (id)initWithBacklightEnvironmentSessionProvider:(id)provider;
- (BOOL)deviceSupportsAlwaysOn;
- (BOOL)isAlwaysOnEnabled;
- (id)flipbookSpecification;
- (BOOL)isShowingBlankingWindow;
- (void)showBlankingWindow:(BOOL)show withFadeDuration:(double)duration;
- (void)_setBlankingWindowVisible:(BOOL)visible fadeDuration:(double)duration;
- (BOOL)isUsingAlwaysOnBrightnessCurve;
@end
@interface CAWindowServerDisplay : NSObject
- (void)setRefreshRate:(float)rate; - (float)refreshRate;
- (BOOL)blankingRemovesPower; - (void)setBlankingRemovesPower:(BOOL)val;
- (BOOL)disabled; - (void)setDisabled:(BOOL)val;
- (BOOL)isBlanked; - (void)setBlanked:(BOOL)val;
- (BOOL)disablesUpdates; - (void)setDisablesUpdates:(BOOL)val;
- (BOOL)isFlipBookEnabled; - (void)setFlipBookEnabled:(BOOL)val;
- (BOOL)isFlipBookSuppressed; - (void)setFlipBookSuppressed:(BOOL)val;
@end
@interface CSCoverSheetViewController : UIViewController
- (BOOL)isAlwaysOnPresentation; - (BOOL)shouldDimForAlwaysOn;
- (BOOL)coverSheetIsObscured; - (long long)backlightLuminance;
- (void)setBacklightLevel:(float)level;
- (void)_updateAppearanceForAODTransitionToInactive:(BOOL)inactive;
- (void)_updateWallpaperEffectView;
@end
@interface CSCombinedListViewController : UIViewController
- (BOOL)showNotificationsInAlwaysOn; - (void)setShowNotificationsInAlwaysOn:(BOOL)show;
- (void)_setNotificationListHidden:(BOOL)hidden forReason:(id)reason;
@end
@interface CSBackgroundContentViewController : UIViewController @end
@interface CSComplicationContainerViewController : UIViewController @end
@interface SBFLockScreenDateView : UIView @end
@interface SBFLockScreenDateViewController : UIViewController
- (void)updateTimeNow;
@end
@interface SBLockScreenViewControllerBase : UIViewController @end
@interface SBDashBoardLockScreenEnvironment : NSObject @end
@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)shouldPreventBacklightBlankingForAlwaysOn;
- (void)lockUIFromSource:(int)source withOptions:(id)options;
- (void)unlockUIFromSource:(int)source withOptions:(id)options;
- (void)_wakeScreenForTapToWake;
@end
@interface SBTapToWakeController : NSObject
- (void)tapToWakeDidRecognize:(UITapGestureRecognizer *)gesture;
@end
@interface SBBacklightController : NSObject
+ (instancetype)sharedInstance;
- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion;
- (void)animateBacklightToFactor:(float)factor duration:(double)duration source:(long long)source completion:(id)completion;
- (float)_factorToPublishForBacklightState:(long long)state;
@end
@interface SBProximitySensorManager : NSObject
- (void)_setObjectInProximity:(BOOL)inProximity detectionMode:(int)mode;
@end
@interface BLSHBacklightStateMachine : NSObject
- (long long)backlightState; - (BOOL)isAlwaysOnEnabled; - (BOOL)isAlwaysOnSuppressed;
@end
@interface BLSHAlwaysOnPresentationEngine : NSObject
- (BOOL)isSuppressed; - (BOOL)isUsingPseudoFlipbook; - (void)suspendForReason:(id)reason;
@end
@interface BLSHBacklightSceneHostEnvironment : NSObject
- (BOOL)supportsAlwaysOn; - (BOOL)isAlwaysOnActive; - (long long)visualState;
@end
@interface PRPosterEnvironmentImpl : NSObject
- (CGFloat)backlightProgress; - (long long)luminance;
@end
@interface BLSBacklight : NSObject + (BOOL)isAlwaysOnEnabledByHardware; @end
@interface CBDisplayModule : NSObject + (BOOL)isAlwaysOnDisplaySupported; @end
@interface CBController : NSObject - (void)setPowerState:(BOOL)state completion:(id)completion; @end

// Khai báo thêm cho iOS 16
@interface PaperBoardController : NSObject
- (void)setAlwaysOnDisplayDimmingView:(UIView *)view;
@end
@interface CLKDevice : NSObject
- (BOOL)supportsAlwaysOnDisplay;
@end
@interface CLKUIColoringView : UIView
- (void)setAlwaysOnDimmed:(BOOL)dimmed;
@end
@interface SBLowPowerModeAlwaysOnPolicy : NSObject @end
@interface SBFocusModeAlwaysOnPolicy : NSObject @end
@interface SBThermalAlwaysOnPolicy : NSObject @end
@interface BLSBacklightFBSSceneEnvironment : NSObject @end
@interface BLSHXPCBacklightProxyHost : NSObject @end

//==============================================================
// 2. TẦNG DRIVER & PHẦN CỨNG (BACKBOARDD)
//==============================================================
%group Group_Backboardd
%hook CBController
- (void)setPowerState:(BOOL)state completion:(id)completion {
    if (isAODMasterEnabled() && !state && gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) { %orig(YES, completion); return; }
    %orig(state, completion);
}
%end
%hook CAWindowServerDisplay
- (float)refreshRate { if (isAODMasterEnabled() && gCurrentState == AODStateActive) return getCustomAODRefreshRate(); return %orig; }
- (void)setRefreshRate:(float)rate { if (isAODMasterEnabled() && gCurrentState == AODStateActive) { %orig(getCustomAODRefreshRate()); return; } %orig(rate); }
- (BOOL)blankingRemovesPower { if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) return NO; return %orig; }
- (void)setBlankingRemovesPower:(BOOL)val { if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) { %orig(NO); return; } %orig(val); }
- (BOOL)disabled { if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) return NO; return %orig; }
- (void)setDisabled:(BOOL)val { if (isAODMasterEnabled() && val && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) { %orig(NO); return; } %orig(val); }
- (BOOL)isBlanked { if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) return NO; return %orig; }
- (void)setBlanked:(BOOL)blanked { if (isAODMasterEnabled() && blanked && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) { %orig(NO); return; } %orig(blanked); }
- (BOOL)disablesUpdates { if (isAODMasterEnabled() && gCurrentState == AODStateActive) return NO; return %orig; }
- (void)setDisablesUpdates:(BOOL)val { if (isAODMasterEnabled() && gCurrentState == AODStateActive) { %orig(NO); return; } %orig(val); }
%end
%hook BLSHBacklightStateMachine
- (BOOL)isAlwaysOnEnabled { if (shouldSuppressAODBySystemPolicies()) return NO; return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnSuppressed { if (isAODMasterEnabled()) return (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies()) ? YES : NO; return %orig; }
- (long long)backlightState { long long state = %orig; if (isAODMasterEnabled() && state == 0 && gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) return 2; return state; }
%end
%hook BLSHFlipbookSpecification
- (double)framesPerSecond { if (isAODMasterEnabled() && gCurrentState == AODStateActive) return (double)getCustomAODRefreshRate(); return %orig; }
- (double)minimumGapDuration { if (isAODMasterEnabled() && gCurrentState == AODStateActive) { double fps = (double)getCustomAODRefreshRate(); return (fps <= 1.0) ? 1.0 : (1.0 / fps); } return %orig; }
%end
%hook BLSHAlwaysOnPresentationEngine
- (BOOL)isSuppressed { if (isAODMasterEnabled() && (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies())) return YES; return %orig; }
- (BOOL)isUsingPseudoFlipbook { return isAODMasterEnabled() ? YES : %orig; }
- (void)suspendForReason:(id)reason { if (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) return; %orig(reason); }
%end
%hook BLSHBacklightSceneHostEnvironment
- (BOOL)supportsAlwaysOn { if (shouldSuppressAODBySystemPolicies()) return NO; return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnActive { return (isAODMasterEnabled() && gCurrentState == AODStateActive && !shouldSuppressAODBySystemPolicies()) ? YES : %orig; }
- (long long)visualState { long long state = %orig; if (isAODMasterEnabled() && state == 0 && gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) return 2; return state; }
%end
%end // Group_Backboardd

//==============================================================
// 3. TẦNG SPRINGBOARD
//==============================================================
%group Group_SpringBoard
static CSCoverSheetViewController *gCoverSheetVC = nil;
static CSCombinedListViewController *gCombinedListVC = nil;

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application { %orig; gSpringBoardDidFinishLaunching = YES; }
%end
%hook CSCoverSheetViewController
- (void)viewDidLoad { %orig; gCoverSheetVC = self; }
- (BOOL)isAlwaysOnPresentation { return (isAODMasterEnabled() && gCurrentState == AODStateActive) ? YES : %orig; }
- (BOOL)shouldDimForAlwaysOn { return (isAODMasterEnabled() && gCurrentState == AODStateActive) ? YES : %orig; }
- (long long)backlightLuminance { return (isAODMasterEnabled() && gCurrentState == AODStateActive) ? 1 : %orig; }
- (void)_updateWallpaperEffectView {
    %orig;
    UIView *floatingLayer = nil; UIView *effectView = nil;
    @try { floatingLayer = [self valueForKey:@"_wallpaperFloatingLayerContainerView"]; effectView = [self valueForKey:@"_wallpaperEffectView"]; } @catch (NSException *e) {}
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        if (!isWallpaperEnabled()) { if (floatingLayer) floatingLayer.alpha = 0.0f; if (effectView) { effectView.backgroundColor = [UIColor blackColor]; effectView.alpha = 1.0f; } self.view.backgroundColor = [UIColor blackColor]; }
        else { if (floatingLayer) floatingLayer.alpha = 1.0f; if (effectView) { effectView.backgroundColor = [UIColor clearColor]; effectView.alpha = 0.0f; } }
    } else { if (floatingLayer) floatingLayer.alpha = 1.0f; if (effectView) { effectView.backgroundColor = [UIColor clearColor]; effectView.alpha = 0.0f; } self.view.backgroundColor = [UIColor clearColor]; }
}
%end
%hook CSCombinedListViewController
- (BOOL)showNotificationsInAlwaysOn { return isAODMasterEnabled() ? isNotificationsEnabled() : %orig; }
- (void)_setNotificationListHidden:(BOOL)hidden forReason:(id)reason {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive && !isNotificationsEnabled()) { %orig(YES, reason); return; }
    %orig(hidden, reason);
}
%end
%hook SBLockScreenViewControllerBase
- (void)setBacklightLevel:(float)level { if (isAODMasterEnabled() && gCurrentState == AODStateActive) { %orig(getAODPanelBrightnessFactor() * 100.0f); return; } %orig(level); }
%end
%hook SBBacklightController
- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion {
    if (isAODMasterEnabled() && state == 0 && gCurrentState != AODStateProximityOff && !shouldSuppressAODBySystemPolicies()) {
        gCurrentState = AODStateActive; state = 2;
        if (gCoverSheetVC) { dispatch_async(dispatch_get_main_queue(), ^{ [gCoverSheetVC _updateWallpaperEffectView]; }); }
    } else if (state == 1 || state == 3) { gCurrentState = AODStateIdle; }
    %orig(state, source, YES, completion);
}
- (float)_factorToPublishForBacklightState:(long long)state { if (isAODMasterEnabled() && gCurrentState == AODStateActive) { if (gCurrentState == AODStateProximityOff || shouldSuppressAODBySystemPolicies()) return 0.0f; return getAODPanelBrightnessFactor(); } return %orig(state); }
%end
%hook SBBacklightPlatformProvider
- (id)initWithBacklightEnvironmentSessionProvider:(id)provider { if (provider) gInjectedSessionProvider = provider; return %orig(provider); }
- (BOOL)deviceSupportsAlwaysOn { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnEnabled { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isShowingBlankingWindow { return (isAODMasterEnabled() && gCurrentState == AODStateActive) ? NO : %orig; }
%end
%hook SBLowPowerModeAlwaysOnPolicy
- (BOOL)isAlwaysOnPolicyActive { return NO; } // Bỏ qua chế độ tiết kiệm pin
%end
%hook SBThermalAlwaysOnPolicy
- (BOOL)isAlwaysOnPolicyActive { return NO; } // Bỏ qua nhiệt độ
%end
%hook SBLockScreenManager
- (BOOL)shouldPreventBacklightBlankingForAlwaysOn { return (isAODMasterEnabled() && gCurrentState == AODStateActive) ? YES : %orig; }
- (void)unlockUIFromSource:(int)source withOptions:(id)options { gCurrentState = AODStateIdle; %orig; }
%end
%hook SBTapToWakeController
- (void)tapToWakeDidRecognize:(UITapGestureRecognizer *)gesture {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) { gCurrentState = AODStateIdle; [[%c(SBBacklightController) sharedInstance] setBacklightState:1 source:13 animated:YES completion:nil]; }
    %orig(gesture);
}
%end
%end // Group_SpringBoard

//==============================================================
// 4. TẦNG PAPERBOARD & CLOCKANGEL (MỚI - DÀNH CHO IOS 16)
//==============================================================
%group Group_PaperBoard
%hook PaperBoardController
- (void)setAlwaysOnDisplayDimmingView:(UIView *)view {
    %orig(view);
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        view.hidden = NO;
        view.alpha = 1.0f;
    }
}
%end
%hook PRPosterEnvironmentImpl
- (CGFloat)backlightProgress { if (isAODMasterEnabled() && gCurrentState == AODStateActive) return 0.20f; return %orig; }
- (long long)luminance { if (isAODMasterEnabled() && gCurrentState == AODStateActive) return 1; return %orig; }
%end
%end // Group_PaperBoard

%group Group_ClockAngel
%hook CLKDevice
- (BOOL)supportsAlwaysOnDisplay { return YES; }
%end
%hook CLKUIColoringView
- (void)setAlwaysOnDimmed:(BOOL)dimmed {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) { %orig(YES); }
    else { %orig(dimmed); }
}
%end
%end // Group_ClockAngel

//==============================================================
// 5. TẦNG PREFERENCES (MỞ KHÓA GIAO DIỆN GỐC)
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
%hook CBDisplayModule
+ (BOOL)isAlwaysOnDisplaySupported { return YES; }
%end
%hook DBSMainDisplayPreferencesController
- (NSMutableArray *)specifiers {
    NSMutableArray *specs = %orig;
    if (!specs) return specs;
    
    // Nếu Apple đã tự sinh ra thì đéo cần chèn
    for (PSSpecifier *s in specs) {
        NSString *sID = [s propertyForKey:@"id"];
        if ([sID containsString:@"ALWAYS_ON"] || [sID containsString:@"AOD"]) return specs;
    }
    
    Class detailClass = NSClassFromString(@"DBSAlwaysOnViewController");
    if (detailClass) {
        PSSpecifier *spec = [%c(PSSpecifier) preferenceSpecifierNamed:@"Màn hình Luôn bật" target:self set:NULL get:NULL detail:detailClass cell:2 edit:Nil];
        [spec setProperty:@"ALWAYS_ON_DISPLAY" forKey:@"id"];
        [specs insertObject:spec atIndex:1];
    }
    return specs;
}
%end
%hook DBSAlwaysOnViewController
- (BOOL)shouldShowAlwaysOn { return YES; }
- (id)isAlwaysOnEnabled:(PSSpecifier *)specifier { return @(isAODMasterEnabled()); }
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
%end
%end // Group_Preferences

//==============================================================
// 6. CONSTRUCTOR: NẠP TẤT CẢ CÁC TIẾN TRÌNH
//==============================================================
static void AODPreferencesReloadCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) { loadAODPreferences(); }

%ctor {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName];
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];

        loadAODPreferences();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)AODPreferencesReloadCallback, CFSTR("com.jb.aodreal/preferences.changed"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        if ([bid isEqualToString:@"com.apple.springboard"] || [proc isEqualToString:@"SpringBoard"]) {
            gIsSpringBoardProcess = YES;
            %init(Group_SpringBoard);
        } else if ([proc isEqualToString:@"backboardd"]) {
            %init(Group_Backboardd);
        } else if ([proc isEqualToString:@"PaperBoard"] || [bid containsString:@"paperboard"]) {
            %init(Group_PaperBoard); // NẠP AOD HÌNH NỀN iOS 16
        } else if ([proc isEqualToString:@"ClockAngel"] || [bid containsString:@"clockangel"]) {
            %init(Group_ClockAngel); // NẠP AOD ĐỒNG HỒ iOS 16
        } else if ([bid isEqualToString:@"com.apple.Preferences"] || [proc.lowercaseString containsString:@"preferences"]) {
            void *gestaltHandle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
            if (gestaltHandle) {
                void *mgFunc = dlsym(gestaltHandle, "MGGetBoolAnswer");
                if (mgFunc) MSHookFunction(mgFunc, (void *)replaced_MGGetBoolAnswer, (void **)&orig_MGGetBoolAnswer);
            }
            %init(Group_Preferences);
        }
    }
}
