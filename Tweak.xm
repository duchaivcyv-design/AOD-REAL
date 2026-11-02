#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAFrameRateRange.h>
#import <IOKit/IOKitLib.h>

//==============================================================
// HÀM GHI LOG DEBUG RA FILE (/tmp/aodreal.log)
//==============================================================
static void AODLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    NSString *logMessage = [NSString stringWithFormat:@"[AODREAL] %@\n", message];
    const char *paths[] = { "/tmp/aodreal.log", "/var/mobile/Library/Preferences/aodreal.log" };
    for (int i = 0; i < 2; i++) {
        FILE *file = fopen(paths[i], "a");
        if (file) {
            fputs([logMessage UTF8String], file);
            fclose(file);
            break;
        }
    }
}

//==============================================================
// 0. BỘ ĐIỀU PHỐI TRẠNG THÁI TRUNG TÂM & TIỆN ÍCH
//==============================================================

typedef NS_ENUM(NSInteger, AODState) {
    AODStateIdle = 0,       // Máy đang dùng / Đã mở khóa
    AODStateActive,        // Đang hiển thị AOD tĩnh
    AODStateProximityOff   // Đang che cảm biến / Bỏ túi
};

static AODState gCurrentState = AODStateIdle;
static BOOL gHasActiveNotification = NO;
static NSInteger gBurnInShiftStep = 0;

static inline BOOL isAODMasterEnabled(void) {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(
        CFSTR("enabled"),
        CFSTR("com.jb.aodreal"),
        &valid
    );
    if (!valid) return YES;
    return (BOOL)val;
}

static inline float getCustomAODRefreshRate(void) {
    CFPropertyListRef val = CFPreferencesCopyAppValue(CFSTR("CustomAODRefreshRate"), CFSTR("com.jb.aodreal"));
    if (val && CFGetTypeID(val) == CFNumberGetTypeID()) {
        float rate = [(__bridge NSNumber *)val floatValue];
        CFRelease(val);
        if (rate >= 2.0f && rate <= 20.0f) return rate;
    }
    if (val) CFRelease(val);
    return 2.0f;
}

static inline float getCustomAODBrightnessFactor(void) {
    CFPropertyListRef val = CFPreferencesCopyAppValue(CFSTR("CustomAODBrightness"), CFSTR("com.jb.aodreal"));
    if (val && CFGetTypeID(val) == CFNumberGetTypeID()) {
        float level = [(__bridge NSNumber *)val floatValue];
        CFRelease(val);
        if (level >= 2.0f && level <= 20.0f) return level / 1000.0f;
    }
    if (val) CFRelease(val);
    return 0.005f;
}

static inline BOOL isWallpaperEnabled(void) {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(
        CFSTR("ShowWallpaperInAlwaysOn"),
        CFSTR("com.apple.BacklightServices"),
        &valid
    );
    if (!valid) return YES;
    return (BOOL)val;
}

static inline BOOL isNotificationsEnabled(void) {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(
        CFSTR("ShowNotificationsInAlwaysOn"),
        CFSTR("com.apple.BacklightServices"),
        &valid
    );
    if (!valid) return YES;
    return (BOOL)val;
}

static void TriggerNotificationBoost(void) {
    if (!isAODMasterEnabled() || gCurrentState != AODStateActive) return;
    gHasActiveNotification = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gHasActiveNotification = NO;
    });
}

//==============================================================
// 1. KHAI BÁO TOÀN BỘ CÁC LỚP HỆ THỐNG ĐỂ BUILD THEOS KHÔNG LỖI
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
- (NSInteger)indexOfSpecifier:(PSSpecifier *)specifier;
@end

@interface DBSAlwaysOnViewController : PSListController
- (id)isAlwaysOnEnabled:(PSSpecifier *)specifier;
- (void)setAlwaysOnDisplayEnabled:(id)value specifier:(PSSpecifier *)specifier;
@end

@interface SBBacklightPlatformProvider : NSObject
- (BOOL)deviceSupportsAlwaysOn;
- (BOOL)isAlwaysOnEnabled;
- (BOOL)isShowingBlankingWindow;
- (void)showBlankingWindow:(BOOL)show withFadeDuration:(double)duration;
- (void)_setBlankingWindowVisible:(BOOL)visible fadeDuration:(double)duration;
- (BOOL)isUsingAlwaysOnBrightnessCurve;
@end

