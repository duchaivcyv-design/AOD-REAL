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
    const char *path = "/tmp/aodreal.log";
    
    NSLog(@"%@", logMessage);
    const char *paths[] = { path, "/var/mobile/Library/Preferences/aodreal.log" };
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
// 0. KHAI BÁO GIAO THỨC, STRUCT VÀ INTERFACE NỘI BỘ
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
- (void)reloadSpecifiers;
- (void)insertSpecifier:(PSSpecifier *)specifier atIndex:(NSInteger)index animated:(BOOL)animated;
- (void)addSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
- (NSInteger)indexOfSpecifier:(PSSpecifier *)specifier;
@end

@interface CAWindowServerDisplay : NSObject
- (id)currentMode;
- (BOOL)supportsVariableRefreshRate;
- (BOOL)supportsLowPowerRefreshRate;
- (BOOL)supportsArbitraryFrameRates;
- (id)modeWithName:(id)arg1;
- (void)setRefreshRate:(float)rate;
- (float)refreshRate;
- (void)setAllowsVirtualModes:(BOOL)allows;
- (void)setLowPowerRefreshRate:(float)arg1;
- (float)lowPowerRefreshRate;
- (void)setFrameInterval:(NSInteger)interval;
- (NSInteger)frameInterval;
@end

@interface CADisplay : NSObject
- (CAFrameRateRange)preferredFrameRateRange;
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range;
- (void)setFrameRateRange:(CAFrameRateRange)range;
- (BOOL)supportsArbitraryFrameRates;
- (void)setAllowsVirtualModes:(BOOL)arg1;
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
- (void)lockUIFromSource:(int)source withOptions:(id)options;
- (void)unlockUIFromSource:(int)source withOptions:(id)options;
@end

@interface SBBacklightController : NSObject
+ (instancetype)sharedInstance;
- (void)animateBacklightToFactor:(float)factor duration:(double)duration source:(long long)source completion:(id)completion;
- (float)backlightFactor;
- (BOOL)screenIsOn;
- (BOOL)screenIsDim;
@end

@interface BLSHBacklightStateMachine : NSObject
- (long long)backlightState;
- (BOOL)isAlwaysOnSuppressed;
- (void)setAlwaysOnSuppressed:(BOOL)suppressed;
@end

@interface BLSHAlwaysOnPresentationEngine : NSObject
- (BOOL)isAlwaysOnSupported;
- (BOOL)isAlwaysOnActive;
- (BOOL)isAlwaysOnEnabled;
- (BOOL)isAlwaysOnSuppressed;
@end

@interface BLSHBacklightSceneHostEnvironment : NSObject
- (BOOL)supportsAlwaysOn;
- (BOOL)isAlwaysOnActive;
- (long long)visualState;
- (BOOL)isClientActive;
@end

//==============================================================
// 1. BIẾN TOÀN CỤC & TIỆN ÍCH QUẢN TRỊ TRẠNG THÁI HIỂN THỊ
//==============================================================

static BOOL gIsAODActive = NO;
static BOOL gHasActiveNotification = NO;
static BOOL gIsDisplayDriverConfigured = NO;
static float gLastObservedBrightness = 0.5f;

static inline BOOL isAODMasterEnabled(void) {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(
        CFSTR("enabled"),
        CFSTR("com.jb.aodreal"),
        &valid
    );
    if (!valid) return YES; // Mặc định mở cờ hiển thị cho menu
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
    if (!isAODMasterEnabled() || !gIsAODActive) return;
    gHasActiveNotification = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gHasActiveNotification = NO;
    });
}

//==============================================================
// 2. TẦNG 1 & 2: BACKBOARDD, IOKIT VÀ QUARTZCORE (ÉP PANEL CỨNG)
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

%hookf(kern_return_t, IOConnectCallMethod, mach_port_t connection, uint32_t selector, const uint64_t *input, uint32_t inputCnt, const void *inputStruct, size_t inputStructCnt, uint64_t *output, uint32_t *outputCnt, void *outputStruct, size_t *outputStructCnt) {
    kern_return_t ret = %orig(connection, selector, input, inputCnt, inputStruct, inputStructCnt, output, outputCnt, outputStruct, outputStructCnt);
    if (ret != KERN_SUCCESS && isAODMasterEnabled() && gIsAODActive) {
        return KERN_SUCCESS;
    }
    return ret;
}

