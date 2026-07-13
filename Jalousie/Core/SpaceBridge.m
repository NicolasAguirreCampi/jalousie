#import "SpaceBridge.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <string.h>

typedef void (*SLSPerformAsyncBridgedOp)(id operation);

// Yabai's Mach-O local-symbol resolver (ported verbatim from
// yabai/src/misc/macho_dlsym.h). Walks LC_SYMTAB entries in the loaded
// image to find symbols the export table hides. We need this because the
// perform function is a static-linkage C++ symbol that dlsym can't see.
static void *macho_find_symbol(const char *substring, const char *target_symbol)
{
    uint32_t image_count = _dyld_image_count();
    for (uint32_t i = 0; i < image_count; ++i) {
        const char *image_name = _dyld_get_image_name(i);
        if (!image_name || !strstr(image_name, substring)) continue;

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct mach_header_64 *header =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!header) continue;

        const struct segment_command_64 *linkedit = NULL;
        const struct symtab_command *symtab = NULL;
        uint64_t offset = sizeof(struct mach_header_64);
        for (uint32_t j = 0; j < header->ncmds; ++j) {
            const struct load_command *cmd =
                (const struct load_command *)(((const uint8_t *)header) + offset);
            if (cmd->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg =
                    (const struct segment_command_64 *)cmd;
                if (strcmp(seg->segname, SEG_LINKEDIT) == 0) linkedit = seg;
            } else if (cmd->cmd == LC_SYMTAB) {
                symtab = (const struct symtab_command *)cmd;
            }
            offset += cmd->cmdsize;
        }
        if (!linkedit || !symtab) continue;

        uintptr_t base = (uintptr_t)linkedit->vmaddr - linkedit->fileoff + slide;
        const char *strtab = (const char *)(base + symtab->stroff);
        const struct nlist_64 *nlist = (const struct nlist_64 *)(base + symtab->symoff);
        for (uint32_t k = 0; k < symtab->nsyms; ++k) {
            const char *name = strtab + nlist[k].n_un.n_strx;
            if (strcmp(name, target_symbol) == 0) {
                return (void *)(uintptr_t)(nlist[k].n_value + slide);
            }
        }
    }
    return NULL;
}

static SLSPerformAsyncBridgedOp resolvePerformer(void)
{
    static SLSPerformAsyncBridgedOp fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Try the exported name first (older macOS).
        fn = (SLSPerformAsyncBridgedOp)dlsym(
            RTLD_DEFAULT, "SLSPerformAsynchronousBridgedWindowManagementOperation");
        if (fn) return;
        // On macOS 26+ the symbol is present but not exported. Use yabai's
        // trick: walk the local symbol table of the SkyLight image and match
        // the C++-mangled internal name.
        fn = (SLSPerformAsyncBridgedOp)macho_find_symbol(
            "SkyLight.framework",
            "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation");
    });
    return fn;
}

BOOL JalousieBridgedSendWindowToSpace(uint32_t windowID, uint64_t spaceID)
{
    SLSPerformAsyncBridgedOp perform = resolvePerformer();
    if (!perform) {
        NSLog(@"[Jalousie] ⚠️ bridge: perform() symbol not found (dlsym + macho scan both failed)");
        return NO;
    }

    Class opClass = objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
    if (!opClass) {
        NSLog(@"[Jalousie] ⚠️ bridge: SLSBridgedMoveWindowsToManagedSpaceOperation class not found");
        return NO;
    }

    NSArray *windows = @[@(windowID)];
    id operation = nil;

    // macOS 26+ uses (spaceID, windows, options); pre-Tahoe used (windows, spaceID).
    // Try Tahoe first, then fall back.
    SEL tahoeSel = sel_registerName("initWithSpaceID:windows:options:");
    if ([opClass instancesRespondToSelector:tahoeSel]) {
        // options = 0 is what the exported wrapper passes.
        operation = ((id (*)(id, SEL, uint64_t, id, uint64_t))objc_msgSend)(
            [opClass alloc], tahoeSel, spaceID, windows, (uint64_t)0);
    }
    if (!operation) {
        SEL legacySel = sel_registerName("initWithWindows:spaceID:");
        if ([opClass instancesRespondToSelector:legacySel]) {
            operation = ((id (*)(id, SEL, id, uint64_t))objc_msgSend)(
                [opClass alloc], legacySel, windows, spaceID);
        }
    }
    if (!operation) {
        NSLog(@"[Jalousie] ⚠️ bridge: no supported init selector on this macOS");
        return NO;
    }

    perform(operation);
    return YES;
}