@interface SBAlwaysOnPolicyCoordinator : NSObject
- (NSSet *)activePolicies;
- (void)_activatePolicy:(id)policy;
@end

// Bổ sung đầy đủ các policy con nội bộ của SpringBoard
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

// Khai báo các subsystem chuyển tiếp của backboardd
@interface BLSHBacklightTransitionStateMachine : NSObject
- (BOOL)isAlwaysOnEnabled;
- (BOOL)isAlwaysOnSuppressed;
@end

@interface BLSHXPCBacklightProxyHost : NSObject
- (BOOL)isAlwaysOnEnabled;
@end

@interface BLSHFlipbookSpecification : NSObject
- (double)framesPerSecond;
@end

@interface CAWindowServerDisplay : NSObject
- (id)currentMode;
- (void)setRefreshRate:(float)rate;
- (float)refreshRate;
- (void)setLowPowerRefreshRate:(float)arg1;
- (float)lowPowerRefreshRate;
@end

@interface CADisplay : NSObject
- (CAFrameRateRange)preferredFrameRateRange;
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range;
- (void)setFrameRateRange:(CAFrameRateRange)range;
@end

@interface CSCoverSheetViewController : UIViewController
- (BOOL)isAlwaysOnPresentation;
- (BOOL)shouldDimForAlwaysOn;
@end

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isLockScreenActive;
- (BOOL)shouldPreventBacklightBlankingForAlwaysOn;
@end

@interface SBBacklightController : NSObject
+ (instancetype)sharedInstance;
- (void)animateBacklightToFactor:(float)factor duration:(double)duration source:(long long)source completion:(id)completion;
- (float)backlightFactor;
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
@end

@interface BLSHBacklightSceneHostEnvironment : NSObject
- (BOOL)supportsAlwaysOn;
- (BOOL)isAlwaysOnActive;
- (long long)visualState;
- (BOOL)isClientActive;
@end

@interface SBFLockScreenDateViewController : UIViewController
@end

//==============================================================
// 2. TẦNG BACKBOARDD & DRIVER PHẦN CỨNG
//==============================================================

%group Group_Backboardd

%hookf(kern_return_t, IORegistryEntryCreateCFProperties, io_registry_entry_t entry, CFMutableDictionaryRef *properties, CFAllocatorRef allocator, uint32_t options) {
    kern_return_t ret = %orig(entry, properties, allocator, options);
    if (ret == KERN_SUCCESS && properties && *properties && isAODMasterEnabled()) {
        int customRate = (int)getCustomAODRefreshRate();
        int minRate = 2;
        int maxRate = 60;
        
        CFNumberRef rateNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &customRate);
        CFNumberRef minRateNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &minRate);
        CFNumberRef maxRateNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &maxRate);

        CFDictionarySetValue(*properties, CFSTR("supports-aod"), kCFBooleanTrue);
        CFDictionarySetValue(*properties, CFSTR("supports-variable-refresh-rate"), kCFBooleanTrue);
        CFDictionarySetValue(*properties, CFSTR("supports-arbitrary-frame-rates"), kCFBooleanTrue);
        CFDictionarySetValue(*properties, CFSTR("timing-sample-rate"), rateNum);
        CFDictionarySetValue(*properties, CFSTR("min-refresh-rate"), minRateNum);
        CFDictionarySetValue(*properties, CFSTR("max-refresh-rate"), maxRateNum);
        CFDictionarySetValue(*properties, CFSTR("target-refresh-rate"), rateNum);
        CFDictionarySetValue(*properties, CFSTR("IOMFBSupportsAOD"), kCFBooleanTrue);

        CFRelease(rateNum);
        CFRelease(minRateNum);
        CFRelease(maxRateNum);
    }
    return ret;
}

%hook CAWindowServerDisplay
- (BOOL)supportsVariableRefreshRate { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)supportsLowPowerRefreshRate { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)supportsArbitraryFrameRates { return isAODMasterEnabled() ? YES : %orig; }
- (float)refreshRate {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return gHasActiveNotification ? 50.0f : getCustomAODRefreshRate();
    }
    return %orig;
}
- (void)setRefreshRate:(float)rate {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        %orig(gHasActiveNotification ? 50.0f : getCustomAODRefreshRate());
        return;
    }
    %orig(rate);
}
- (float)lowPowerRefreshRate {
    if (isAODMasterEnabled()) return getCustomAODRefreshRate();
    return %orig;
}
- (void)setLowPowerRefreshRate:(float)arg1 {
    if (isAODMasterEnabled()) { %orig(getCustomAODRefreshRate()); return; }
    %orig(arg1);
}
%end

