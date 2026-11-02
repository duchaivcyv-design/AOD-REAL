#import "AODREALRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <spawn.h>
#import <signal.h>
#import <sys/wait.h>
#import <unistd.h>

// Khai báo hàm C API respring của FrontBoardServices (an toàn, chuẩn của Apple)
extern void FBSSystemServiceRespring(void);

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
// ĐỌC / GHI CẤU HÌNH CHO SWITCH & SLIDERS (ĐỒNG BỘ COM.JB.AODREAL)
//==============================================================

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSString *domain = [specifier propertyForKey:@"defaults"] ?: @"com.jb.aodreal";
    
    CFPropertyListRef val = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)domain);
    if (val) {
        return (__bridge_transfer id)val;
    }
    return [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSString *domain = [specifier propertyForKey:@"defaults"] ?: @"com.jb.aodreal";
    
    CFPreferencesSetAppValue(
        (__bridge CFStringRef)key,
        (__bridge CFPropertyListRef)value,
        (__bridge CFStringRef)domain
    );
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    
    // Phát thông báo Darwin để Tweak.xm cập nhật ngay lập tức
    NSString *postNotification = [specifier propertyForKey:@"PostNotification"];
    if (postNotification) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)postNotification,
            NULL,
            NULL,
            YES
        );
    }
}

//==============================================================
// XỬ LÝ RESPRING ĐA TẦNG AN TOÀN
//==============================================================

- (void)respring {
    // Cách 1: Gọi trực tiếp API C FBSSystemServiceRespring nếu symbol tồn tại
    if (&FBSSystemServiceRespring != NULL) {
        FBSSystemServiceRespring();
        return;
    }

    // Cách 2: Gọi FrontBoardServices ObjC runtime (Tránh bị sandbox chặn)
    Class fbssClass = NSClassFromString(@"FBSSystemService");
    if (fbssClass && [fbssClass respondsToSelector:@selector(sharedService)]) {
        id service = [fbssClass performSelector:@selector(sharedService)];
        SEL respringSel = NSSelectorFromString(@"exitAndRelaunch:");
        if (service && [service respondsToSelector:respringSel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            // YES = Relaunch SpringBoard ngay sau khi exit
            [service performSelector:respringSel withObject:@(YES)];
            #pragma clang diagnostic pop
            return;
        }
    }

    // Cách 3: Thử dùng sbreload hoặc killall qua posix_spawn (Hỗ trợ rootless/rootful)
    pid_t pid;
    const char *argsReload[] = {"sbreload", NULL};
    const char *argsKill[] = {"killall", "-9", "SpringBoard", NULL};
    
    // Thử chạy sbreload trước (mượt hơn killall, có sẵn trên Dopamine/Palera1n)
    const char *sbreloadPaths[] = {
        "/var/jb/usr/bin/sbreload",
        "/usr/bin/sbreload"
    };
    for (int i = 0; i < 2; i++) {
        if (access(sbreloadPaths[i], X_OK) == 0) {
            int ret = posix_spawn(&pid, sbreloadPaths[i], NULL, NULL, (char *const *)argsReload, NULL);
            if (ret == 0) {
                waitpid(pid, NULL, 0);
                return;
            }
        }
    }

    // Fallback: killall -9 SpringBoard
    const char *killallPaths[] = {
        "/var/jb/usr/bin/killall",
        "/usr/bin/killall",
        "/var/jb/bin/killall",
        "/bin/killall"
    };
    for (int i = 0; i < 4; i++) {
        if (access(killallPaths[i], X_OK) == 0) {
            int ret = posix_spawn(&pid, killallPaths[i], NULL, NULL, (char *const *)argsKill, NULL);
            if (ret == 0) {
                waitpid(pid, NULL, 0);
                return;
            }
        }
    }

    // Cách 4: Fallback hệ thống
    system("killall -9 SpringBoard");
}

@end
