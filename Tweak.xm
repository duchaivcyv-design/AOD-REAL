#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <substrate.h>

//==============================================================
// 0. KHAI BÁO CÁC LỚP VÀ HÀM CỦA APPLE (TỪ KẾT QUẢ QUÉT)
//==============================================================
typedef NS_ENUM(NSInteger, AODState) {
    AODStateIdle = 0,
    AODStateActive,
    AODStateProximityOff
};

static AODState gCurrentState = AODStateIdle;
static BOOL gSpringBoardDidFinishLaunching = NO;
static BOOL gIsSpringBoardProcess = NO;

static inline BOOL isAODMasterEnabled(void) { 
    if (gIsSpringBoardProcess && !gSpringBoardDidFinishLaunching) return NO;
    return YES; // ÉP BẬT CỨNG (Mặc định luôn bật)
}
static inline float getCustomAODRefreshRate(void) { return 1.0f; }
static inline float getAODPanelBrightnessFactor(void) { return 0.01f; }

// Khai báo các Interface nội bộ
@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)title target:(id)target set:(SEL)set get:(SEL)get detail:(Class)detail cell:(long long)cell edit:(Class)edit;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end
@interface PSListController : UIViewController
- (NSMutableArray *)specifiers;
- (void)reloadSpecifiers;
@end

// Class thật của Apple đã tìm thấy
@interface DBSAlwaysOnViewController : PSListController
- (BOOL)shouldShowAlwaysOn;
- (id)isAlwaysOnEnabled:(PSSpecifier *)specifier;
- (void)setAlwaysOnDisplayEnabled:(id)value specifier:(PSSpecifier *)specifier;
@end

@interface DBSMainDisplayPreferencesController : PSListController
- (PSSpecifier *)_alwaysOnDisplaySpecifier;
@end

@interface AlwaysOnBlockingPolicy : NSObject
- (BOOL)isActive;
@end
@interface AlwaysOnDisplayAction : NSObject @end
@interface AlwaysOnBrightnessCurveController : NSObject @end

@interface BLSHBacklightStateMachine : NSObject
- (long long)backlightState;
- (BOOL)isAlwaysOnEnabled;
- (BOOL)isAlwaysOnSuppressed;
@end
@interface BLSHAlwaysOnPresentationEngine : NSObject
- (BOOL)isSuppressed;
- (BOOL)isUsingPseudoFlipbook;
@end
@interface SBBacklightController : NSObject
+ (instancetype)sharedInstance;
- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion;
- (float)_factorToPublishForBacklightState:(long long)state;
@end
@interface SBLockScreenManager : NSObject
- (BOOL)shouldPreventBacklightBlankingForAlwaysOn;
- (void)unlockUIFromSource:(int)source withOptions:(id)options;
@end
@interface CSCoverSheetViewController : UIViewController
- (BOOL)isAlwaysOnPresentation;
@end
@interface CBController : NSObject - (void)setPowerState:(BOOL)state completion:(id)completion; @end
@interface CAWindowServerDisplay : NSObject
- (BOOL)blankingRemovesPower;
- (void)setBlankingRemovesPower:(BOOL)val;
@end
@interface BLSBacklight : NSObject + (BOOL)isAlwaysOnEnabledByHardware; @end
@interface CBDisplayModule : NSObject + (BOOL)isAlwaysOnDisplaySupported; @end

// MobileGestalt
static Boolean (*orig_MGGetBoolAnswer)(CFStringRef property) = NULL;
static Boolean replaced_MGGetBoolAnswer(CFStringRef property) {
    if (property) {
        NSString *key = (__bridge NSString *)property;
        if ([key isEqualToString:@"oPeik/9e8lQWMszEjbPzng"] || [key isEqualToString:@"AlwaysOnDisplaySupport"]) return YES;
    }
    return orig_MGGetBoolAnswer ? orig_MGGetBoolAnswer(property) : NO;
}

//==============================================================
// 1. TẦNG GIAO DIỆN: GỌI HÀM GỐC CỦA APPLE (KHÔNG TỰ VẼ)
//==============================================================
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
    
    // Quét xem Apple đã tự hiện ra chưa
    for (PSSpecifier *s in specs) {
        if ([[s propertyForKey:@"id"] containsString:@"ALWAYS_ON"]) return specs;
    }

    // GỌI HÀM GỐC CỦA APPLE ĐỂ LẤY SPECIFIER THẬT
    PSSpecifier *realSpec = nil;
    SEL sel = NSSelectorFromString(@"_alwaysOnDisplaySpecifier");
    if ([self respondsToSelector:sel]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        realSpec = [self performSelector:sel];
        #pragma clang diagnostic pop
    }
    
    if (realSpec) {
        [specs insertObject:realSpec atIndex:1]; // Chèn lên đầu
    }
    return specs;
}
%end

