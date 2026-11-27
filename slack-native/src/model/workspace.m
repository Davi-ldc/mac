// Owns decoding a workspace.
#import "model/json.h"
#import "model/workspace.h"

NSURL *SNBestURL(NSDictionary<NSNumber *, NSURL *> *urls, CGFloat pixels) {
    NSNumber *best = nil;
    for (NSNumber *size in urls) {
        BOOL fits = size.doubleValue >= pixels, bestFits = best.doubleValue >= pixels;
        if (!best || (fits && (!bestFits || size.doubleValue < best.doubleValue)) || (!fits && !bestFits && size.doubleValue > best.doubleValue))
            best = size;
    }
    return best ? urls[best] : nil;
}

@implementation SNWorkspace

+ (instancetype)workspaceWithJSON:(NSDictionary *)json {
    NSString *workspaceID = SNJSONString(json, @"id");
    if (!workspaceID.length) return nil;
    SNWorkspace *workspace = [self new];
    workspace->_json = [json copy];
    workspace->_workspaceID = workspaceID;
    workspace->_name = SNJSONString(json, @"name") ?: @"";
    workspace->_domain = SNJSONString(json, @"domain") ?: @"";
    workspace->_url = SNJSONURL(json, @"url");
    if (!workspace->_url && workspace->_domain.length)
        workspace->_url = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@.slack.com/", workspace->_domain]];
    workspace->_enterpriseID = SNJSONString(json, @"enterprise_id");
    workspace->_enterpriseName = SNJSONString(json, @"enterprise_name");
    NSDictionary *icon = SNJSONObject(json, @"icon");
    NSMutableDictionary *icons = [NSMutableDictionary new];
    for (NSString *key in icon) {
        NSInteger size = [key hasPrefix:@"image_"] ? [key substringFromIndex:6].integerValue : 0;
        NSURL *url = size ? SNJSONURL(icon, key) : nil;
        if (url) icons[@(size)] = url;
    }
    workspace->_iconURLs = icons;
    workspace->_iconIsDefault = SNJSONBool(icon, @"image_default");
    NSMutableArray *presets = [NSMutableArray new];
    for (NSArray *preset in SNJSONArray(SNJSONObject(json, @"prefs"), @"custom_status_presets")) {
        if (![preset isKindOfClass:NSArray.class] || preset.count < 4) continue;
        BOOL strings = YES;
        for (id part in [preset subarrayWithRange:NSMakeRange(0, 4)]) strings = strings && [part isKindOfClass:NSString.class];
        if (strings) [presets addObject:[preset subarrayWithRange:NSMakeRange(0, 4)]];
    }
    workspace->_statusPresets = presets;
    return workspace;
}

- (NSURL *)iconURLForPixels:(CGFloat)pixels { return SNBestURL(self.iconURLs, pixels); }
- (id)copyWithZone:(NSZone *)zone { return self; }

@end