%hook CADisplay
- (CAFrameRateRange)preferredFrameRateRange {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        float targetHz = gHasActiveNotification ? 50.0f : getCustomAODRefreshRate();
        return CAFrameRateRangeMake(targetHz, targetHz, targetHz);
    }
    return %orig;
}
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        float targetHz = gHasActiveNotification ? 50.0f : getCustomAODRefreshRate();
        %orig(CAFrameRateRangeMake(targetHz, targetHz, targetHz));
        return;
    }
    %orig(range);
}
%end

%hook BKDisplayRenderOverlay
- (BOOL)disablesDisplayBlanking { return isAODMasterEnabled() ? YES : %orig; }
%end

// Không chặn setBlanked thô bạo: Cho phép tắt khi che cảm biến hoặc đút túi
%hook BKDisplayManager
- (void)setBlanked:(BOOL)blanked withReason:(id)reason {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive && blanked) {
        if (gCurrentState != AODStateProximityOff) {
            %orig(NO, reason);
            return;
        }
    }
    %orig(blanked, reason);
}
%end

%hook BLSHBacklightStateMachine
- (BOOL)isAlwaysOnEnabled {
    return isAODMasterEnabled() ? YES : %orig;
}

- (BOOL)isAlwaysOnSuppressed {
    if (isAODMasterEnabled()) {
        return (gCurrentState == AODStateProximityOff) ? YES : NO;
    }
    return %orig;
}

- (BOOL)isAlwaysOnDisabledByAssertion {
    return %orig;
}

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
        gHasActiveNotification = NO;
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

// Ép tốc độ tạo khung hình AOD theo thanh trượt phần cứng[span_3](start_span)[span_3](end_span)
%hook BLSHFlipbookSpecification

- (double)framesPerSecond {
    if (isAODMasterEnabled()) {
        return (double)getCustomAODRefreshRate();
    }
    return %orig;
}

- (id)initWithSoftMemoryLimit:(unsigned long long)arg1 
                frameCapacity:(unsigned long long)arg2 
              framesPerSecond:(double)fps 
           minimumGapDuration:(double)arg4 
             coaelscingEpsilon:(double)arg5 
       minimumPrepareInterval:(double)arg6 
        maximumRenderInterval:(double)arg7 {
    if (isAODMasterEnabled()) {
        fps = (double)getCustomAODRefreshRate();
    }
    return %orig(arg1, arg2, fps, arg4, arg5, arg6, arg7);
}

- (id)initWithFrameCapacity:(unsigned long long)arg1 
            framesPerSecond:(double)fps 
         minimumGapDuration:(double)arg3 
           coaelscingEpsilon:(double)arg4 
     minimumPrepareInterval:(double)arg5 
      maximumRenderInterval:(double)arg6 {
    if (isAODMasterEnabled()) {
        fps = (double)getCustomAODRefreshRate();
    }
    return %orig(arg1, fps, arg3, arg4, arg5, arg6);
}

%end

%hook BLSHAlwaysOnPresentationEngine
- (BOOL)isSuppressed {
    if (isAODMasterEnabled()) {
        return (gCurrentState == AODStateProximityOff) ? YES : %orig;
    }
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
%end

%hook BLSHBacklightSceneHostEnvironment
- (BOOL)supportsAlwaysOn { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnActive { return (isAODMasterEnabled() && gCurrentState != AODStateProximityOff) ? YES : %orig; }
- (BOOL)isClientActive { return isAODMasterEnabled() ? YES : %orig; }
- (long long)visualState {
    long long state = %orig;
    if (isAODMasterEnabled() && state == 0 && gCurrentState != AODStateProximityOff) return 2;
    return state;
}
%end

%end // Group_Backboardd

//==============================================================
// 3. TẦNG SPRINGBOARD: MỞ KHÓA MƯỢT MÀ & CHỐNG ÁM MÀN VÔ HÌNH
//==============================================================

%group Group_SpringBoard

%hook SBBacklightPlatformProvider
- (BOOL)deviceSupportsAlwaysOn { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnEnabled { return isAODMasterEnabled() ? YES : %orig; }

- (BOOL)isShowingBlankingWindow {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return NO;
    }
    return %orig;
}

- (void)showBlankingWindow:(BOOL)show withFadeDuration:(double)duration {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive && show) {
        if (gCurrentState != AODStateProximityOff) {
            return;
        }
    }
    %orig(show, duration);
}

- (void)_setBlankingWindowVisible:(BOOL)visible fadeDuration:(double)duration {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive && visible) {
        if (gCurrentState != AODStateProximityOff) {
            return;
        }
    }
    %orig(visible, duration);
}

