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
            _specifiers = [NSMutableArray array];
        }
    }
    return _specifiers;
}

- (void)respring {
    // 1. Thử gửi tín hiệu respring thông qua killall (Hỗ trợ cả rootless và rootful)
    pid_t pid;
    const char *args[] = {"killall", "-9", "SpringBoard", NULL};
    
    // Kiểm tra đường dẫn killall của Rootless trước, sau đó fallback về standard path
    const char *paths[] = {
        "/var/jb/usr/bin/killall",
        "/usr/bin/killall",
        "/var/jb/bin/killall",
        "/bin/killall"
    };
    
    int spawned = -1;
    for (int i = 0; i < 4; i++) {
        if (access(paths[i], X_OK) == 0) {
            spawned = posix_spawn(&pid, paths[i], NULL, NULL, (char *const *)args, NULL);
            if (spawned == 0) {
                int status;
                waitpid(pid, &status, 0);
                return;
            }
        }
    }
    
    // 2. Fallback an toàn: Respring qua lệnh hệ thống của FrontBoard/SpringBoardServices
    // TUYỆT ĐỐI KHÔNG kill(1, SIGKILL) vì sẽ gây Panic / sập nguồn máy
    system("killall -9 SpringBoard");
}

@end
