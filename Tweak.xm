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
// 0. KHAI BÁO GIAO THỨC VÀ INTERFACE NỘI BỘ
//==============================================================

@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)title
                                  target:(id)target
                                     set:(SEL)set
                                     get:(SEL)get
                                  detail:(Class)detail
                                    cell:(long long)cell
                                    edit:(Class)edit;
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
- (PSSpecifier *)_alwaysOnDisplaySpecifier;
- (PSSpecifier *)_showWallpaperSpecifier;
- (PSSpecifier *)_showNotificationsSpecifier;
- (id)isAlwaysOnEnabled:(PSSpecifier *)specifier;
- (void)setAlwaysOnDisplayEnabled:(id)value specifier:(PSSpecifier *)specifier;
@end

@interface CAWindowServerDisplay : NSObject
- (id)currentMode;
- (BOOL)supportsVariableRefreshRate;
- (BOOL)supportsLowPowerRefreshRate;
- (BOOL)supportsArbitraryFrameRates;
- (void)setRefreshRate:(float)rate;
- (float)refreshRate;
- (void)setLowPowerRefreshRate:(float)arg1;
- (float)lowPowerRefreshRate;
@end

@interface CADisplay : NSObject
- (CAFrameRateRange)preferredFrameRateRange;
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range;
- (void)setFrameRateRange:(CAFrameRateRange)range;
- (BOOL)supportsArbitraryFrameRates;
@end

@interface CSCoverSheetViewController : UIViewController
- (BOOL)isAlwaysOnPresentation;
- (BOOL)shouldDimForAlwaysOn;
- (void)updateAlwaysOnPresentationAnimated:(BOOL)animated;
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
- (void)setUsePseudoFlipbook:(BOOL)use;
- (BOOL)alwaysFillFlipbook;
- (void)setAlwaysFillFlipbook:(BOOL)fill;
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
// 1. BIẾN TOÀN CỤC & QUẢN TRỊ TRẠNG THÁI HIỂN THỊ
//==============================================================

static BOOL gIsAODActive = NO;
static BOOL gHasActiveNotification = NO;
static BOOL gIsDisplayDriverConfigured = NO;
static BOOL gIsProximityBlocked = NO;
static NSInteger gBurnInShiftCounter = 0;

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
    if (!isAODMasterEnabled() || !gIsAODActive || gIsProximityBlocked) return;
    gHasActiveNotification = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gHasActiveNotification = NO;
    });
}

//==============================================================
// 2. TẦNG 1 & 2: BACKBOARDD, IOKIT VÀ FLIPBOOK SUBSYSTEM
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
        gIsDisplayDriverConfigured = YES;
    }
    return ret;
}

%hook CAWindowServerDisplay
- (BOOL)supportsVariableRefreshRate { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)supportsLowPowerRefreshRate { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)supportsArbitraryFrameRates { return isAODMasterEnabled() ? YES : %orig; }
- (float)refreshRate {
    if (isAODMasterEnabled() && gIsAODActive) {
        return gHasActiveNotification ? 50.0f : getCustomAODRefreshRate();
    }
    return %orig;
}
- (void)setRefreshRate:(float)rate {
    if (isAODMasterEnabled() && gIsAODActive) {
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
    if (isAODMasterEnabled() && gIsAODActive) {
        float targetHz = gHasActiveNotification ? 50.0f : getCustomAODRefreshRate();
        return CAFrameRateRangeMake(targetHz, targetHz, targetHz);
    }
    return %orig;
}
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if (isAODMasterEnabled() && gIsAODActive) {
        float targetHz = gHasActiveNotification ? 50.0f : getCustomAODRefreshRate();
        %orig(CAFrameRateRangeMake(targetHz, targetHz, targetHz));
        return;
    }
    %orig(range);
}
- (void)setFrameRateRange:(CAFrameRateRange)range {
    if (isAODMasterEnabled() && gIsAODActive) {
        float targetHz = gHasActiveNotification ? 50.0f : getCustomAODRefreshRate();
        %orig(CAFrameRateRangeMake(targetHz, targetHz, targetHz));
        return;
    }
    %orig(range);
}
- (BOOL)supportsArbitraryFrameRates { return isAODMasterEnabled() ? YES : %orig; }
%end

%hook BKDisplayRenderOverlay
- (BOOL)disablesDisplayBlanking { return isAODMasterEnabled() ? YES : %orig; }
%end

