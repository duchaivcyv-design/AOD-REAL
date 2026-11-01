#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAFrameRateRange.h>

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
- (id)modeWithName:(id)arg1;
@end

@interface CADisplay : NSObject
- (CAFrameRateRange)preferredFrameRateRange;
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range;
@end

//==============================================================
// BIẾN TOÀN CỤC
//==============================================================
static BOOL gIsAODActive = NO;
static BOOL gHasActiveNotification = NO;

static BOOL isAODMasterEnabled(void) {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(
        CFSTR("enabled"),
        CFSTR("com.jb.aodreal"),   // ← sửa domain
        &valid
    );
    if (!valid) return NO;
    return (BOOL)val;
}

static void TriggerNotificationBoost(void) {
    gHasActiveNotification = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gHasActiveNotification = NO;
    });
}

//==============================================================
// NHÓM 1: GIAO DIỆN CÀI ĐẶT
//==============================================================
%group Group_Preferences

%hook BLSBacklight
+ (BOOL)isAlwaysOnEnabledByHardware {
    return isAODMasterEnabled() ? YES : %orig;
}
%end

%hook BLSAlwaysOnFrequencyConfiguration
- (BOOL)isAlwaysOnEnabled {
    return isAODMasterEnabled() ? YES : %orig;
}
%end

%hook CBDisplayModule
- (BOOL)isAlwaysOnDisplaySupported {
    return isAODMasterEnabled() ? YES : %orig;
}
%end

