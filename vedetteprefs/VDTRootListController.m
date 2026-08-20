//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "VDTRootListController.h"
#import "../VDTShared.h"
#import "PrivateHeaders.h"

@implementation VDTRootListController

- (NSArray *)specifiers{
    if (!_specifiers){
        NSMutableArray *specifiers = [NSMutableArray array];

        PSSpecifier *mainGroup = [PSSpecifier
            preferenceSpecifierNamed:@"Vedette"
            target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [mainGroup setProperty:
            @"轻量 CPU 超限终止工具。关闭总开关后会立即停止所有 Vedette CPU 采样。"
            forKey:@"footerText"];
        [specifiers addObject:mainGroup];

        PSSpecifier *enabled = [PSSpecifier
            preferenceSpecifierNamed:@"总开关"
            target:self
            set:@selector(setPreferenceValue:specifier:)
            get:@selector(readPreferenceValue:)
            detail:nil cell:PSSwitchCell edit:nil];
        [enabled setProperty:@"enabled" forKey:@"key"];
        [enabled setProperty:@YES forKey:@"default"];
        [enabled setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];
        [enabled setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];
        [specifiers addObject:enabled];

        PSTextFieldSpecifier *sampleInterval = [PSTextFieldSpecifier
            preferenceSpecifierNamed:@"检测周期（毫秒）"
            target:self
            set:@selector(setPreferenceValue:specifier:)
            get:@selector(readPreferenceValue:)
            detail:nil cell:PSEditTextCell edit:nil];
        [sampleInterval setKeyboardType:UIKeyboardTypeNumberPad
                               autoCaps:UITextAutocapitalizationTypeNone
                         autoCorrection:UITextAutocorrectionTypeNo];
        [sampleInterval setPlaceholder:@"250"];
        [sampleInterval setProperty:@VDT_DEFAULT_SAMPLE_INTERVAL_MSEC forKey:@"default"];
        [sampleInterval setProperty:@"sampleIntervalMilliseconds" forKey:@"key"];
        [sampleInterval setProperty:VEDETTE_IDENTIFIER forKey:@"defaults"];
        [sampleInterval setProperty:PREFS_CHANGED_NN forKey:@"PostNotification"];
        [specifiers addObject:sampleInterval];

        PSSpecifier *intervalHelp = [PSSpecifier
            preferenceSpecifierNamed:nil
            target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [intervalHelp setProperty:
            @"允许手动输入 50～5000 毫秒，默认 250 毫秒。数值越小响应越快，但常驻 CPU 开销也越高；所有目标共用同一个检测周期。"
            forKey:@"footerText"];
        [specifiers addObject:intervalHelp];

        PSSpecifier *targetsGroup = [PSSpecifier
            preferenceSpecifierNamed:@"监控目标"
            target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [targetsGroup setProperty:
            @"监控第三方 App 前，还需要在 RootHide Bootstrap 的 App List 中允许该 App 注入 tweak。启用后请彻底退出并重新打开目标 App。"
            forKey:@"footerText"];
        [specifiers addObject:targetsGroup];

        PSSpecifier *applications = [PSSpecifier
            preferenceSpecifierNamed:@"应用程序"
            target:nil set:nil get:nil
            detail:NSClassFromString(@"VDTApplicationListSubcontrollerController")
            cell:PSLinkCell edit:nil];
        [specifiers addObject:applications];

        PSSpecifier *daemons = [PSSpecifier
            preferenceSpecifierNamed:@"系统进程"
            target:nil set:nil get:nil
            detail:NSClassFromString(@"CHPDaemonListController")
            cell:PSLinkCell edit:nil];
        [specifiers addObject:daemons];

        PSSpecifier *resetGroup = [PSSpecifier
            preferenceSpecifierNamed:@"维护"
            target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [resetGroup setProperty:@"清除全部 App 和系统进程监控配置。" forKey:@"footerText"];
        [specifiers addObject:resetGroup];

        PSSpecifier *reset = [PSSpecifier
            preferenceSpecifierNamed:@"恢复默认设置"
            target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        [reset setButtonAction:@selector(resetPreferences)];
        [specifiers addObject:reset];

        _specifiers = specifiers;
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier{
    return valueForKey([specifier propertyForKey:@"key"]) ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier{
    if ([[specifier propertyForKey:@"key"] isEqualToString:@"sampleIntervalMilliseconds"]){
        NSInteger milliseconds = [value integerValue];
        if (milliseconds < VDT_MIN_SAMPLE_INTERVAL_MSEC || milliseconds > VDT_MAX_SAMPLE_INTERVAL_MSEC){
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"检测周期无效"
                message:@"请输入 50 到 5000 之间的毫秒数。默认值为 250 毫秒。"
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            [self reloadSpecifier:specifier animated:YES];
            return;
        }
        value = @(milliseconds);
    }
    setValueForKey([specifier propertyForKey:@"key"], value);
}

- (void)resetPreferences{
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"恢复默认设置"
        message:@"确定要清除全部 Vedette 监控配置吗？"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel
        handler:nil]];
    [alert addAction:[UIAlertAction
        actionWithTitle:@"清除"
        style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) {
            [[NSFileManager defaultManager] removeItemAtPath:PREFS_PATH error:nil];
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                (CFStringRef)PREFS_CHANGED_NN,
                NULL, NULL, YES
            );
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                (CFStringRef)RESTORE_ALL_MONITORS_NN,
                NULL, NULL, YES
            );
            [self reloadSpecifiers];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
