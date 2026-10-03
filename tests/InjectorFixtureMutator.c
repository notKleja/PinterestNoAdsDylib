#include <fcntl.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    int fd = open(argv[1], O_RDWR);
    if (fd < 0) return 1;
    struct stat status;
    if (fstat(fd, &status) != 0) return 1;
    uint8_t *bytes = mmap(NULL, (size_t)status.st_size,
        PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (bytes == MAP_FAILED) return 1;
    struct mach_header_64 *header = (struct mach_header_64 *)bytes;
    uint8_t *cursor = bytes + sizeof(*header);
    int changed = 0;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        struct load_command *command = (struct load_command *)cursor;
        if (command->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *segment = (struct segment_command_64 *)cursor;
            if (strcmp(argv[2], "truncated-segment") == 0) {
                command->cmdsize = sizeof(struct load_command);
                changed = 1;
                break;
            }
            struct section_64 *sections = (struct section_64 *)(segment + 1);
            for (uint32_t section = 0; section < segment->nsects; section++) {
                if (strncmp(sections[section].sectname, "__text", 16) == 0) {
                    sections[section].offset =
                        (uint32_t)(sizeof(*header) + header->sizeofcmds);
                    changed = 1;
                    break;
                }
            }
        }
        if (changed) break;
        cursor += command->cmdsize;
    }
    msync(bytes, (size_t)status.st_size, MS_SYNC);
    munmap(bytes, (size_t)status.st_size);
    close(fd);
    return changed ? 0 : 1;
}
