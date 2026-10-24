#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <dlfcn.h>
#import <sys/mman.h>
#import <string.h>
#import <pthread.h>
#import "SGRebind.h"
#import "SGLog.h"

// Writes one pointer, making its page writable first; a page dyld made read only after binding
// (__DATA_CONST, __AUTH_CONST) is copied and made read only again.
static BOOL writeSlot(void **slot, void *value, BOOL readOnly) {
    vm_size_t page = vm_page_size ? vm_page_size : 16384;
    vm_address_t start = (vm_address_t)slot & ~(page - 1);
    
    // First attempt: VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY
    kern_return_t result = vm_protect(mach_task_self(), start, page, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (result != KERN_SUCCESS) {
        // Fallback: the page might already be a private COW copy from a previous write on the same page.
        result = vm_protect(mach_task_self(), start, page, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    }
    if (result != KERN_SUCCESS) {
        if (mprotect((void *)start, page, PROT_READ | PROT_WRITE) == 0) {
            result = KERN_SUCCESS;
        }
    }
    if (result != KERN_SUCCESS) {
        SGLog(@"rebind: vm_protect failed (%d) for slot %p on page 0x%lx", result, slot, (unsigned long)start);
        return NO;
    }
    *slot = value;
    if (readOnly) {
        vm_protect(mach_task_self(), start, page, FALSE, VM_PROT_READ);
    }
    return YES;
}

static BOOL rebindInHeader(const struct mach_header_64 *header, intptr_t slide, const char *symbol, void *replacement, void **original, void *fallback) {
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct load_command *command = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const struct load_command *)((const char *)command + command->cmdsize)) {
        if (command->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)command)->segname, SEG_LINKEDIT) == 0) {
            linkedit = (const struct segment_command_64 *)command;
        } else if (command->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)command;
        } else if (command->cmd == LC_DYSYMTAB) {
            dysymtab = (const struct dysymtab_command *)command;
        }
    }
    if (!linkedit || !symtab || !dysymtab || !dysymtab->nindirectsyms) return NO;

    uintptr_t base = (uintptr_t)slide + (uintptr_t)(linkedit->vmaddr - linkedit->fileoff);
    const struct nlist_64 *symbols = (const struct nlist_64 *)(base + symtab->symoff);
    const char *strings = (const char *)(base + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(base + dysymtab->indirectsymoff);

    // The symbol's index once, searching undefined symbols first, then all symbols.
    uint32_t wanted = UINT32_MAX;
    uint32_t start = dysymtab->iundefsym;
    uint32_t end = start + dysymtab->nundefsym;
    if (end > symtab->nsyms) end = symtab->nsyms;
    for (uint32_t i = start; i < end; i++) {
        uint32_t offset = symbols[i].n_un.n_strx;
        if (offset >= symtab->strsize) continue;
        const char *name = strings + offset;
        if (name[0] == '_' && strcmp(name + 1, symbol) == 0) {
            wanted = i;
            break;
        }
    }
    if (wanted == UINT32_MAX) {
        for (uint32_t i = 0; i < symtab->nsyms; i++) {
            uint32_t offset = symbols[i].n_un.n_strx;
            if (offset >= symtab->strsize) continue;
            const char *name = strings + offset;
            if (name[0] == '_' && strcmp(name + 1, symbol) == 0) {
                wanted = i;
                break;
            }
        }
    }
    if (wanted == UINT32_MAX) return NO;

    BOOL rebound = NO;
    command = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const struct load_command *)((const char *)command + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
        BOOL readOnly = strcmp(segment->segname, "__DATA_CONST") == 0 || strcmp(segment->segname, "__AUTH_CONST") == 0;
        const struct section_64 *section = (const struct section_64 *)(segment + 1);
        for (uint32_t s = 0; s < segment->nsects; s++, section++) {
            uint32_t type = section->flags & SECTION_TYPE;
            if (type != S_NON_LAZY_SYMBOL_POINTERS && type != S_LAZY_SYMBOL_POINTERS) continue;
            void **slots = (void **)((uintptr_t)slide + section->addr);
            uint64_t count = section->size / sizeof(void *);
            for (uint64_t k = 0; k < count; k++) {
                uint64_t entry = (uint64_t)section->reserved1 + k;
                if (entry >= dysymtab->nindirectsyms || indirect[entry] != wanted) continue;
                if (slots[k] == replacement) {
                    rebound = YES;
                    continue;
                }
                void *held = slots[k];
                if (!writeSlot(&slots[k], replacement, readOnly)) continue;
                if (original && !*original) {
                    if (held && ((uintptr_t)held & 0x8000000000000000ULL) == 0) {
                        *original = held;
                    } else {
                        *original = fallback;
                    }
                }
                rebound = YES;
            }
        }
    }
    if (rebound && original && (!*original || ((uintptr_t)*original & 0x8000000000000000ULL))) {
        *original = fallback;
    }
    return rebound;
}