// Chặn ngắt nguồn màn hình trừ khi bị che cảm biến hoặc úp máy
%hook BKDisplayManager
- (void)setBlanked:(BOOL)blanked withReason:(id)reason {
    if (isAODMasterEnabled() && gIsAODActive && blanked) {
        if (!gIsProximityBlocked) {
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
        // SỬA Ở ĐÂY: Phải trả về NO cứng để ép hệ thống KHÔNG được đè nén AOD.
        // Chỉ trả về YES khi điện thoại bị che cảm biến / đút túi.
        return gIsProximityBlocked ? YES : NO;
    }
    return %orig;
}

// Trả về %orig để hệ thống tắt AOD khi có cuộc gọi, camera, báo thức
- (BOOL)isAlwaysOnDisabledByAssertion {
    return %orig;
}

- (long long)backlightState {
    long long state = %orig;
    if (isAODMasterEnabled() && state == 0) {
        if (!gIsProximityBlocked) {
            gIsAODActive = YES;
            return 2; // Ép sang State 2 (Trạng thái AOD)
        }
    }
    if (state != 2 && state != 0) {
        gIsAODActive = NO;
        gHasActiveNotification = NO;
    }
    return state;
}
%end

%hook BLSHAlwaysOnPresentationEngine
- (BOOL)isSuppressed {
    if (isAODMasterEnabled()) {
        return gIsProximityBlocked ? YES : %orig;
    }
    return %orig;
}

- (void)setSuppressed:(BOOL)suppressed {
    if (isAODMasterEnabled() && !gIsProximityBlocked && suppressed) {
        %orig(NO);
        return;
    }
    %orig(suppressed);
}

- (BOOL)isUsingPseudoFlipbook {
    return isAODMasterEnabled() ? YES : %orig;
}

- (BOOL)alwaysFillFlipbook {
    return isAODMasterEnabled() ? YES : %orig;
}

// FIX 2: Loại bỏ hook purgeFlipbook thủ công, để hệ thống tự quản lý chu kỳ dọn frame
%end

%hook BLSHBacklightSceneHostEnvironment
- (BOOL)supportsAlwaysOn { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnActive { return (isAODMasterEnabled() && !gIsProximityBlocked) ? YES : %orig; }
- (BOOL)isClientActive { return isAODMasterEnabled() ? YES : %orig; }
- (long long)visualState {
    long long state = %orig;
    if (isAODMasterEnabled() && state == 0 && !gIsProximityBlocked) return 2;
    return state;
}
%end

%end // Group_Backboardd

//==============================================================
// 3. TẦNG 3: SPRINGBOARD, CẢM BIẾN TIỆM CẬN & CHỐNG ÁM MÀN
//==============================================================

%group Group_SpringBoard

%hook CSCoverSheetViewController
- (BOOL)isAlwaysOnPresentation { 
    return (isAODMasterEnabled() && gIsAODActive && !gIsProximityBlocked) ? YES : %orig; 
}
- (BOOL)shouldDimForAlwaysOn { 
    return (isAODMasterEnabled() && gIsAODActive) ? YES : %orig; 
}
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (isAODMasterEnabled() && gIsAODActive) [self updateAlwaysOnPresentationAnimated:animated];
}
%end

%hook SBLockScreenManager
- (BOOL)shouldPreventBacklightBlankingForAlwaysOn { 
    return (isAODMasterEnabled() && !gIsProximityBlocked) ? YES : %orig; 
}
- (void)lockUIFromSource:(int)source withOptions:(id)options {
    %orig;
    if (isAODMasterEnabled()) {
        gIsAODActive = YES;
        [UIDevice currentDevice].proximityMonitoringEnabled = YES;
    }
}
- (void)unlockUIFromSource:(int)source withOptions:(id)options {
    %orig;
    gIsAODActive = NO;
    gHasActiveNotification = NO;
    gIsProximityBlocked = NO;
    [UIDevice currentDevice].proximityMonitoringEnabled = NO;
}
%end

// Chống ám màn hình: Tịnh tiến tọa độ vi mô cụm đồng hồ
%hook SBFLockScreenDateViewController
- (void)updateTimeNow {
    %orig;
    if (isAODMasterEnabled() && gIsAODActive) {
        gBurnInShiftCounter++;
        CGFloat dx = (CGFloat)((gBurnInShiftCounter % 3) - 1) * 1.5f;
        CGFloat dy = (CGFloat)(((gBurnInShiftCounter / 3) % 3) - 1) * 1.5f;
        
        [UIView animateWithDuration:0.5f animations:^{
            self.view.transform = CGAffineTransformMakeTranslation(dx, dy);
        }];
    } else {
        self.view.transform = CGAffineTransformIdentity;
    }
}
%end

%hook SBNCNotificationDispatcher
- (void)_postNotificationRequest:(id)request {
    %orig;
    if (gIsAODActive && isNotificationsEnabled()) TriggerNotificationBoost();
}
%end

%hook NCNotificationDispatcher
- (void)postNotificationWithRequest:(id)request {
    %orig;
    if (gIsAODActive && isNotificationsEnabled()) TriggerNotificationBoost();
}
%end

// FIX 3: Chỉ can thiệp mức sáng AOD bình thường, không tự ép factor 0.0f đè lên tiệm cận
%hook SBBacklightController
- (void)animateBacklightToFactor:(float)factor duration:(double)duration source:(long long)source completion:(id)completion {
    if (isAODMasterEnabled() && !gIsProximityBlocked) {
        if (factor <= 0.05f) {
            gIsAODActive = YES;
            factor = getCustomAODBrightnessFactor();
        } else {
            gIsAODActive = NO;
            gHasActiveNotification = NO;
        }
    }
    %orig(factor, duration, source, completion);
}
%end

%end // Group_SpringBoard

//==============================================================
// 4. TẦNG 4: POSTERBOARD (NỀN ĐEN TUYỀN OLED)
//==============================================================

%group Group_PosterBoard

%hook PRRenderingBacklightEnvironment
- (BOOL)supportsAlwaysOn { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnActive { return (isAODMasterEnabled() && !gIsProximityBlocked) ? YES : %orig; }
%end

%hook PRPosterEnvironmentImpl
- (long long)backlightLuminance {
    if (isAODMasterEnabled() && gIsAODActive) {
        if (gIsProximityBlocked) return 0;
        return isWallpaperEnabled() ? 1 : 0;
    }
    return %orig;
}
%end

%end // Group_PosterBoard

//==============================================================
// 5. TẦNG 5: GIAO DIỆN CÀI ĐẶT AOD GỐC APPLE
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
    if (!detailClass) {
        AODLog(@"LỖI: Không tìm thấy class DBSAlwaysOnViewController");
        return;
    }

    PSSpecifier *aodSpec = [%c(PSSpecifier) preferenceSpecifierNamed:@"Màn hình luôn bật"
                                                              target:list
                                                                 set:NULL
                                                                 get:NULL
                                                              detail:detailClass
                                                                cell:2
                                                                edit:Nil];
    [aodSpec setProperty:kAODID forKey:@"id"];
    [aodSpec setProperty:NSStringFromClass(detailClass) forKey:@"detail"];

    NSInteger idx = -1;
    for (NSInteger i = 0; i < (NSInteger)specs.count; i++) {
        NSString *sid = [[[specs objectAtIndex:i] propertyForKey:@"id"] description].uppercaseString;
        if ([sid containsString:@"RAISE"] || [sid containsString:@"WAKE"]) { 
            idx = i + 1; 
            break; 
        }
    }
    if (idx < 0) {
        for (NSInteger i = 0; i < (NSInteger)specs.count; i++) {
            NSString *sid = [[[specs objectAtIndex:i] propertyForKey:@"id"] description].uppercaseString;
            if ([sid containsString:@"AUTOLOCK"] || [sid containsString:@"AUTO_LOCK"]) { 
                idx = i + 1; 
                break; 
            }
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
                                                               target:self
                                                                  set:@selector(setCustomHz:spec:)
                                                                  get:@selector(getCustomHz:)
                                                               detail:Nil cell:5 edit:Nil];
    [hzSlider setProperty:kAODHzID forKey:@"id"];
    [hzSlider setProperty:@(2.0f) forKey:@"min"];
    [hzSlider setProperty:@(20.0f) forKey:@"max"];
    [hzSlider setProperty:@YES forKey:@"showValue"];

    PSSpecifier *brightSlider = [%c(PSSpecifier) preferenceSpecifierNamed:@"Độ sáng AOD (Mức 2-20)"
                                                                   target:self
                                                                      set:@selector(setCustomBrightness:spec:)
                                                                      get:@selector(getCustomBrightness:)
                                                                   detail:Nil cell:5 edit:Nil];
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
- (id)getCustomHz:(PSSpecifier *)spec {
    return @(getCustomAODRefreshRate());
}

%new
- (void)setCustomBrightness:(id)value spec:(PSSpecifier *)spec {
    CFPreferencesSetAppValue(CFSTR("CustomAODBrightness"), (__bridge CFPropertyListRef)(value), CFSTR("com.jb.aodreal"));
    CFPreferencesAppSynchronize(CFSTR("com.jb.aodreal"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jb.aodreal/preferences.changed"), NULL, NULL, YES);
}

%new
- (id)getCustomBrightness:(PSSpecifier *)spec {
    return @(getCustomAODBrightnessFactor() * 1000.0f);
}

%end

%end // Group_Preferences

//==============================================================
// 6. KHỞI TẠO VÀ LẮNG NGHE SỰ KIỆN HỆ THỐNG
//==============================================================

static void PreferencesChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    AODLog(@"Nhận được Darwin Notification: Cấu hình preferences đã thay đổi");
}

static void ProximityStateDidChange(NSNotification *notification) {
    if (!gIsAODActive) return;
    BOOL isClose = [UIDevice currentDevice].proximityState;
    if (isClose != gIsProximityBlocked) {
        gIsProximityBlocked = isClose;
        AODLog(@"Cảm biến tiệm cận: %@", isClose ? @"BỊ CHE / ĐÚT TÚI -> TẮT MÀN" : @"HỞ -> BẬT LẠI AOD");
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
        } else if ([bundleID isEqualToString:@"com.apple.Preferences"] || 
                   [processName isEqualToString:@"Preferences"]) {
            %init(Group_Preferences);
        }
    }
}
