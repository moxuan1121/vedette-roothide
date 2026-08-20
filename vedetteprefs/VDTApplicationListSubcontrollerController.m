//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "VDTApplicationListSubcontrollerController.h"
#import "VDTProcessConfiguration.h"
#import "../PrivateHeaders.h"
#import "../VDTShared.h"
#import <objc/message.h>

static NSString *VDTApplicationDisplayName(LSApplicationProxy *proxy){
    NSBundle *bundle = [NSBundle bundleWithURL:proxy.bundleURL];
    NSString *displayName = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"];
    if (displayName.length == 0){
        displayName = [bundle objectForInfoDictionaryKey:@"CFBundleName"];
    }
    if (displayName.length == 0){
        displayName = proxy.bundleExecutable;
    }
    return displayName.length > 0 ? displayName : proxy.bundleIdentifier;
}

static UIImage *VDTApplicationIcon(NSString *bundleIdentifier){
    SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![UIImage respondsToSelector:selector]){
        return nil;
    }
    typedef UIImage *(*IconFunction)(id, SEL, NSString *, NSInteger, CGFloat);
    IconFunction iconFunction = (IconFunction)objc_msgSend;
    UIImage *icon = iconFunction(UIImage.class, selector, bundleIdentifier, 2, UIScreen.mainScreen.scale);
    return icon ?: iconFunction(UIImage.class, selector, bundleIdentifier, 0, UIScreen.mainScreen.scale);
}

@implementation VDTApplicationListSubcontrollerController

- (void)viewDidLoad{
    NSMutableArray *applications = [NSMutableArray array];
    NSMutableSet *seenIdentifiers = [NSMutableSet set];
    LSApplicationWorkspace *workspace = [objc_getClass("LSApplicationWorkspace") defaultWorkspace];
    for (LSApplicationProxy *proxy in [workspace allApplications]){
        if (proxy.bundleIdentifier.length == 0 || [seenIdentifiers containsObject:proxy.bundleIdentifier]){
            continue;
        }
        [seenIdentifiers addObject:proxy.bundleIdentifier];
        [applications addObject:proxy];
    }
    [applications sortUsingComparator:^NSComparisonResult(LSApplicationProxy *left, LSApplicationProxy *right) {
        return [VDTApplicationDisplayName(left) localizedCaseInsensitiveCompare:VDTApplicationDisplayName(right)];
    }];
    _applications = [applications copy];
    [self applySearchControllerHideWhileScrolling:YES];
    [super viewDidLoad];
}

- (NSString *)topTitle{
    return @"应用程序";
}

- (NSString *)plistName{
    return nil;
}

- (NSMutableArray *)specifiers{
    if (!_specifiers){
        NSMutableArray *specifiers = [NSMutableArray array];
        for (LSApplicationProxy *proxy in _applications){
            NSString *identifier = proxy.bundleIdentifier;
            NSString *displayName = VDTApplicationDisplayName(proxy);
            if (_searchKey.length > 0 &&
                ![displayName localizedStandardContainsString:_searchKey] &&
                ![identifier localizedStandardContainsString:_searchKey]){
                continue;
            }

            PSSpecifier *specifier = [PSSpecifier
                preferenceSpecifierNamed:displayName
                target:self
                set:nil
                get:@selector(previewStringForSpecifier:)
                detail:[VDTProcessConfiguration class]
                cell:PSLinkListCell
                edit:nil];
            [specifier setProperty:@(VDTConfigTypeApp) forKey:@"configurationType"];
            [specifier setProperty:identifier forKey:@"applicationIdentifier"];
            [specifier setProperty:@YES forKey:@"enabled"];
            UIImage *icon = VDTApplicationIcon(identifier);
            if (icon){
                [specifier setProperty:icon forKey:@"iconImage"];
            }
            [specifiers addObject:specifier];
        }
        _specifiers = specifiers;
    }
    self.navigationItem.title = [self topTitle];
    return _specifiers;
}

- (id)previewStringForSpecifier:(PSSpecifier *)specifier{
    NSString *identifier = [specifier propertyForKey:@"applicationIdentifier"];
    return [valueForProcessConfigKey(identifier, @"enabled", @NO, VDTConfigTypeApp) boolValue]
        ? @"已启用"
        : @"";
}

- (PSSpecifier *)specifierForApplicationWithIdentifier:(NSString *)applicationID{
    for (PSSpecifier *specifier in [self specifiers]){
        if ([[specifier propertyForKey:@"applicationIdentifier"] isEqualToString:applicationID]){
            return specifier;
        }
    }
    return nil;
}
@end
