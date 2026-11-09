/*
 * elf_rpath.c
 *
 * Convert an ELF64 executable's DT_RUNPATH to DT_RPATH, in place.
 *
 * zig 0.16 records -L dirs and addRPathSpecial("$ORIGIN") as DT_RUNPATH.
 * glibc does NOT consult an executable's DT_RUNPATH when resolving
 * dlopen(3) calls made from inside a loaded shared object - the FEIG
 * SDK (libfeisp) dlopens the transport plugins (libfeusb2.so, ...) by
 * bare name, so plugin loading fails with "cannot open shared object
 * file" whenever the binary is run directly.
 *
 * Old-style DT_RPATH, by contrast, IS consulted for dlopen (walked
 * down the dependency chain), so converting the entry makes the plugin
 * dlopen find the libs staged next to the executable. The rpath string
 * itself is unchanged; only the 8-byte tag value flips (29 -> 15).
 *
 * Usage: elf_rpath <elf64-executable>
 * Exit codes: 0 ok (converted or already DT_RPATH), 1 error, 2 usage.
 */

#define _GNU_SOURCE /* memmem */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define PT_DYNAMIC 2
#define DT_NULL 0
#define DT_RPATH 15
#define DT_RUNPATH 29

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <elf64-executable>\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];

    int fd = open(path, O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "ERROR: cannot open %s: %s\n", path, strerror(errno));
        return 1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        fprintf(stderr, "ERROR: fstat %s: %s\n", path, strerror(errno));
        close(fd);
        return 1;
    }
    if (st.st_size < 64) {
        fprintf(stderr, "ERROR: %s too small to be an ELF file\n", path);
        close(fd);
        return 1;
    }
    uint8_t *p = mmap(NULL, st.st_size, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
    if (p == MAP_FAILED) {
        fprintf(stderr, "ERROR: mmap %s: %s\n", path, strerror(errno));
        close(fd);
        return 1;
    }

    int rc = 1;
    static const uint8_t elf_magic[4] = { 0x7f, 'E', 'L', 'F' };
    if (memcmp(p, elf_magic, 4) != 0 || p[4] != 2) {
        fprintf(stderr, "ERROR: %s is not an ELF64 executable\n", path);
        goto out;
    }

    uint64_t e_phoff;
    uint16_t e_phentsize, e_phnum;
    memcpy(&e_phoff, p + 0x20, 8);
    memcpy(&e_phentsize, p + 0x36, 2);
    memcpy(&e_phnum, p + 0x38, 2);

    uint64_t dyn_off = 0, dyn_size = 0;
    for (int i = 0; i < e_phnum; i++) {
        uint64_t base = e_phoff + (uint64_t)i * e_phentsize;
        uint32_t p_type;
        memcpy(&p_type, p + base, 4);
        if (p_type == PT_DYNAMIC) {
            memcpy(&dyn_off, p + base + 8, 8);
            memcpy(&dyn_size, p + base + 32, 8);
            break;
        }
    }
    if (dyn_off == 0) {
        fprintf(stderr, "ERROR: %s has no PT_DYNAMIC segment\n", path);
        goto out;
    }

    int have_rpath = 0, have_runpath = 0, runpath_off = -1;
    for (uint64_t off = dyn_off; off + 16 <= dyn_off + dyn_size; off += 16) {
        int64_t d_tag;
        memcpy(&d_tag, p + off, 8);
        if (d_tag == DT_NULL) break;
        if (d_tag == DT_RPATH) {
            have_rpath = 1;
        } else if (d_tag == DT_RUNPATH) {
            have_runpath = 1;
            runpath_off = (int)off;
        }
    }

    if (have_rpath && have_runpath) {
        fprintf(stderr,
                "elf_rpath: both DT_RPATH and DT_RUNPATH present, "
                "leaving DT_RPATH in place\n");
        rc = 0;
    } else if (have_rpath) {
        printf("elf_rpath: already DT_RPATH, nothing to do\n");
        rc = 0;
    } else if (have_runpath) {
        int64_t tag = DT_RPATH;
        memcpy(p + runpath_off, &tag, 8);
        if (msync(p, st.st_size, MS_SYNC) != 0) {
            fprintf(stderr, "ERROR: msync %s: %s\n", path, strerror(errno));
            goto out;
        }
        printf("elf_rpath: converted DT_RUNPATH -> DT_RPATH\n");
        rc = 0;
    } else {
        fprintf(stderr, "ERROR: %s has neither DT_RPATH nor DT_RUNPATH\n", path);
        goto out;
    }

    if (memmem(p, st.st_size, "$ORIGIN", 7) == NULL) {
        fprintf(stderr,
                "WARNING: no $ORIGIN in file - rpath may not cover the "
                "exe directory\n");
    }

out:
    munmap(p, st.st_size);
    close(fd);
    return rc;
}