// ÉP CÁC CÔNG TẮC BÊN TRONG TRANG AOD GỐC
%hook DBSAlwaysOnViewController
- (BOOL)shouldShowAlwaysOn { return YES; }
- (id)isAlwaysOnEnabled:(PSSpecifier *)specifier { return @YES; }
- (void)setAlwaysOnDisplayEnabled:(id)value specifier:(PSSpecifier *)specifier {
    CFPreferencesSetAppValue(CFSTR("AlwaysOnDisplayEnabled"), (__bridge CFPropertyListRef)(value), CFSTR("com.apple.BacklightServices"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.BacklightServices"));
    [self reloadSpecifiers];
}
%end
%end // Group_Preferences

//==============================================================
// 2. TẦNG LÕI: GỠ BỎ CHẶN (POLICY) VÀ ÉP CHẠY AOD
//==============================================================
%group Group_Backboardd
%hook CBController
- (void)setPowerState:(BOOL)state completion:(id)completion {
    if (!state && gCurrentState != AODStateProximityOff) { %orig(YES, completion); return; }
    %orig(state, completion);
}
%end

%hook CAWindowServerDisplay
- (BOOL)blankingRemovesPower { if (gCurrentState == AODStateActive) return NO; return %orig; }
- (void)setBlankingRemovesPower:(BOOL)val { if (gCurrentState == AODStateActive) { %orig(NO); return; } %orig(val); }
%end

%hook BLSHBacklightStateMachine
- (BOOL)isAlwaysOnEnabled { return YES; }
- (BOOL)isAlwaysOnSuppressed { return (gCurrentState == AODStateProximityOff) ? YES : NO; }
- (long long)backlightState { long long s = %orig; if (s == 0 && gCurrentState != AODStateProximityOff) return 2; return s; }
%end

%hook BLSHAlwaysOnPresentationEngine
- (BOOL)isSuppressed { return (gCurrentState == AODStateProximityOff) ? YES : NO; }
- (BOOL)isUsingPseudoFlipbook { return YES; }
%end

// GỠ BỎ HOÀN TOÀN CHÍNH SÁCH CHẶN CỦA APPLE (Class vừa tìm thấy)
%hook AlwaysOnBlockingPolicy
- (BOOL)isActive { return NO; }
%end
%end // Group_Backboardd

//==============================================================
// 3. TẦNG SPRINGBOARD: BẮT SỰ KIỆN KHÓA MÁY ĐỂ HIỆN AOD
//==============================================================
%group Group_SpringBoard
%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application { %orig; gSpringBoardDidFinishLaunching = YES; }
%end
%hook CSCoverSheetViewController
- (BOOL)isAlwaysOnPresentation { return (gCurrentState == AODStateActive) ? YES : %orig; }
%end
%hook SBBacklightController
- (void)setBacklightState:(long long)state source:(long long)source animated:(BOOL)animated completion:(id)completion {
    if (state == 0 && gCurrentState != AODStateProximityOff) {
        gCurrentState = AODStateActive; state = 2;
    } else if (state == 1 || state == 3) { gCurrentState = AODStateIdle; }
    %orig(state, source, YES, completion);
}
- (float)_factorToPublishForBacklightState:(long long)state { if (gCurrentState == AODStateActive) return getAODPanelBrightnessFactor(); return %orig(state); }
%end
%hook SBLockScreenManager
- (BOOL)shouldPreventBacklightBlankingForAlwaysOn { return (gCurrentState == AODStateActive) ? YES : %orig; }
- (void)unlockUIFromSource:(int)source withOptions:(id)options { gCurrentState = AODStateIdle; %orig; }
%end
%end // Group_SpringBoard

//==============================================================
// 4. CONSTRUCTOR: NẠP VÀO CÁC TIẾN TRÌNH
//==============================================================
%ctor {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName];
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];

        if ([bid isEqualToString:@"com.apple.springboard"] || [proc isEqualToString:@"SpringBoard"]) {
            gIsSpringBoardProcess = YES;
            %init(Group_SpringBoard);
        } else if ([proc isEqualToString:@"backboardd"]) {
            %init(Group_Backboardd);
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
