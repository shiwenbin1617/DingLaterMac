#ifndef DINGTALK_VFS_H
#define DINGTALK_VFS_H

#ifdef __cplusplus
extern "C" {
#endif

/* Registers (once) a read-only SQLite VFS named "dingtalk" that transparently
   decrypts a live DingTalk ArkDB file (AES-128-ECB, whole 4 KiB pages) and
   overlays the committed frames of the current-generation "-wal" file.
   Returns 0 on success. */
int dingtalk_vfs_register(void);

/* Sets the 16-byte AES key used for databases opened afterwards.
   Call dingtalk_vfs_register() first. */
void dingtalk_vfs_set_key(const unsigned char *key16);

#ifdef __cplusplus
}
#endif

#endif
