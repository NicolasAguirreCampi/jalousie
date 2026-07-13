#ifndef SpaceBridge_h
#define SpaceBridge_h

#import <Foundation/Foundation.h>

// Send a single window to a target managed space using yabai's Tier-1
// mechanism: `SLSPerformAsynchronousBridgedWindowManagementOperation` +
// the private `SLSBridgedMoveWindowsToManagedSpaceOperation` class. All
// symbol lookups happen at runtime (dlsym / objc_getClass) so this
// gracefully returns NO on macOS versions that don't ship them.
BOOL JalousieBridgedSendWindowToSpace(uint32_t windowID, uint64_t spaceID);

#endif /* SpaceBridge_h */
