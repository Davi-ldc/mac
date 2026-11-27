// Typed reads from Slack's API JSON (NSJSONSerialization output). Each returns nil, 0 or NO when
// the key is missing or holds another type, so decoders never trust the server's shapes.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSString *_Nullable SNJSONString(id _Nullable object, NSString *key);
/// Strings are accepted too: Slack sends some counts and times as either.
NSInteger SNJSONInteger(id _Nullable object, NSString *key);
double SNJSONDouble(id _Nullable object, NSString *key);
BOOL SNJSONBool(id _Nullable object, NSString *key);
NSDictionary *_Nullable SNJSONObject(id _Nullable object, NSString *key);
NSArray *_Nullable SNJSONArray(id _Nullable object, NSString *key);
/// The array's strings, skipping anything else.
NSArray<NSString *> *SNJSONStrings(id _Nullable object, NSString *key);
/// Decodes each dictionary of the array with `decode`, dropping those it rejects.
NSArray *SNJSONMap(id _Nullable object, NSString *key, id _Nullable (^decode)(NSDictionary *item));
/// http(s) URL strings only.
NSURL *_Nullable SNJSONURL(id _Nullable object, NSString *key);
/// The URLs of keys "<prefix><pixels>" by size in pixels (thumb_360, image_72); thumb_360_w and
/// thumb_360_gif are not sizes.
NSDictionary<NSNumber *, NSURL *> *SNJSONSizedURLs(id _Nullable object, NSString *prefix);
/// `json` with `changes` laid over it; an NSNull value removes the key.
NSDictionary *SNJSONMerge(NSDictionary *json, NSDictionary *changes);

NS_ASSUME_NONNULL_END