%hook DBRDisplayController
- (BOOL)shouldShowAlwaysOnDisplay {
    return isAODMasterEnabled() ? YES : %orig;
}
- (BOOL)shouldShowAlwaysOnDisplaySpecifier {
    return isAODMasterEnabled() ? YES : %orig;
}
- (BOOL)isAlwaysOnDisplaySupported {
    return isAODMasterEnabled() ? YES : %orig;
}

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
        Class detailClass = NSClassFromString(@"DBRAlwaysOnDisplayDetailController");
        if (!detailClass) {
            detailClass = NSClassFromString(@"DBRAlwaysOnDisplayController");
        }
        
        PSSpecifier *aodSpec = [%c(PSSpecifier) preferenceSpecifierNamed:@"Màn hình luôn bật"
                                                                  target:self
                                                                     set:NULL
                                                                     get:NULL
                                                                  detail:detailClass
                                                                    cell:2
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

%hook DBRAlwaysOnDisplayDetailController
- (BOOL)shouldShowAlwaysOnDisplaySpecifiers {
    return isAODMasterEnabled() ? YES : %orig;
}
- (BOOL)isAlwaysOnDisplayEnabled {
    return isAODMasterEnabled() ? YES : %orig;
}

- (id)alwaysOnDisplayEnabled:(PSSpecifier *)specifier {
    return @(isAODMasterEnabled());
}

- (void)setAlwaysOnDisplayEnabled:(id)value specifier:(PSSpecifier *)specifier {
    CFPreferencesSetAppValue(CFSTR("AlwaysOnDisplayEnabled"),
        (__bridge CFPropertyListRef)(value),
        CFSTR("com.apple.BacklightServices"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.BacklightServices"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.apple.BacklightServices.AlwaysOnDisplayEnabled.changed"),
        NULL, NULL, YES);
}

- (id)showWallpaperEnabled:(PSSpecifier *)specifier {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(
        CFSTR("ShowWallpaperInAlwaysOn"),
        CFSTR("com.apple.BacklightServices"), &valid);
    return valid ? @(val) : @YES;
}

- (void)setShowWallpaperEnabled:(id)value specifier:(PSSpecifier *)specifier {
    CFPreferencesSetAppValue(CFSTR("ShowWallpaperInAlwaysOn"),
        (__bridge CFPropertyListRef)(value),
        CFSTR("com.apple.BacklightServices"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.BacklightServices"));
}

- (id)showNotificationsEnabled:(PSSpecifier *)specifier {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(
        CFSTR("ShowNotificationsInAlwaysOn"),
        CFSTR("com.apple.BacklightServices"), &valid);
    return valid ? @(val) : @YES;
}

- (void)setShowNotificationsEnabled:(id)value specifier:(PSSpecifier *)specifier {
    CFPreferencesSetAppValue(CFSTR("ShowNotificationsInAlwaysOn"),
        (__bridge CFPropertyListRef)(value),
        CFSTR("com.apple.BacklightServices"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.BacklightServices"));
}
%end

%end // Group_Preferences


//==============================================================
// NHÓM 2: BACKBOARDD
//==============================================================
%group Group_Backboardd

%hook BKDisplayRenderOverlay
- (BOOL)disablesDisplayBlanking {
    return isAODMasterEnabled() ? YES : %orig;
}
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
        return 2;
    }
    if (state != 2 && state != 0) {
        gIsAODActive = NO;
        gHasActiveNotification = NO;
    }
    return state;
}
- (BOOL)isAlwaysOnSuppressed {
    return isAODMasterEnabled() ? NO : %orig;
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

%hook CAWindowServerDisplay
- (BOOL)supportsVariableRefreshRate { return isAODMasterEnabled() ? YES : %orig; }
- (BOOL)supportsLowPowerRefreshRate { return isAODMasterEnabled() ? YES : %orig; }
- (id)modeWithName:(id)arg1 {
    id mode = %orig;
    if (isAODMasterEnabled() && !mode) {
        return [self currentMode];
    }
    return mode;
}
%end

// Hook setter thay vì getter — renderer đọc setter
%hook CADisplay
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if (isAODMasterEnabled() && gIsAODActive) {
        if (gHasActiveNotification) {
            %orig(CAFrameRateRangeMake(50.0f, 50.0f, 50.0f));
        } else {
            %orig(CAFrameRateRangeMake(2.0f, 5.0f, 2.0f));
        }
        return;
    }
    %orig(range);
}
%end

%end // Group_Backboardd


//==============================================================
// NHÓM 3: SPRINGBOARD
//==============================================================
%group Group_SpringBoard

%hook CSCoverSheetViewController
- (BOOL)isAlwaysOnPresentation {
    return isAODMasterEnabled() ? YES : %orig;
}
- (BOOL)shouldDimForAlwaysOn {
    return isAODMasterEnabled() ? YES : %orig;
}
%end

%hook SBLockScreenManager
- (BOOL)shouldPreventBacklightBlankingForAlwaysOn {
    return isAODMasterEnabled() ? YES : %orig;
}
- (void)lockUIFromSource:(int)source withOptions:(id)options {
    %orig;
    if (isAODMasterEnabled()) {
        gIsAODActive = YES;
    }
}
- (void)unlockUIFromSource:(int)source withOptions:(id)options {
    %orig;
    gIsAODActive = NO;
    gHasActiveNotification = NO;
}
%end

// Bắt thông báo — kiểm tra lớp tồn tại trước khi hook
%hook SBNCNotificationDispatcher
- (void)_postNotificationRequest:(id)request {
    %orig;
    if (gIsAODActive) {
        TriggerNotificationBoost();
    }
}
%end

%hook SBBacklightController
- (void)animateBacklightToFactor:(float)factor duration:(double)duration source:(long long)source completion:(id)completion {
    if (isAODMasterEnabled()) {
        if (factor <= 0.05f) {
            gIsAODActive = YES;
            factor = 0.015f;
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
// NHÓM 4: POSTERBOARD
//==============================================================
%group Group_PosterBoard

%hook PRRenderingBacklightEnvironment
- (BOOL)supportsAlwaysOn {
    return isAODMasterEnabled() ? YES : %orig;
}
- (BOOL)isAlwaysOnActive {
    return isAODMasterEnabled() ? YES : %orig;
}
%end

%hook PRPosterEnvironmentImpl
- (long long)backlightLuminance {
    if (isAODMasterEnabled()) return 1;
    return %orig;
}
%end

%end // Group_PosterBoard


//==============================================================
// CONSTRUCTOR
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
