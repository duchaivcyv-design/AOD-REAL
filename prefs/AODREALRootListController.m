#import <Preferences/PSListController.h>
#import <spawn.h>
#import <signal.h>

@interface AODREALRootListController : PSListController
@end

@implementation AODREALRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        if (!_specifiers) {
            // Fallback: nếu Root.plist không load được, tạo specifier tối thiểu
            _specifiers = [NSMutableArray array];
        }
    }
    return _specifiers;
}

- (void)respring {
    pid_t pid;
    const char *args[] = {"killall", "-9", "SpringBoard", NULL};
    int status = posix_spawn(&pid, "/usr/bin/killall", NULL, NULL,
                             (char *const *)args, NULL);
    if (status != 0) {
        // Fallback: dùng kill() nếu killall không có
        kill(1, SIGKILL); // PID 1 là launchd, nhưng SpringBoard thường là PID khác
    }
}

@end
