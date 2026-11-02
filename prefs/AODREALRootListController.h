#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface AODREALRootListController : PSListController

// Khai báo phương thức xử lý nút bấm Respring từ Root.plist
- (void)respring;

// Khai báo các hàm getter/setter tùy chỉnh cho specifier
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;

@end
