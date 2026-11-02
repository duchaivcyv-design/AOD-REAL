#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAFrameRateRange.h>
#import <IOKit/IOKitLib.h>

//==============================================================
// KHAI BÁO GIAO THỨC & INTERFACE NỘI BỘ
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
@end

@interface CADisplay : NSObject
- (CAFrameRateRange)preferredFrameRateRange;
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range;
- (void)setFrameRateRange:(CAFrameRateRange)range;
@end

//==============================================================
// BIẾN TOÀN CỤC & HÀM ĐỌC/GHI CẤU HÌNH TỪ CÀI ĐẶT
//==============================================================
static BOOL gIsAODActive = NO;
static BOOL gHasActiveNotification = NO;

// Kiểm tra công tắc tổng của Tweak
static BOOL isAODMasterEnabled(void) {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(
        CFSTR("enabled"),
        CFSTR("com.jb.aodreal"),
        &valid
    );
    if (!valid) return NO;
    return (BOOL)val;
}

// Đọc tần số quét tùy chỉnh (Mặc định: 2 Hz, dải 2 - 20 Hz)
static float getCustomAODRefreshRate(void) {
    CFPropertyListRef val = CFPreferencesCopyAppValue(CFSTR("CustomAODRefreshRate"), CFSTR("com.jb.aodreal"));
    if (val && CFGetTypeID(val) == CFNumberGetTypeID()) {
        float rate = [(__bridge NSNumber *)val floatValue];
        CFRelease(val);
        if (rate >= 2.0f && rate <= 20.0f) return rate;
    }
    if (val) CFRelease(val);
    return 2.0f; // Mặc định hạ cứng xuống 2Hz
}

// Đọc mức độ sáng siêu thấp (Ánh xạ từ 2 - 20 thành 0.002f - 0.020f)
static float getCustomAODBrightnessFactor(void) {
    CFPropertyListRef val = CFPreferencesCopyAppValue(CFSTR("CustomAODBrightness"), CFSTR("com.jb.aodreal"));
    if (val && CFGetTypeID(val) == CFNumberGetTypeID()) {
        float level = [(__bridge NSNumber *)val floatValue];
        CFRelease(val);
        if (level >= 2.0f && level <= 20.0f) return level / 1000.0f;
    }
    if (val) CFRelease(val);
    return 0.005f; // Mức mặc định (0.005f)
}

// Kích hoạt xung nhịp 50Hz tức thời khi có thông báo đáp xuống
static void TriggerNotificationBoost(void) {
    gHasActiveNotification = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gHasActiveNotification = NO;
    });
}

//==============================================================
// TẦNG 1: BẺ KHÓA IOKIT FRAMEBUFFER & CHẶN TỪ CHỐI PANEL CỨNG
//==============================================================

// 1.1 Ghi đè thông số driver của tấm nền (AppleCLCD2 / IOMobileFramebuffer)
%hookf(kern_return_t, IORegistryEntryCreateCFProperties, io_registry_entry_t entry, CFMutableDictionaryRef *properties, CFAllocatorRef allocator, uint32_t options) {
    kern_return_t ret = %orig(entry, properties, allocator, options);
    if (ret == KERN_SUCCESS && properties && *properties && isAODMasterEnabled()) {
        int customRate = (int)getCustomAODRefreshRate();
        CFNumberRef rateNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &customRate);
        int minRate = 2;
        CFNumberRef minRateNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &minRate);

        // Bơm các thuộc tính cứng ép nhận diện AOD và tần số thấp vào Registry
        CFDictionarySetValue(*properties, CFSTR("supports-aod"), kCFBooleanTrue);
        CFDictionarySetValue(*properties, CFSTR("supports-variable-refresh-rate"), kCFBooleanTrue);
        CFDictionarySetValue(*properties, CFSTR("supports-arbitrary-frame-rates"), kCFBooleanTrue);
        CFDictionarySetValue(*properties, CFSTR("timing-sample-rate"), rateNum);
        CFDictionarySetValue(*properties, CFSTR("min-refresh-rate"), minRateNum);
        CFDictionarySetValue(*properties, CFSTR("target-refresh-rate"), rateNum);

        CFRelease(rateNum);
        CFRelease(minRateNum);
    }
    return ret;
}

// 1.2 Bắt và nuốt toàn bộ mã từ chối kIOReturnUnsupportedMode khi ép mode tần số quét thấp
%hookf(kern_return_t, IOConnectCallMethod, mach_port_t connection, uint32_t selector, const uint64_t *input, uint32_t inputCnt, const void *inputStruct, size_t inputStructCnt, uint64_t *output, uint32_t *outputCnt, void *outputStruct, size_t *outputStructCnt) {
    kern_return_t ret = %orig(connection, selector, input, inputCnt, inputStruct, inputStructCnt, output, outputCnt, outputStruct, outputStructCnt);
    // Khi đang trong trạng thái AOD, nếu phần cứng trả về mã lỗi không hỗ trợ mode, ép nhận thành công
    if (ret != KERN_SUCCESS && isAODMasterEnabled() && gIsAODActive) {
        return KERN_SUCCESS;
    }
    return ret;
}

