// Starting the app's pieces outside a normal launch: from a fixture folder, and the memory check.
#import <AppKit/AppKit.h>

#import "store/fixture.h"

NS_ASSUME_NONNULL_BEGIN

/// The fixture as the window's source: the UI takes its user's language and its images come
/// from the folder (nothing is fetched).
SNFixtureSource *_Nullable SNOpenFixture(NSURL *folder);

/// `--memory <fixture folder or cache .sqlite>`: builds the whole window from the fixture or from
/// a workspace's cache (as a signed-in launch would, without network), draws every layer as a
/// frame on screen would (without showing the window) and prints the time to the first frame and
/// the process's memory footprint.
int SNMeasureMemory(NSURL *fixture);

NS_ASSUME_NONNULL_END
