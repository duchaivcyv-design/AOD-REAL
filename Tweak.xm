#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

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

//==============================================================
// CÔNG TẮC TỔNG (MASTER SWITCH) — MẶC ĐỊNH TẮT
//==============================================================
static BOOL isAODMasterEnabled(void) {
    Boolean valid = false;
    Boolean val = CFPreferencesGetAppBooleanValue(
        CFSTR("enabled"),
        CFSTR("com.jb.aodreal"),
        &valid
    );
    if (!valid) return NO; // Mặc định TẮT lần đầu
    return (BOOL)val;
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
        return 2; // BLSBacklightStateAlwaysOn
    }
    return state;
}
- (BOOL)isAlwaysOnSuppressed {
    return isAODMasterEnabled() ? NO : %orig;
}
%end

%hook BLSHAlwaysOnPresentationEngine
- (BOOL)isAlwaysOnSupported {
    return isAODMasterEnabled() ? YES : %orig;
}
- (BOOL)isAlwaysOnActive {
    return isAODMasterEnabled() ? YES : %orig;
}
- (BOOL)isAlwaysOnEnabled {
    return isAODMasterEnabled() ? YES : %orig;
}
- (BOOL)isAlwaysOnSuppressed {
    return isAODMasterEnabled() ? NO : %orig;
}
%end

%hook BLSHAlwaysOnSuppressionAssertion
- (BOOL)isSuppressed {
    return isAODMasterEnabled() ? NO : %orig;
}
%end

%hook BLSHBacklightSceneHostEnvironment
- (BOOL)supportsAlwaysOn {
    return isAODMasterEnabled() ? YES : %orig;
}
- (BOOL)isAlwaysOnActive {
    return isAODMasterEnabled() ? YES : %orig;
}
- (long long)visualState {
    long long state = %orig;
    if (isAODMasterEnabled() && state == 0) return 2;
    return state;
}
- (BOOL)isClientActive {
    return isAODMasterEnabled() ? YES : %orig;
}
%end

%hook CAWindowServerDisplay
- (BOOL)supportsVariableRefreshRate {
    return isAODMasterEnabled() ? YES : %orig;
}
- (BOOL)supportsLowPowerRefreshRate {
    return isAODMasterEnabled() ? YES : %orig;
}
- (id)modeWithName:(id)arg1 {
    id mode = %orig;
    if (isAODMasterEnabled() && !mode) {
        return [self currentMode];
    }
    return mode;
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
%end

%hook SBBacklightController
- (void)animateBacklightToFactor:(float)factor duration:(double)duration source:(long long)source completion:(id)completion {
    if (isAODMasterEnabled() && factor <= 0.05f) {
        factor = 0.015f;
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