// 1.3 Ép hàm thiết lập thuộc tính IOKit luôn nhận tham số tần số quét thấp
%hookf(kern_return_t, IORegistryEntrySetCFProperties, io_registry_entry_t entry, CFTypeRef properties) {
    if (isAODMasterEnabled() && gIsAODActive) {
        return KERN_SUCCESS;
    }
    return %orig(entry, properties);
}


//==============================================================
// TẦNG 2: QUARTZCORE, BACKBOARDD & TRIỆT TIÊU WATCHDOG BLANKING
//==============================================================
%group Group_Backboardd

// 2.1 Ép CAWindowServerDisplay cho phép chạy virtual timing mode và hạ refresh rate vật lý
%hook CAWindowServerDisplay

- (BOOL)supportsVariableRefreshRate { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)supportsLowPowerRefreshRate { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)supportsArbitraryFrameRates { return isAODMasterEnabled() ? YES : %orig; }

- (float)refreshRate {
    if (isAODMasterEnabled() && gIsAODActive) {
        if (gHasActiveNotification) {
            return 50.0f;
        }
        return getCustomAODRefreshRate();
    }
    return %orig;
}

- (void)setRefreshRate:(float)rate {
    if (isAODMasterEnabled() && gIsAODActive) {
        float forced = gHasActiveNotification ? 50.0f : getCustomAODRefreshRate();
        %orig(forced);
        return;
    }
    %orig(rate);
}

- (id)modeWithName:(id)arg1 {
    id mode = %orig;
    if (isAODMasterEnabled() && !mode) {
        return [self currentMode];
    }
    return mode;
}

%end

// 2.2 Cưỡng bức CADisplay khóa cứng dải tần số quét
%hook CADisplay

- (CAFrameRateRange)preferredFrameRateRange {
    if (isAODMasterEnabled() && gIsAODActive) {
        if (gHasActiveNotification) {
            return CAFrameRateRangeMake(50.0f, 50.0f, 50.0f);
        }
        float targetHz = getCustomAODRefreshRate();
        return CAFrameRateRangeMake(targetHz, targetHz, targetHz);
    }
    return %orig;
}

- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if (isAODMasterEnabled() && gIsAODActive) {
        if (gHasActiveNotification) {
            %orig(CAFrameRateRangeMake(50.0f, 50.0f, 50.0f));
        } else {
            float targetHz = getCustomAODRefreshRate();
            %orig(CAFrameRateRangeMake(targetHz, targetHz, targetHz));
        }
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

%end

// 2.3 Triệt tiêu toàn bộ cơ chế Watchdog Blanking dập đen màn hình của backboardd
%hook BKDisplayRenderOverlay
- (BOOL)disablesDisplayBlanking { return isAODMasterEnabled() ? YES : %orig; }
%end

%hook BKDisplayManager
- (void)setBlanked:(BOOL)blanked withReason:(id)reason {
    if (isAODMasterEnabled() && blanked) {
        %orig(NO, reason);
        return;
    }
    %orig(blanked, reason);
}
%end

%hook BLSHBacklightStateMachine
- (long long)backlightState {
    long long state = %orig;
    if (isAODMasterEnabled() && state == 0) {
        gIsAODActive = YES;
        return 2; // Ép giữ State 2 (BLSBacklightStateAlwaysOn)
    }
    if (state != 2 && state != 0) {
        // Thoát AOD: Tắt cờ và hoàn trả quyền kiểm soát xung nhịp về cho OS
        gIsAODActive = NO;
        gHasActiveNotification = NO;
    }
    return state;
}
- (BOOL)isAlwaysOnSuppressed { return isAODMasterEnabled() ? NO : %orig; }
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
// TẦNG 3: SPRINGBOARD (HẠ ĐỘ SÁNG CỰC TIỂU & BẮT THÔNG BÁO)
//==============================================================
%group Group_SpringBoard

%hook CSCoverSheetViewController
- (BOOL)isAlwaysOnPresentation { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)shouldDimForAlwaysOn { return isAODMasterEnabled() ? YES : %orig; }
%end

%hook SBLockScreenManager
- (BOOL)shouldPreventBacklightBlankingForAlwaysOn { return isAODMasterEnabled() ? YES : %orig; }
- (void)lockUIFromSource:(int)source withOptions:(id)options {
    %orig;
    if (isAODMasterEnabled()) {
        gIsAODActive = YES;
    }
}
- (void)unlockUIFromSource:(int)source withOptions:(id)options {
    %orig;
    // Mở khóa màn hình: Thoát ngay khỏi AOD và trả quyền cho OS
    gIsAODActive = NO;
    gHasActiveNotification = NO;
}
%end

// Bắt thông báo đến tầng SpringBoard để bung xung nhịp 50Hz
%hook SBNCNotificationDispatcher
- (void)_postNotificationRequest:(id)request {
    %orig;
    if (gIsAODActive) {
        TriggerNotificationBoost();
    }
}
%end

%hook NCNotificationDispatcher
- (void)postNotificationWithRequest:(id)request {
    %orig;
    if (gIsAODActive) {
        TriggerNotificationBoost();
    }
}
%end

// Cưỡng chế hạ độ sáng màn hình theo thanh trượt cài đặt
%hook SBBacklightController
- (void)animateBacklightToFactor:(float)factor duration:(double)duration source:(long long)source completion:(id)completion {
    if (isAODMasterEnabled()) {
        if (factor <= 0.05f) {
            gIsAODActive = YES;
            // Áp dụng mức độ sáng siêu thấp từ thanh trượt cài đặt
            factor = getCustomAODBrightnessFactor();
        } else {
            gIsAODActive = NO;
            gHasActiveNotification = NO;
        }
    }
    %orig(factor, duration, source, completion);
}
%end

// Chống treo luồng mạng APNs khi hệ thống vào chế độ tiết kiệm pin
%hook ProcessControl
- (BOOL)hasBackgroundTasksSuspended {
    if (gIsAODActive) {
        return NO;
    }
    return %orig;
}
%end

%end // Group_SpringBoard


//==============================================================
// TẦNG 4: POSTERBOARD (RENDER LAYER & SHADERS)
//==============================================================
%group Group_PosterBoard

%hook PRRenderingBacklightEnvironment
- (BOOL)supportsAlwaysOn { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnActive { return isAODMasterEnabled() ? YES : %orig; }
%end

%hook PRPosterEnvironmentImpl
- (long long)backlightLuminance {
    if (isAODMasterEnabled()) return 1; // 1: Mức mờ tối gốc của AOD
    return %orig;
}
%end

%end // Group_PosterBoard


//==============================================================
// TẦNG 5: GIAO DIỆN CÀI ĐẶT (PREFERENCES GỐC & THANH TRƯỢT TÙY CHỈNH)
//==============================================================
%group Group_Preferences

%hook BLSBacklight
+ (BOOL)isAlwaysOnEnabledByHardware { return isAODMasterEnabled() ? YES : %orig; }
%end

%hook BLSAlwaysOnFrequencyConfiguration
- (BOOL)isAlwaysOnEnabled { return isAODMasterEnabled() ? YES : %orig; }
%end

%hook CBDisplayModule
- (BOOL)isAlwaysOnDisplaySupported { return isAODMasterEnabled() ? YES : %orig; }
%end

// 5.1 Ép mục "Màn hình luôn bật" xuất hiện trong Cài đặt -> Màn hình & Độ sáng
%hook DBRDisplayController
- (BOOL)shouldShowAlwaysOnDisplay { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)shouldShowAlwaysOnDisplaySpecifier { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnDisplaySupported { return isAODMasterEnabled() ? YES : %orig; }

- (id)specifiers {
    NSMutableArray *specs = %orig;
    if (!isAODMasterEnabled()) return specs;

    static NSString *const kAODID = @"ALWAYS_ON_DISPLAY";
    BOOL exists = NO;
    for (PSSpecifier *s in specs) {
        if ([[s propertyForKey:@"id"] isEqualToString:kAODID]) {
            exists = YES;
            break;
        }
    }

    if (!exists) {
        Class detailClass = NSClassFromString(@"DBRAlwaysOnDisplayDetailController") ?: NSClassFromString(@"DBRAlwaysOnDisplayController");
        PSSpecifier *aodSpec = [%c(PSSpecifier) preferenceSpecifierNamed:@"Màn hình luôn bật"
                                                                  target:self
                                                                     set:NULL
                                                                     get:NULL
                                                                  detail:detailClass
                                                                    cell:2 // PSLinkCell
                                                                    edit:Nil];
        [aodSpec setProperty:kAODID forKey:@"id"];
        [aodSpec setProperty:@"DBRAlwaysOnDisplayDetailController" forKey:@"detail"];

        NSInteger insertIdx = -1;
        for (NSInteger i = 0; i < specs.count; i++) {
            if ([[[specs objectAtIndex:i] propertyForKey:@"id"] isEqualToString:@"AUTOLOCK"]) {
                insertIdx = i + 1;
                break;
            }
        }
        if (insertIdx >= 0 && insertIdx <= specs.count) {
            [specs insertObject:aodSpec atIndex:insertIdx];
        } else {
            [specs addObject:aodSpec];
        }
    }
    return specs;
}
%end

// 5.2 Nạp toàn bộ công cụ và thanh trượt vào trang con AOD của Cài đặt
%hook DBRAlwaysOnDisplayDetailController
- (BOOL)shouldShowAlwaysOnDisplaySpecifiers { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)isAlwaysOnDisplayEnabled { return isAODMasterEnabled() ? YES : %orig; }

- (id)specifiers {
    NSMutableArray *specs = %orig;
    static NSString *const kAODHzID = @"AOD_CUSTOM_HZ_KEY";

    BOOL exists = NO;
    for (PSSpecifier *s in specs) {
        if ([[s propertyForKey:@"id"] isEqualToString:kAODHzID]) {
            exists = YES;
            break;
        }
    }

    if (!exists) {
        PSSpecifier *group = [%c(PSSpecifier) preferenceSpecifierNamed:@"GIỚI HẠN PHẦN CỨNG AOD (2-20)"
                                                               target:self set:NULL get:NULL detail:Nil cell:0 edit:Nil];
        [group setProperty:@"Ép phần cứng hạ tần số quét và độ sáng xuống tầng thấp nhất khi khóa màn hình." forKey:@"footerText"];

        // Thanh trượt tần số quét (2 - 20 Hz)
        PSSpecifier *hzSlider = [%c(PSSpecifier) preferenceSpecifierNamed:@"Tần số quét (2-20 Hz)"
                                                                   target:self
                                                                      set:@selector(setCustomHz:spec:)
                                                                      get:@selector(getCustomHz:)
                                                                   detail:Nil cell:5 edit:Nil]; // 5: PSSliderCell
        [hzSlider setProperty:kAODHzID forKey:@"id"];
        [hzSlider setProperty:@(2.0f) forKey:@"min"];
        [hzSlider setProperty:@(20.0f) forKey:@"max"];
        [hzSlider setProperty:@YES forKey:@"showValue"];

        // Thanh trượt độ sáng cực thấp (2 - 20)
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

- (id)alwaysOnDisplayEnabled:(PSSpecifier *)specifier { return @(isAODMasterEnabled()); }
- (void)setAlwaysOnDisplayEnabled:(id)value specifier:(PSSpecifier *)specifier {
    CFPreferencesSetAppValue(CFSTR("AlwaysOnDisplayEnabled"), (__bridge CFPropertyListRef)(value), CFSTR("com.apple.BacklightServices"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.BacklightServices"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.apple.BacklightServices.AlwaysOnDisplayEnabled.changed"), NULL, NULL, YES);
}

- (id)showWallpaperEnabled:(PSSpecifier *)specifier {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(CFSTR("ShowWallpaperInAlwaysOn"), CFSTR("com.apple.BacklightServices"), &valid);
    return valid ? @(val) : @YES;
}
- (void)setShowWallpaperEnabled:(id)value specifier:(PSSpecifier *)specifier {
    CFPreferencesSetAppValue(CFSTR("ShowWallpaperInAlwaysOn"), (__bridge CFPropertyListRef)(value), CFSTR("com.apple.BacklightServices"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.BacklightServices"));
}

- (id)showNotificationsEnabled:(PSSpecifier *)specifier {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(CFSTR("ShowNotificationsInAlwaysOn"), CFSTR("com.apple.BacklightServices"), &valid);
    return valid ? @(val) : @YES;
}
- (void)setShowNotificationsEnabled:(id)value specifier:(PSSpecifier *)specifier {
    CFPreferencesSetAppValue(CFSTR("ShowNotificationsInAlwaysOn"), (__bridge CFPropertyListRef)(value), CFSTR("com.apple.BacklightServices"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.BacklightServices"));
}
%end

%end // Group_Preferences


//==============================================================
// CONSTRUCTOR: KHỞI TẠO TẬN TIẾN TRÌNH THEO NHÓM
//==============================================================
%ctor {
    @autoreleasepool {
        NSString *processName = [[NSProcessInfo processInfo] processName];
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

        if ([bundleID isEqualToString:@"com.apple.Preferences"]) {
            %init(Group_Preferences);
        } else if ([bundleID isEqualToString:@"com.apple.springboard"]) {
            %init(Group_SpringBoard);
        } else if ([bundleID isEqualToString:@"com.apple.PosterBoard"]) {
            %init(Group_PosterBoard);
        } else if ([processName isEqualToString:@"backboardd"]) {
            %init(Group_Backboardd);
        }
    }
}
