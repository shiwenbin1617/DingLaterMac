/* Read-only SQLite VFS for DingTalk's ArkDB.
 *
 * DingTalk encrypts every database page in place with AES-128-ECB (no IV, no
 * padding, whole page).  The key is a 16-byte value supplied at runtime.  This
 * VFS decrypts pages on read and, when a "-wal" file is present, overlays the
 * pages from the committed frames of the current WAL generation so that the
 * database reflects the latest committed state without locking the live app.
 */

#include "DingTalkVFS.h"

#include <sqlite3.h>
#include <CommonCrypto/CommonCryptor.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define DT_MAX_PAGE 65536

typedef struct {
    sqlite3_file base;
    int fd;
    sqlite3_int64 size;
    unsigned pagesize;
    unsigned char key[16];
    unsigned char **wal_pages;   /* indexed by 0-based page number */
    long wal_len;
    long final_pages;
    int use_wal;
} dtFile;

static unsigned char g_key[16];
static int g_key_ready = 0;
static pthread_once_t g_reg_once = PTHREAD_ONCE_INIT;
static sqlite3_vfs g_vfs;

static unsigned be32(const unsigned char *p) {
    return ((unsigned)p[0] << 24) | ((unsigned)p[1] << 16) | ((unsigned)p[2] << 8) | p[3];
}

static int is_sidecar(const char *z) {
    if (!z) return 0;
    size_t n = strlen(z);
    const char *suffixes[] = {"-wal", "-shm", "-journal", 0};
    for (int i = 0; suffixes[i]; i++) {
        size_t m = strlen(suffixes[i]);
        if (n >= m && strcmp(z + n - m, suffixes[i]) == 0) return 1;
    }
    return 0;
}

static unsigned char *aes_decrypt(const unsigned char *key, const unsigned char *in, unsigned len) {
    unsigned char *out = malloc(len ? len : 1);
    if (!out) return NULL;
    size_t moved = 0;
    CCCryptorStatus st = CCCrypt(kCCDecrypt, kCCAlgorithmAES128, kCCOptionECBMode,
                                 key, 16, NULL, in, len, out, len, &moved);
    if (st != kCCSuccess) { free(out); return NULL; }
    return out;
}

/* Parse the current generation's committed WAL frames into per-page buffers. */
static void load_wal(dtFile *f, const char *dbpath) {
    size_t n = strlen(dbpath);
    char *walpath = malloc(n + 5);
    if (!walpath) return;
    memcpy(walpath, dbpath, n);
    memcpy(walpath + n, "-wal", 5);

    int fd = open(walpath, O_RDONLY);
    free(walpath);
    if (fd < 0) return;

    struct stat st;
    long fsz = 24 + (long)f->pagesize;
    if (fstat(fd, &st) != 0 || st.st_size < 32 + fsz) { close(fd); return; }

    unsigned char hdr[32];
    if (pread(fd, hdr, 32, 0) != 32) { close(fd); return; }
    unsigned magic = be32(hdr);
    unsigned psz = be32(hdr + 8);
    if ((magic != 0x377f0682u && magic != 0x377f0683u) || psz != f->pagesize) { close(fd); return; }

    long nframes = (long)((st.st_size - 32) / fsz);
    if (nframes <= 0) { close(fd); return; }

    unsigned char *frame = malloc((size_t)fsz);
    if (!frame) { close(fd); return; }

    unsigned hs1 = be32(hdr + 16), hs2 = be32(hdr + 20);
    long valid = 0;
    for (long i = 0; i < nframes; i++) {
        if (pread(fd, frame, 24, 32 + i * fsz) != 24) break;
        if (be32(frame + 8) != hs1 || be32(frame + 12) != hs2) break;
        valid = i + 1;
    }
    nframes = valid;
    if (nframes <= 0) { free(frame); close(fd); return; }

    long last = -1, final = 0;
    for (long i = 0; i < nframes; i++) {
        if (pread(fd, frame, 24, 32 + i * fsz) != 24) break;
        unsigned dbsz = be32(frame + 4);
        if (dbsz) { last = i; final = (long)dbsz; }
    }
    if (last < 0 || final <= 0) { free(frame); close(fd); return; }

    unsigned char **pages = calloc((size_t)final, sizeof(unsigned char *));
    if (!pages) { free(frame); close(fd); return; }

    for (long i = 0; i <= last; i++) {
        if (pread(fd, frame, (size_t)fsz, 32 + i * fsz) != fsz) break;
        unsigned pgno = be32(frame);
        if (pgno == 0 || (long)pgno > final) continue;
        unsigned char *plain = aes_decrypt(f->key, frame + 24, f->pagesize);
        if (!plain) continue;
        free(pages[pgno - 1]);
        pages[pgno - 1] = plain;
    }

    free(frame);
    close(fd);
    f->wal_pages = pages;
    f->wal_len = final;
    f->final_pages = final;
    f->use_wal = 1;
}

