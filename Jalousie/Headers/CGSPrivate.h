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
extern void CGSMoveWindowsToManagedSpace(CGSConnectionID cid, NSArray *windows, CGSSpaceID space);
extern void CGSHideSpaces(CGSConnectionID cid, NSArray *spaces);
extern void CGSShowSpaces(CGSConnectionID cid, NSArray *spaces);

#endif /* CGSPrivate_h */
