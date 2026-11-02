#import "AODREALRootListController.h"
#import <spawn.h>
#import <signal.h>
#import <sys/wait.h>
#import <unistd.h>

// Khai báo hàm respring của FrontBoardServices (private)
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

- (void)respring {
    // Cách 1: Thử dùng FBSSystemService (API private, an toàn nhất, không cần file system)
    Class fbssClass = NSClassFromString(@"FBSSystemService");
    if (fbssClass && [fbssClass respondsToSelector:@selector(sharedService)]) {
        id service = [fbssClass performSelector:@selector(sharedService)];
        SEL respringSel = NSSelectorFromString(@"openURL:withOptions:");
        NSURL *url = [NSURL URLWithString:@"prefs:root="];
        if (service && [service respondsToSelector:respringSel] && url) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [service performSelector:respringSel withObject:url withObject:@{}];
            #pragma clang diagnostic pop
            return;
        }
    }

    // Cách 2: Dùng posix_spawn với killall (hỗ trợ rootless/rootful)
    pid_t pid;
    const char *args[] = {"killall", "-9", "SpringBoard", NULL};
    const char *paths[] = {
        "/var/jb/usr/bin/killall",
        "/usr/bin/killall",
        "/var/jb/bin/killall",
        "/bin/killall"
    };

    for (int i = 0; i < 4; i++) {
        if (access(paths[i], X_OK) == 0) {
            int ret = posix_spawn(&pid, paths[i], NULL, NULL,
                                  (char *const *)args, NULL);
            if (ret == 0) {
                int status;
                waitpid(pid, &status, 0);
                return;
            }
        }
    }

    // Cách 3: Fallback cuối — gửi Darwin notification để SpringBoard tự respring
    // (một số tweak respring dùng cách này)
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.apple.springboard.respring"),
        NULL, NULL, YES
    );
}

@end