static int dtClose(sqlite3_file *p) {
    dtFile *f = (dtFile *)p;
    if (f->fd >= 0) { close(f->fd); f->fd = -1; }
    if (f->wal_pages) {
        for (long i = 0; i < f->wal_len; i++) free(f->wal_pages[i]);
        free(f->wal_pages);
        f->wal_pages = NULL;
    }
    return SQLITE_OK;
}

/* Returns a malloc'd plaintext page, or a borrowed WAL page (needfree == 0). */
static unsigned char *page_data(dtFile *f, long pidx, int *needfree) {
    *needfree = 0;
    if (f->use_wal && pidx >= 0 && pidx < f->wal_len && f->wal_pages[pidx])
        return f->wal_pages[pidx];

    unsigned ps = f->pagesize;
    unsigned char *plain = malloc(ps);
    if (!plain) return NULL;
    sqlite3_int64 off = (sqlite3_int64)pidx * ps;
    if (off + ps > f->size) {
        memset(plain, 0, ps);
        *needfree = 1;
        return plain;
    }
    unsigned char *ct = malloc(ps);
    if (!ct || pread(f->fd, ct, ps, off) != (ssize_t)ps) {
        free(ct);
        memset(plain, 0, ps);
        *needfree = 1;
        return plain;
    }
    size_t moved = 0;
    CCCryptorStatus st = CCCrypt(kCCDecrypt, kCCAlgorithmAES128, kCCOptionECBMode,
                                 f->key, 16, NULL, ct, ps, plain, ps, &moved);
    free(ct);
    if (st != kCCSuccess) memset(plain, 0, ps);
    *needfree = 1;
    return plain;
}

static int dtRead(sqlite3_file *p, void *buf, int amt, sqlite3_int64 ofst) {
    dtFile *f = (dtFile *)p;
    if (amt <= 0) return SQLITE_OK;
    unsigned char *out = (unsigned char *)buf;
    sqlite3_int64 pos = ofst;
    int remain = amt;
    unsigned ps = f->pagesize;
    while (remain > 0) {
        long pidx = (long)(pos / ps);
        long poff = (long)(pos % ps);
        int chunk = (int)(ps - poff);
        if (chunk > remain) chunk = remain;
        int needfree = 0;
        unsigned char *page = page_data(f, pidx, &needfree);
        if (!page) return SQLITE_IOERR_READ;
        if (pidx == 0) {
            unsigned char *copy = malloc(ps);
            if (!copy) { if (needfree) free(page); return SQLITE_NOMEM; }
            memcpy(copy, page, ps);
            if (needfree) free(page);
            page = copy; needfree = 1;
            if (ps >= 20) { page[18] = 1; page[19] = 1; }   /* present as non-WAL */
            if (f->use_wal && ps >= 32) {
                unsigned long fp = (unsigned long)f->final_pages;
                page[28] = (unsigned char)(fp >> 24); page[29] = (unsigned char)(fp >> 16);
                page[30] = (unsigned char)(fp >> 8);  page[31] = (unsigned char)fp;
            }
        }
        memcpy(out, page + poff, (size_t)chunk);
        if (needfree) free(page);
        out += chunk; pos += chunk; remain -= chunk;
    }
    return SQLITE_OK;
}

static int dtWrite(sqlite3_file *p, const void *b, int a, sqlite3_int64 o) { (void)p;(void)b;(void)a;(void)o; return SQLITE_READONLY; }
static int dtTruncate(sqlite3_file *p, sqlite3_int64 s) { (void)p;(void)s; return SQLITE_READONLY; }
static int dtSync(sqlite3_file *p, int flags) { (void)p;(void)flags; return SQLITE_OK; }
static int dtFileSize(sqlite3_file *p, sqlite3_int64 *pSize) {
    dtFile *f = (dtFile *)p;
    *pSize = (f->use_wal && f->final_pages > 0) ? (sqlite3_int64)f->final_pages * f->pagesize : f->size;
    return SQLITE_OK;
}
static int dtLock(sqlite3_file *p, int l) { (void)p;(void)l; return SQLITE_OK; }
static int dtUnlock(sqlite3_file *p, int l) { (void)p;(void)l; return SQLITE_OK; }
static int dtCheckReservedLock(sqlite3_file *p, int *out) { (void)p; *out = 0; return SQLITE_OK; }
static int dtFileControl(sqlite3_file *p, int op, void *arg) { (void)p;(void)op;(void)arg; return SQLITE_NOTFOUND; }
static int dtSectorSize(sqlite3_file *p) { (void)p; return 4096; }
static int dtDeviceCharacteristics(sqlite3_file *p) { (void)p; return SQLITE_IOCAP_IMMUTABLE; }