struct SGRebindingEntry {
    char symbol[128];
    void *replacement;
    void **original;
    void *fallback;
    BOOL rebound;
};

static struct SGRebindingEntry sg_rebindings[32];
static size_t sg_rebinding_count = 0;
static pthread_mutex_t sg_rebind_lock = PTHREAD_MUTEX_INITIALIZER;
static BOOL sg_dyld_registered = NO;

extern const struct mach_header_64 _mh_dylib_header;

static BOOL shouldCheckImage(const struct mach_header *header, const char *name) {
    if (!header || header->magic != MH_MAGIC_64) return NO;
    if ((const void *)header == (const void *)&_mh_dylib_header) return NO;
    if (name && strstr(name, "LiveContainer.app")) return NO;
    if (header->filetype == MH_EXECUTE) return YES;
    if (name) {
        const char *slash = strrchr(name, '/');
        const char *file = slash ? slash + 1 : name;
        return strcmp(file, "Spotify") == 0 && strstr(name, ".app/Spotify") != NULL;
    }
    return NO;
}

static void rebindImage(const struct mach_header *header, intptr_t slide) {
    Dl_info info;
    const char *name = NULL;
    if (dladdr(header, &info) && info.dli_fname) {
        name = info.dli_fname;
    }
    if (!shouldCheckImage(header, name)) return;

    pthread_mutex_lock(&sg_rebind_lock);
    for (size_t i = 0; i < sg_rebinding_count; i++) {
        struct SGRebindingEntry *entry = &sg_rebindings[i];
        if (rebindInHeader((const struct mach_header_64 *)header, slide, entry->symbol, entry->replacement, entry->original, entry->fallback)) {
            entry->rebound = YES;
            SGLog(@"rebind: successfully rebound %s in image %s", entry->symbol, name ?: "unknown");
        }
    }
    pthread_mutex_unlock(&sg_rebind_lock);
}

BOOL SGRebindImport(const char *symbol, void *replacement, void **original) {
    if (!symbol || !replacement) return NO;

    void *fallback = dlsym(RTLD_DEFAULT, symbol);

    BOOL needRegister = NO;
    pthread_mutex_lock(&sg_rebind_lock);
    struct SGRebindingEntry *entry = NULL;
    for (size_t i = 0; i < sg_rebinding_count; i++) {
        if (strcmp(sg_rebindings[i].symbol, symbol) == 0) {
            entry = &sg_rebindings[i];
            break;
        }
    }
    if (!entry && sg_rebinding_count < 32) {
        entry = &sg_rebindings[sg_rebinding_count++];
        strncpy(entry->symbol, symbol, sizeof(entry->symbol) - 1);
        entry->symbol[sizeof(entry->symbol) - 1] = '\0';
        entry->replacement = replacement;
        entry->original = original;
        entry->fallback = fallback;
        entry->rebound = NO;
    } else if (entry) {
        entry->replacement = replacement;
        if (original) entry->original = original;
        if (fallback) entry->fallback = fallback;
    }

    if (!sg_dyld_registered) {
        sg_dyld_registered = YES;
        needRegister = YES;
    }
    pthread_mutex_unlock(&sg_rebind_lock);

    if (needRegister) {
        _dyld_register_func_for_add_image(rebindImage);
    } else {
        uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; i++) {
            const struct mach_header *header = _dyld_get_image_header(i);
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            rebindImage(header, slide);
        }
    }

    pthread_mutex_lock(&sg_rebind_lock);
    BOOL rebound = entry ? entry->rebound : NO;
    pthread_mutex_unlock(&sg_rebind_lock);

    return rebound;
}
