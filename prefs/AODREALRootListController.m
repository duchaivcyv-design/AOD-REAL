#import "AODREALRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <spawn.h>
#import <signal.h>
#import <sys/wait.h>
#import <unistd.h>
#import <dlfcn.h>

@implementation AODREALRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        if (!_specifiers) {
            _specifiers = [NSMutableArray array];
        }
    }
    return _specifiers;
}

//==============================================================
// ĐỌC / GHI CẤU HÌNH ĐỒNG BỘ HAI CHIỀU APPLE & TWEAK
//==============================================================

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return nil;
    
    NSString *domain = [specifier propertyForKey:@"defaults"] ?: @"com.jb.aodreal";
    
    CFPropertyListRef val = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)domain);
    if (!val && [domain isEqualToString:@"com.jb.aodreal"]) {
        // Fallback đọc từ domain Apple nếu domain tweak chưa có
        val = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("com.apple.BacklightServices"));
    }
    
    if (val) {
        return (__bridge_transfer id)val;
    }
    return [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return;
    
    NSString *domain = [specifier propertyForKey:@"defaults"] ?: @"com.jb.aodreal";
    
    // Ép kiểu chuẩn số thực (hỗ trợ nấc 0.5, 1, 5, 10, 15, 20 và Hz 2, 5, 10, 15, 20)
    id finalValue = value;
    if ([key isEqualToString:@"CustomAODRefreshRate"] || 
        [key isEqualToString:@"CustomAODBrightness"]) {
        if ([value isKindOfClass:[NSString class]]) {
            finalValue = @([value floatValue]);
        } else if ([value isKindOfClass:[NSNumber class]]) {
            finalValue = value;
        }
    }
    
    // 1. Ghi vào domain chỉ định
    CFPreferencesSetAppValue(
        (__bridge CFStringRef)key,
        (__bridge CFPropertyListRef)finalValue,
        (__bridge CFStringRef)domain
    );
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    
    // 2. Đồng bộ chéo sang Apple BacklightServices nếu là các công tắc hệ thống
    if ([key isEqualToString:@"enabled"]) {
        CFPreferencesSetAppValue(CFSTR("AlwaysOnDisplayEnabled"), (__bridge CFPropertyListRef)finalValue, CFSTR("com.apple.BacklightServices"));
        CFPreferencesSetAppValue(CFSTR("enabled"), (__bridge CFPropertyListRef)finalValue, CFSTR("com.apple.BacklightServices"));
        CFPreferencesAppSynchronize(CFSTR("com.apple.BacklightServices"));
    } else if ([key isEqualToString:@"ShowWallpaperInAlwaysOn"] || [key isEqualToString:@"BlurWallpaperInAlwaysOn"]) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)finalValue, CFSTR("com.apple.BacklightServices"));
        CFPreferencesAppSynchronize(CFSTR("com.apple.BacklightServices"));
    }
    
    // 3. Phát thông báo Darwin để Tweak.xm cập nhật ngay lập tức không cần Respring
    NSString *postNotification = [specifier propertyForKey:@"PostNotification"] ?: @"com.jb.aodreal/preferences.changed";
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)postNotification,
        NULL,
        NULL,
        YES
    );
}

//==============================================================
// XỬ LÝ RESPRING TOÀN DIỆN (SPRINGBOARD + BACKBOARDD CHO AOD)
//==============================================================

- (void)respring {
    pid_t pid;
    
    // Danh sách đường dẫn binary trên rootless iOS 16
    const char *sbreloadPaths[] = {
        "/var/jb/usr/bin/sbreload",
        "/usr/bin/sbreload"
    };
    
    const char *killallPaths[] = {
        "/var/jb/usr/bin/killall",
        "/usr/bin/killall",
        "/var/jb/bin/killall",
        "/bin/killall"
    };

    // Cách 1: Gọi killall diệt cả backboardd và SpringBoard để giải phóng Flipbook buffer
    const char *argsKillBoth[] = {"killall", "-9", "backboardd", "SpringBoard", NULL};
    for (int i = 0; i < 4; i++) {
        if (access(killallPaths[i], X_OK) == 0) {
            int ret = posix_spawn(&pid, killallPaths[i], NULL, NULL, (char *const *)argsKillBoth, NULL);
            if (ret == 0) {
                waitpid(pid, NULL, 0);
                return;
            }
        }
    }

    // Cách 2: Gọi sbreload nếu có
    const char *argsReload[] = {"sbreload", NULL};
    for (int i = 0; i < 2; i++) {
        if (access(sbreloadPaths[i], X_OK) == 0) {
            int ret = posix_spawn(&pid, sbreloadPaths[i], NULL, NULL, (char *const *)argsReload, NULL);
            if (ret == 0) {
                waitpid(pid, NULL, 0);
                return;
            }
        }
    }

    // Cách 3: FrontBoardServices API
    Class fbssClass = NSClassFromString(@"FBSSystemService");
    if (fbssClass && [fbssClass respondsToSelector:@selector(sharedService)]) {
        id service = [fbssClass performSelector:@selector(sharedService)];
        SEL respringSel = NSSelectorFromString(@"exitAndRelaunch:");
        if (service && [service respondsToSelector:respringSel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [service performSelector:respringSel withObject:@(YES)];
            #pragma clang diagnostic pop
            return;
        }
    }

    // Cách 4: Fallback Darwin Notification
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.apple.springboard.relaunch"),
        NULL,
        NULL,
        YES
    );
}

@end