- (BOOL)isUsingAlwaysOnBrightnessCurve {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return YES;
    }
    return %orig;
}
%end

// Vô hiệu hóa Coordinator và các Policy hạn chế nội bộ
%hook SBAlwaysOnPolicyCoordinator
- (NSSet *)activePolicies {
    return isAODMasterEnabled() ? [NSSet set] : %orig;
}
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

%hook CSCoverSheetViewController
- (BOOL)isAlwaysOnPresentation { 
    return (isAODMasterEnabled() && gCurrentState == AODStateActive) ? YES : %orig; 
}
- (BOOL)shouldDimForAlwaysOn { 
    return (isAODMasterEnabled() && gCurrentState == AODStateActive) ? YES : %orig; 
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (gCurrentState == AODStateActive) {
        gCurrentState = AODStateIdle;
    }
}
%end

%hook SBLockScreenManager
- (BOOL)shouldPreventBacklightBlankingForAlwaysOn { 
    return (isAODMasterEnabled() && gCurrentState != AODStateProximityOff) ? YES : %orig; 
}

- (void)lockUIFromSource:(int)source withOptions:(id)options {
    %orig;
    if (isAODMasterEnabled()) {
        gCurrentState = AODStateActive;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gCurrentState == AODStateActive) {
                [UIDevice currentDevice].proximityMonitoringEnabled = YES;
            }
        });
    }
}

// Khôi phục ngay độ sáng tự nhiên khi mở khóa máy, tránh kẹt màn hình đen[span_4](start_span)[span_4](end_span)
- (void)unlockUIFromSource:(int)source withOptions:(id)options {
    gCurrentState = AODStateIdle;
    gHasActiveNotification = NO;
    [UIDevice currentDevice].proximityMonitoringEnabled = NO;
    %orig;
}
%end

// CHỐNG ÁM MÀN HÌNH THEO QUỸ ĐẠO ELIP VI MÔ (0.35 px - KHÔNG BỊ PHÁT HIỆN)
%hook SBFLockScreenDateViewController
- (void)updateTimeNow {
    %orig;
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        gBurnInShiftStep++;
        
        // Tạo quỹ đạo vi mô elip 8 điểm xoay vòng
        static const CGFloat kRadiusX = 0.35f;
        static const CGFloat kRadiusY = 0.30f;
        double angle = (gBurnInShiftStep % 8) * (M_PI / 4.0);
        CGFloat dx = (CGFloat)(cos(angle) * kRadiusX);
        CGFloat dy = (CGFloat)(sin(angle) * kRadiusY);
        
        // Chuyển động siêu mượt trong 1.2s, mắt thường không thấy độ lệch
        [UIView animateWithDuration:1.2f 
                              delay:0.0f 
                            options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionAllowUserInteraction 
                         animations:^{
            self.view.transform = CGAffineTransformMakeTranslation(dx, dy);
        } completion:nil];
    } else {
        self.view.transform = CGAffineTransformIdentity;
    }
}
%end

%hook SBNCNotificationDispatcher
- (void)_postNotificationRequest:(id)request {
    %orig;
    if (gCurrentState == AODStateActive && isNotificationsEnabled()) TriggerNotificationBoost();
}
%end

%hook NCNotificationDispatcher
- (void)postNotificationWithRequest:(id)request {
    %orig;
    if (gCurrentState == AODStateActive && isNotificationsEnabled()) TriggerNotificationBoost();
}
%end

// Điều tiết độ sáng êm ái, nhả cờ ngay khi người dùng vuốt/chạm
%hook SBBacklightController
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

%end // Group_SpringBoard

//==============================================================
// 4. TẦNG POSTERBOARD: TẮT NỀN ĐEN TUYỀN OLED
//==============================================================

%group Group_PosterBoard