%hookf(kern_return_t, IORegistryEntrySetCFProperties, io_registry_entry_t entry, CFTypeRef properties) {
    if (isAODMasterEnabled() && gIsAODActive) {
        return KERN_SUCCESS;
    }
    return %orig(entry, properties);
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
- (id)modeWithName:(id)arg1 {
    id mode = %orig;
    if (isAODMasterEnabled() && !mode) return [self currentMode];
    return mode;
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
        %orig(CAFrameRateRangeMake(gHasActiveNotification ? 50.0f : getCustomAODRefreshRate(), gHasActiveNotification ? 50.0f : getCustomAODRefreshRate(), gHasActiveNotification ? 50.0f : getCustomAODRefreshRate()));
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

%hook BKDisplayManager
- (void)setBlanked:(BOOL)blanked withReason:(id)reason {
    if (isAODMasterEnabled() && blanked) { %orig(NO, reason); return; }
    %orig(blanked, reason);
}
%end

%hook BLSHBacklightStateMachine
- (long long)backlightState {
    long long state = %orig;
    if (isAODMasterEnabled() && state == 0) { gIsAODActive = YES; return 2; }
    if (state != 2 && state != 0) { gIsAODActive = NO; gHasActiveNotification = NO; }
    return state;
}
- (BOOL)isAlwaysOnSuppressed { return isAODMasterEnabled() ? NO : %orig; }
- (void)setAlwaysOnSuppressed:(BOOL)suppressed {
    if (isAODMasterEnabled() && suppressed) { %orig(NO); return; }
    %orig(suppressed);
}
%end

%hook BLSHAlwaysOnPresentationEngine
- (BOOL)isAlwaysOnSupported { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnActive { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnEnabled { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnSuppressed { return isAODMasterEnabled() ? NO : %orig; }
%end

%hook BLSHAlwaysOnSuppressionAssertion
- (BOOL)isSuppressed { return isAODMasterEnabled() ? NO : %orig; }
%end

%hook BLSHBacklightSceneHostEnvironment
- (BOOL)supportsAlwaysOn { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnActive { return isAODMasterEnabled() ? YES : %orig; }
- (long long)visualState {
    long long state = %orig;
    if (isAODMasterEnabled() && state == 0) return 2;
    return state;
}
- (BOOL)isClientActive { return isAODMasterEnabled() ? YES : %orig; }
%end

%end // Group_Backboardd

//==============================================================
// 3. TẦNG 3: SPRINGBOARD
//==============================================================

%group Group_SpringBoard

%hook CSCoverSheetViewController
- (BOOL)isAlwaysOnPresentation { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)shouldDimForAlwaysOn { return isAODMasterEnabled() ? YES : %orig; }
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (isAODMasterEnabled() && gIsAODActive) [self updateAlwaysOnPresentationAnimated:animated];
}
%end

%hook SBLockScreenManager
- (BOOL)shouldPreventBacklightBlankingForAlwaysOn { return isAODMasterEnabled() ? YES : %orig; }
- (void)lockUIFromSource:(int)source withOptions:(id)options {
    %orig;
    if (isAODMasterEnabled()) gIsAODActive = YES;
}
- (void)unlockUIFromSource:(int)source withOptions:(id)options {
    %orig;
    gIsAODActive = NO;
    gHasActiveNotification = NO;
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

%hook SBBacklightController
- (void)animateBacklightToFactor:(float)factor duration:(double)duration source:(long long)source completion:(id)completion {
    if (isAODMasterEnabled()) {
        if (factor <= 0.05f) {
            gIsAODActive = YES;
            factor = getCustomAODBrightnessFactor();
        } else {
            gIsAODActive = NO;
            gHasActiveNotification = NO;
            gLastObservedBrightness = factor;
        }
    }
    %orig(factor, duration, source, completion);
}
%end

%hook ProcessControl
- (BOOL)hasBackgroundTasksSuspended {
    if (gIsAODActive) return NO;
    return %orig;
}
%end

%end // Group_SpringBoard

//==============================================================
// 4. TẦNG 4: POSTERBOARD
//==============================================================

%group Group_PosterBoard

%hook PRRenderingBacklightEnvironment
- (BOOL)supportsAlwaysOn { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnActive { return isAODMasterEnabled() ? YES : %orig; }
%end

%hook PRPosterEnvironmentImpl
- (long long)backlightLuminance {
    if (isAODMasterEnabled()) return isWallpaperEnabled() ? 1 : 0;
    return %orig;
}
%end

%end // Group_PosterBoard

//==============================================================
// 5. TẦNG 5: GIAO DIỆN CÀI ĐẶT (ÉP HIỆN BẰNG VIEWWILLAPPEAR)
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

// Nạp bundle prefs thủ công (Settings chỉ tự nạp khi bấm vào entry của PreferenceLoader)
static Class AODLoadPrefsClass(void) {
    Class c = NSClassFromString(@"AODREALRootListController");
    if (c) return c;
    NSArray *paths = @[ @"/var/jb/Library/PreferenceBundles/AODREALPrefs.bundle",
                        @"/Library/PreferenceBundles/AODREALPrefs.bundle" ];
    for (NSString *p in paths) {
        NSBundle *b = [NSBundle bundleWithPath:p];
        if (b && [b load]) {
            AODLog(@"Đã nạp bundle: %@", p);
            c = NSClassFromString(@"AODREALRootListController");
            if (c) return c;
        } else {
            AODLog(@"Không nạp được bundle (tồn tại=%d): %@", b != nil, p);
        }
    }
    return Nil;
}

static void AODInjectIntoList(PSListController *list) {
    NSString *className = NSStringFromClass([list class]);
    if (!([className containsString:@"Display"] || [className containsString:@"Brightness"] ||
          [className containsString:@"DBS"] || [className containsString:@"DBR"])) return;

    NSMutableArray *specs = [list specifiers];
    if (!specs) return;

    static NSString *const kAODID = @"AODREAL_ENTRY";
    for (PSSpecifier *s in specs) {
        if ([[s propertyForKey:@"id"] isEqual:kAODID]) return; // đã chèn rồi
    }

    // In toàn bộ ID để biết chính xác trang này có những gì
    NSMutableArray *ids = [NSMutableArray array];
    for (PSSpecifier *s in specs) [ids addObject:[s propertyForKey:@"id"] ?: @"(nil)"];
    AODLog(@"Class=%@ | specifier IDs=%@", className, ids);

    Class detailClass = AODLoadPrefsClass();
    if (!detailClass) { AODLog(@"LỖI: không có class AODREALRootListController"); return; }

    PSSpecifier *aodSpec = [%c(PSSpecifier) preferenceSpecifierNamed:@"Màn hình luôn bật (AOD)"
                                                          target:list
                                                             set:NULL
                                                             get:NULL
                                                          detail:detailClass
                                                            cell:2 // PSLinkCell
                                                            edit:Nil];
    [aodSpec setProperty:kAODID forKey:@"id"];

    // Tìm vị trí: ưu tiên sau "Đưa lên để bật", rồi tới "Tự động khóa", cuối cùng là cuối trang
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

    // KHÔNG dùng reloadSpecifiers (nó xoá sạch mảng và dựng lại từ đầu -> mất mục vừa chèn)
    if (idx >= 0 && idx <= (NSInteger)specs.count) {
        [list insertSpecifier:aodSpec atIndex:idx animated:NO];
    } else {
        [list addSpecifier:aodSpec animated:NO];
    }
    AODLog(@"=> Đã chèn AOD tại index %ld", (long)idx);
}

%hook PSListController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    AODInjectIntoList(self);
}
// Nếu hệ thống tự reload (đổi dark mode, v.v.) thì chèn lại
- (void)reloadSpecifiers {
    %orig;
    AODInjectIntoList(self);
}
%end

%end // Group_Preferences

//==============================================================
// 6. CONSTRUCTOR
//==============================================================

%ctor {
    @autoreleasepool {
        NSString *processName = [[NSProcessInfo processInfo] processName];
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

        AODLog(@"Tweak nạp vào Process: %@ | Bundle: %@", processName, bundleID);

        if ([bundleID isEqualToString:@"com.apple.springboard"]) {
            %init(Group_SpringBoard);
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
