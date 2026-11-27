// Owns the tab pane registry.
#import "ui/shell/tabs.h"

static Class registered[SNTabAgents + 1];

void SNRegisterTabPane(SNTab tab, Class<SNTabPane> _Nullable paneClass) { registered[tab] = paneClass; }
Class<SNTabPane> SNRegisteredTabPane(SNTab tab) { return registered[tab]; }
