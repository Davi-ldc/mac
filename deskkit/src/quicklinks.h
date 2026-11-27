// The user's quicklinks: names and links in quicklinks.plist, which can be edited by hand.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Each entry has "name" and "link", and when known "created", "updated" (dates),
/// "opened" (a count) and "sublinks". Read again only when the file has changed.
NSArray<NSDictionary *> *DKQuicklinks(void);
/// The choices a quicklink opens as a list in place of its link, each with "title", "url"
/// (a link as a quicklink's) and optionally "icon" (an image file). Entries a hand edit
/// left without a title or a link are skipped.
NSArray<NSDictionary *> *DKSublinks(NSDictionary *quicklink);
/// Adds a quicklink, or replaces the one called `oldName`, keeping its other fields.
void DKSaveQuicklink(NSString *_Nullable oldName, NSString *name, NSString *link, NSArray<NSDictionary *> *sublinks);
void DKDeleteQuicklink(NSString *name);
/// Where a link leads: a file URL for a folder path (starting with / or ~), otherwise a web
/// address, https:// when no scheme is given. Nil when the link is neither.
NSURL *_Nullable DKQuicklinkURL(NSString *link);
/// Opens the quicklink's link, or `sublink`'s, web addresses in Safari, and counts the visit.
void DKOpenQuicklink(NSDictionary *quicklink, NSDictionary *_Nullable sublink);
/// Opens a web address in Safari, whatever the default browser is; a folder in Finder.
void DKOpenURL(NSURL *url);

NS_ASSUME_NONNULL_END
