// The quicklink screens: Search Quicklinks, Create and Edit Quicklink, a quicklink as a row
// with its actions, and the list of a quicklink's sub-links.
#import "picker.h"

NS_ASSUME_NONNULL_BEGIN

DKPage *DKQuicklinksPage(DKPicker *picker);
/// Create Quicklink, or Edit Quicklink for `existing`.
DKForm *DKQuicklinkForm(DKPicker *picker, NSDictionary *_Nullable existing);
/// Opening, copying, editing and deleting the quicklink. Opening one with sub-links lists them.
DKItem *DKQuicklinkItem(DKPicker *picker, NSDictionary *quicklink);

NS_ASSUME_NONNULL_END
