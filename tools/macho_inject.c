#include <errno.h>
#include <fcntl.h>
#include <mach-o/loader.h>
#include <mach/machine.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static int fail(const char *message) {
    fprintf(stderr, "macho-inject: %s\n", message);
    return 1;
}

static uint32_t align8(uint32_t value) {
    return (value + 7u) & ~7u;
}

int main(int argc, char **argv) {
    if (argc != 3) return fail("usage: macho-inject MACHO LOAD_PATH");
    const char *path = argv[1];
    const char *loadPath = argv[2];
    size_t loadPathLength = strlen(loadPath) + 1;
    if (loadPathLength > UINT32_MAX - sizeof(struct dylib_command) - 7u)
        return fail("load path is too long");

    int fd = open(path, O_RDWR);
    if (fd < 0) return fail(strerror(errno));
    struct stat status;
    if (fstat(fd, &status) != 0 || status.st_size < (off_t)sizeof(struct mach_header_64)) {
        close(fd);
        return fail("invalid input size");
    }
    size_t fileSize = (size_t)status.st_size;
    uint8_t *bytes = mmap(NULL, fileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (bytes == MAP_FAILED) {
        close(fd);
        return fail(strerror(errno));
    }

    int result = 1;
    struct mach_header_64 *header = (struct mach_header_64 *)bytes;
    if (header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64) {
        fail("expected a thin arm64 Mach-O");
        goto cleanup;
    }
    uint64_t commandsStart = sizeof(*header);
    uint64_t commandsEnd = commandsStart + header->sizeofcmds;
    if (commandsEnd > fileSize) {
        fail("load commands extend beyond the file");
        goto cleanup;
    }

    uint64_t firstDataOffset = fileSize;
    uint8_t *cursor = bytes + commandsStart;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        if ((uint64_t)(cursor - bytes) + sizeof(struct load_command) > commandsEnd) {
            fail("truncated load command");
            goto cleanup;
        }
        struct load_command *command = (struct load_command *)cursor;
        if (command->cmdsize < sizeof(*command) ||
            (uint64_t)(cursor - bytes) + command->cmdsize > commandsEnd) {
            fail("invalid load command size");
            goto cleanup;
        }
        if (command->cmd == LC_SEGMENT_64) {
            if (command->cmdsize < sizeof(struct segment_command_64)) {
                fail("truncated segment command");
                goto cleanup;
            }
            struct segment_command_64 *segment = (struct segment_command_64 *)cursor;
            uint64_t sectionsSize = (uint64_t)segment->nsects * sizeof(struct section_64);
            if (sizeof(*segment) + sectionsSize > command->cmdsize) {
                fail("invalid segment section table");
                goto cleanup;
            }
            struct section_64 *sections = (struct section_64 *)(segment + 1);
            for (uint32_t sectionIndex = 0; sectionIndex < segment->nsects; sectionIndex++) {
                uint32_t offset = sections[sectionIndex].offset;
                if (offset >= commandsEnd && offset < firstDataOffset)
                    firstDataOffset = offset;
            }
        }
        if (command->cmd == LC_LOAD_DYLIB || command->cmd == LC_LOAD_WEAK_DYLIB) {
            if (command->cmdsize < sizeof(struct dylib_command)) {
                fail("truncated dylib command");
                goto cleanup;
            }
            struct dylib_command *dylib = (struct dylib_command *)cursor;
            uint32_t nameOffset = dylib->dylib.name.offset;
            if (nameOffset < sizeof(*dylib) || nameOffset >= command->cmdsize) {
                fail("invalid dylib name offset");
                goto cleanup;
            }
            const char *name = (const char *)cursor + nameOffset;
            size_t capacity = command->cmdsize - nameOffset;
            if (memchr(name, '\0', capacity) == NULL) {
                fail("unterminated dylib name");
                goto cleanup;
            }
            if (strcmp(name, loadPath) == 0) {
                result = 0;
                goto cleanup;
            }
        }
        cursor += command->cmdsize;
    }
    if ((uint64_t)(cursor - bytes) != commandsEnd) {
        fail("load command count and size disagree");
        goto cleanup;
    }

    uint32_t commandSize = align8((uint32_t)(sizeof(struct dylib_command) + loadPathLength));
    if (commandsEnd + commandSize > firstDataOffset) {
        fail("insufficient free space before Mach-O data");
        goto cleanup;
    }
    struct dylib_command *added = (struct dylib_command *)(bytes + commandsEnd);
    memset(added, 0, commandSize);
    added->cmd = LC_LOAD_DYLIB;
    added->cmdsize = commandSize;
    added->dylib.name.offset = sizeof(*added);
    added->dylib.timestamp = 2;
    memcpy((uint8_t *)added + sizeof(*added), loadPath, loadPathLength);
    header->ncmds++;
    header->sizeofcmds += commandSize;
    if (msync(bytes, fileSize, MS_SYNC) != 0) {
        fail(strerror(errno));
        goto cleanup;
    }
    result = 0;

cleanup:
    munmap(bytes, fileSize);
    close(fd);
    return result;
}