static sqlite3_io_methods dt_io = {
    .iVersion = 1,
    .xClose = dtClose,
    .xRead = dtRead,
    .xWrite = dtWrite,
    .xTruncate = dtTruncate,
    .xSync = dtSync,
    .xFileSize = dtFileSize,
    .xLock = dtLock,
    .xUnlock = dtUnlock,
    .xCheckReservedLock = dtCheckReservedLock,
    .xFileControl = dtFileControl,
    .xSectorSize = dtSectorSize,
    .xDeviceCharacteristics = dtDeviceCharacteristics,
};

static int dtOpen(sqlite3_vfs *vfs, const char *zName, sqlite3_file *pFile, int flags, int *pOutFlags) {
    (void)vfs;
    dtFile *f = (dtFile *)pFile;
    memset(f, 0, sizeof(*f));
    f->fd = -1;
    if (!zName || is_sidecar(zName)) return SQLITE_CANTOPEN;
    if ((flags & SQLITE_OPEN_READWRITE) || (flags & SQLITE_OPEN_CREATE)) return SQLITE_READONLY;
    if (!g_key_ready) return SQLITE_CANTOPEN;

    int fd = open(zName, O_RDONLY);
    if (fd < 0) return SQLITE_CANTOPEN;
    struct stat st;
    if (fstat(fd, &st) != 0) { close(fd); return SQLITE_CANTOPEN; }

    unsigned char head[4096];
    if (st.st_size < 100 || pread(fd, head, sizeof(head), 0) != (ssize_t)sizeof(head)) {
        close(fd);
        return SQLITE_CANTOPEN;
    }
    memcpy(f->key, g_key, 16);
    unsigned char *plain = aes_decrypt(f->key, head, sizeof(head));
    if (!plain) { close(fd); return SQLITE_CANTOPEN; }
    int ok = memcmp(plain, "SQLite format 3\0", 16) == 0;
    unsigned ps = ((unsigned)plain[16] << 8) | plain[17];
    free(plain);
    if (ps == 0) ps = 65536;
    if (!ok || ps < 512 || ps > DT_MAX_PAGE || (ps & (ps - 1)) != 0) { close(fd); return SQLITE_NOTADB; }

    f->fd = fd;
    f->size = st.st_size;
    f->pagesize = ps;
    load_wal(f, zName);
    f->base.pMethods = &dt_io;
    if (pOutFlags) *pOutFlags = SQLITE_OPEN_READONLY;
    return SQLITE_OK;
}

static int dtDelete(sqlite3_vfs *vfs, const char *zName, int syncDir) {
    (void)vfs; (void)zName; (void)syncDir;
    return SQLITE_IOERR_DELETE;
}

static int dtAccess(sqlite3_vfs *vfs, const char *zName, int flags, int *pResOut) {
    (void)vfs; (void)flags;
    *pResOut = (!is_sidecar(zName) && zName && access(zName, F_OK) == 0) ? 1 : 0;
    return SQLITE_OK;
}

static void register_vfs(void) {
    sqlite3_vfs *base = sqlite3_vfs_find(0);
    if (!base) return;
    g_vfs = *base;
    g_vfs.zName = "dingtalk";
    g_vfs.pNext = 0;
    g_vfs.szOsFile = sizeof(dtFile);
    g_vfs.xOpen = dtOpen;
    g_vfs.xDelete = dtDelete;
    g_vfs.xAccess = dtAccess;
    sqlite3_vfs_register(&g_vfs, 0);
}

int dingtalk_vfs_register(void) {
    pthread_once(&g_reg_once, register_vfs);
    return 0;
}

void dingtalk_vfs_set_key(const unsigned char *key16) {
    if (!key16) return;
    memcpy(g_key, key16, 16);
    g_key_ready = 1;
}
