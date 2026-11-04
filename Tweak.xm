#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <substrate.h>

//==============================================================
// KHAI BÁO CÁC LỚP HỆ THỐNG
//==============================================================
@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)title target:(id)target set:(SEL)set get:(SEL)get detail:(Class)detail cell:(long long)cell edit:(Class)edit;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end
@interface PSListController : UIViewController
- (NSMutableArray *)specifiers;
@end
@interface DBSAlwaysOnViewController : PSListController
- (BOOL)shouldShowAlwaysOn;
- (id)isAlwaysOnEnabled:(PSSpecifier *)specifier;
@end
@interface CAWindowServerDisplay : NSObject
- (BOOL)blankingRemovesPower; - (void)setBlankingRemovesPower:(BOOL)val;
@end
@interface CBController : NSObject
- (void)setPowerState:(BOOL)state completion:(id)completion;
@end
@interface SBBacklightController : NSObject
+ (instancetype)sharedInstance;
- (float)_factorToPublishForBacklightState:(long long)state;
- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion;
@end
@interface BLSHBacklightStateMachine : NSObject
- (BOOL)isAlwaysOnEnabled; - (BOOL)isAlwaysOnSuppressed; - (long long)backlightState;
@end
@interface BLSHAlwaysOnPresentationEngine : NSObject
- (BOOL)isSuppressed;
@end
@interface CSCoverSheetViewController : UIViewController
- (BOOL)isAlwaysOnPresentation; - (BOOL)shouldDimForAlwaysOn;
@end
@interface PaperBoardController : NSObject
- (void)setAlwaysOnDisplayDimmingView:(UIView *)view;
@end
@interface CLKDevice : NSObject
- (BOOL)supportsAlwaysOnDisplay;
@end
@interface CLKUIColoringView : UIView
- (void)setAlwaysOnDimmed:(BOOL)dimmed;
@end
@interface PRPosterEnvironmentImpl : NSObject
- (long long)luminance;
@end
@interface AlwaysOnBlockingPolicy : NSObject
- (BOOL)isActive;
@end
@interface SBLowPowerModeAlwaysOnPolicy : NSObject
- (BOOL)isAlwaysOnPolicyActive;
@end
@interface SBThermalAlwaysOnPolicy : NSObject
- (BOOL)isAlwaysOnPolicyActive;
@end
@interface SBFocusModeAlwaysOnPolicy : NSObject
- (BOOL)isAlwaysOnPolicyActive;
@end

//==============================================================
// TẦNG 1: MOBILEGESTALT (ĐÁNH LỪA PHẦN CỨNG)
//==============================================================
static Boolean (*orig_MGGetBoolAnswer)(CFStringRef property) = NULL;
static Boolean replaced_MGGetBoolAnswer(CFStringRef property) {
    if (property) {
        NSString *key = (__bridge NSString *)property;
        if ([key isEqualToString:@"oPeik/9e8lQWMszEjbPzng"] || [key isEqualToString:@"AlwaysOnDisplaySupport"] || [key isEqualToString:@"DeviceSupportsAlwaysOn"]) return YES;
    }
    return orig_MGGetBoolAnswer ? orig_MGGetBoolAnswer(property) : NO;
}

//==============================================================
// TẦNG 2: GỠ BỎ CHẶN (POLICY) & ÉP DRIVER (BACKBOARDD)
//==============================================================
%group Group_Backboardd
%hook AlwaysOnBlockingPolicy
- (BOOL)isActive { return NO; } // Vô hiệu hóa chặn
%end
%hook SBLowPowerModeAlwaysOnPolicy
- (BOOL)isAlwaysOnPolicyActive { return NO; }
%end
%hook SBThermalAlwaysOnPolicy
- (BOOL)isAlwaysOnPolicyActive { return NO; }
%end
%hook SBFocusModeAlwaysOnPolicy
- (BOOL)isAlwaysOnPolicyActive { return NO; }
%end

%hook CAWindowServerDisplay
- (BOOL)blankingRemovesPower { return NO; }
- (void)setBlankingRemovesPower:(BOOL)val { %orig(NO); }
%end
%hook CBController
- (void)setPowerState:(BOOL)state completion:(id)completion {
    if (!state) { %orig(YES, completion); return; } // Cấm tắt điện panel
    %orig(state, completion);
}
%end
%hook BLSHBacklightStateMachine
- (BOOL)isAlwaysOnEnabled { return YES; }
- (BOOL)isAlwaysOnSuppressed { return NO; }
- (long long)backlightState { return 2; }
%end
%hook BLSHAlwaysOnPresentationEngine
- (BOOL)isSuppressed { return NO; }
%end
%end