%hook PRRenderingBacklightEnvironment
- (BOOL)supportsAlwaysOn { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnActive { return (isAODMasterEnabled() && gCurrentState != AODStateProximityOff) ? YES : %orig; }
%end

%hook PRPosterEnvironmentImpl
- (long long)backlightLuminance {
    if (isAODMasterEnabled() && gCurrentState == AODStateActive) {
        return isWallpaperEnabled() ? 1 : 0;
    }
    return %orig;
}
%end

%end // Group_PosterBoard

//==============================================================
// 5. TẦNG GIAO DIỆN CÀI ĐẶT
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
        if ([specID isKindOfClass:[NSString class]] && [(NSString *)specID isEqualToString:kAODID]) {
            return;
        }
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

- (id)isAlwaysOnEnabled:(PSSpecifier *)specifier {
    return @(isAODMasterEnabled());
}

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
    for (PSSpecifier *s in specs) {
        id specID = [s propertyForKey:@"id"];
        if ([specID isKindOfClass:[NSString class]] && [(NSString *)specID isEqualToString:kAODHzID]) {
            return specs;
        }
    }

    PSSpecifier *group = [%c(PSSpecifier) preferenceSpecifierNamed:@"CẤU HÌNH PHẦN CỨNG TẦNG SÂU (2-20)"
                                                           target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
    [group setProperty:@"Ép phần cứng hạ xung nhịp và độ sáng xuống mức tối thiểu khi khóa màn hình." forKey:@"footerText"];

    PSSpecifier *hzSlider = [%c(PSSpecifier) preferenceSpecifierNamed:@"Tần số quét tĩnh (2-20 Hz)"
                                                               target:self set:@selector(setCustomHz:spec:) get:@selector(getCustomHz:) detail:Nil cell:5 edit:Nil];
    [hzSlider setProperty:kAODHzID forKey:@"id"];
    [hzSlider setProperty:@(2.0f) forKey:@"min"];
    [hzSlider setProperty:@(20.0f) forKey:@"max"];
    [hzSlider setProperty:@YES forKey:@"showValue"];

    PSSpecifier *brightSlider = [%c(PSSpecifier) preferenceSpecifierNamed:@"Độ sáng AOD (Mức 2-20)"
                                                                   target:self set:@selector(setCustomBrightness:spec:) get:@selector(getCustomBrightness:) detail:Nil cell:5 edit:Nil];
    [brightSlider setProperty:@"AOD_CUSTOM_BRIGHTNESS_KEY" forKey:@"id"];
    [brightSlider setProperty:@(2.0f) forKey:@"min"];
    [brightSlider setProperty:@(20.0f) forKey:@"max"];
    [brightSlider setProperty:@YES forKey:@"showValue"];

    [specs addObject:group];
    [specs addObject:hzSlider];
    [specs addObject:brightSlider];

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
// 6. KHỞI TẠO & LẮNG NGHE CẢM BIẾN TIỆM CẬN
//==============================================================

static void PreferencesChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    AODLog(@"Nhận Darwin Notification: Đồng bộ cấu hình preferences thành công");
}

static void ProximityStateDidChange(NSNotification *notification) {
    if (gCurrentState == AODStateIdle) return;
    
    BOOL isClose = [UIDevice currentDevice].proximityState;
    if (isClose) {
        gCurrentState = AODStateProximityOff;
    } else {
        gCurrentState = AODStateActive;
    }
}

%ctor {
    @autoreleasepool {
        NSString *processName = [[NSProcessInfo processInfo] processName];
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

        AODLog(@"Tweak nạp vào Process: %@ | Bundle: %@", processName, bundleID);

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            PreferencesChangedCallback,
            CFSTR("com.jb.aodreal/preferences.changed"),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        if ([bundleID isEqualToString:@"com.apple.springboard"]) {
            %init(Group_SpringBoard);
            [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceProximityStateDidChangeNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
                ProximityStateDidChange(note);
            }];
        } else if ([bundleID isEqualToString:@"com.apple.PosterBoard"]) {
            %init(Group_PosterBoard);
        } else if ([processName isEqualToString:@"backboardd"]) {
            %init(Group_Backboardd);
        } else if ([bundleID isEqualToString:@"com.apple.Preferences"] || [processName isEqualToString:@"Preferences"]) {
            %init(Group_Preferences);
        }
    }
}
