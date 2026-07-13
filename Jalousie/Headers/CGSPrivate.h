#ifndef CGSPrivate_h
#define CGSPrivate_h

#import <Foundation/Foundation.h>

// Private but stable Core Graphics Services symbols used by every macOS
// window manager. These are undocumented and not covered by the public SDK,
// but Apple has kept the signatures stable since 10.9. Declaring only the
// handful of functions we actually call keeps the surface area small.

typedef int CGSConnectionID;
typedef uint64_t CGSSpaceID;

typedef NS_ENUM(int, CGSSpaceType) {
    kCGSSpaceUser = 0,
    kCGSSpaceFullscreen = 1,
};

// Space-mask bits for CGSCopySpaces. 0x7 = all managed spaces (user + fullscreen
// on the current display); we filter/index into the result ourselves.
extern CGSConnectionID CGSMainConnectionID(void);
extern CGSSpaceID CGSGetActiveSpace(CGSConnectionID cid);
extern NSArray *CGSCopySpaces(CGSConnectionID cid, int mask);
extern CFArrayRef CGSCopySpacesForWindows(CGSConnectionID cid, int mask, CFArrayRef windowIDs);
extern void CGSMoveWindowsToManagedSpace(CGSConnectionID cid, NSArray *windows, CGSSpaceID space);
extern void CGSAddWindowsToSpaces(CGSConnectionID cid, NSArray *windows, NSArray *spaces);
extern void CGSRemoveWindowsFromSpaces(CGSConnectionID cid, NSArray *windows, NSArray *spaces);
extern void CGSHideSpaces(CGSConnectionID cid, NSArray *spaces);
extern void CGSShowSpaces(CGSConnectionID cid, NSArray *spaces);

// Returns the per-display space topology: an array of dictionaries, one per
// display, each with keys "Display Identifier" (CFUUID string) and "Spaces"
// (array of dicts each carrying an "id64" number). This is the only stable
// way to answer "give me the Nth space on the display I care about."
extern CFArrayRef CGSCopyManagedDisplaySpaces(CGSConnectionID cid);

// SkyLight (SLS) private APIs — resolved via dlsym at runtime in Swift
// (see SpaceManager) because the framework isn't in our public link path
// and the symbol set varies by macOS version. Kept out of the extern block
// so we don't hit link-time undefined errors.

#endif /* CGSPrivate_h */