//==============================================================
// TẦNG 3: ÉP SPRINGBOARD HIỂN THỊ GIAO DIỆN AOD
//==============================================================
%group Group_SpringBoard
%hook CSCoverSheetViewController
- (BOOL)isAlwaysOnPresentation { return YES; }
- (BOOL)shouldDimForAlwaysOn { return YES; }
%end
%hook SBBacklightController
- (float)_factorToPublishForBacklightState:(long long)state { return 0.01f; } // Sáng 1%
- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion {
    if (state == 0) state = 2; // Khóa máy thành AOD
    %orig(state, source, YES, completion);
}
%end
%end

//==============================================================
// TẦNG 4: ÉP ĐỒ HỌA (PAPERBOARD & CLOCKANGEL)
//==============================================================
%group Group_PaperBoard
%hook PaperBoardController
- (void)setAlwaysOnDisplayDimmingView:(UIView *)view { %orig(view); view.hidden = NO; view.alpha = 1.0f; }
%end
%hook PRPosterEnvironmentImpl
- (long long)luminance { return 1; } // Ép độ sáng màn hình
%end
%end

%group Group_ClockAngel
%hook CLKDevice
- (BOOL)supportsAlwaysOnDisplay { return YES; }
%end
%hook CLKUIColoringView
- (void)setAlwaysOnDimmed:(BOOL)dimmed { %orig(YES); }
%end
%end

//==============================================================
// TẦNG 5: PREFERENCES (GỌI HÀM GỐC APPLE, CHÈN SPECIFIER THẬT)
//==============================================================
%group Group_Preferences
%hook PSListController
- (NSMutableArray *)specifiers {
    NSMutableArray *specs = %orig;
    if (!specs) return specs;
    
    NSString *className = NSStringFromClass([self class]);
    
    // Can thiệp vào trang Màn hình & Độ sáng (có thể tên là DBRDisplayController hoặc DBSMainDisplayPreferencesController)
    if ([className containsString:@"Display"] || [className containsString:@"Brightness"] || [className containsString:@"DBR"] || [className containsString:@"DBS"]) {
        
        // Kiểm tra xem đã chèn chưa
        for (PSSpecifier *s in specs) {
            if ([[s propertyForKey:@"id"] containsString:@"ALWAYS_ON"]) return specs;
        }

        // Gọi hàm gốc của Apple để tự tạo specifier
        PSSpecifier *realSpec = nil;
        SEL aodSel = NSSelectorFromString(@"_alwaysOnDisplaySpecifier");
        
        if ([self respondsToSelector:aodSel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            realSpec = [self performSelector:aodSel];
            #pragma clang diagnostic pop
        }

        // Nếu Apple trả về, chèn vào
        if (realSpec) {
            [specs insertObject:realSpec atIndex:1];
        }
    }
    return specs;
}
%end

%hook DBSAlwaysOnViewController
- (BOOL)shouldShowAlwaysOn { return YES; }
- (id)isAlwaysOnEnabled:(PSSpecifier *)specifier { return @YES; }
%end
%end

//==============================================================
// CONSTRUCTOR: KÍCH HOẠT THEO TIẾN TRÌNH
//==============================================================
%ctor {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName];
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];

        if ([bid isEqualToString:@"com.apple.Preferences"] || [proc.lowercaseString containsString:@"preferences"]) {
            // Hook MobileGestalt
            void *gestaltHandle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
            if (gestaltHandle) {
                void *mgFunc = dlsym(gestaltHandle, "MGGetBoolAnswer");
                if (mgFunc) MSHookFunction(mgFunc, (void *)replaced_MGGetBoolAnswer, (void **)&orig_MGGetBoolAnswer);
            }
            %init(Group_Preferences);
        } 
        else if ([bid isEqualToString:@"com.apple.springboard"] || [proc isEqualToString:@"SpringBoard"]) {
            %init(Group_SpringBoard);
        } 
        else if ([proc isEqualToString:@"backboardd"]) {
            %init(Group_Backboardd);
        }
        else if ([proc isEqualToString:@"PaperBoard"] || [bid containsString:@"paperboard"]) {
            %init(Group_PaperBoard);
        }
        else if ([proc isEqualToString:@"ClockAngel"] || [bid containsString:@"clockangel"]) {
            %init(Group_ClockAngel);
        }
    }
}
