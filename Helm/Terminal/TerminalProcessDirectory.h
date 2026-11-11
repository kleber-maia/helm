#ifndef HELM_TERMINAL_PROCESS_DIRECTORY_H
#define HELM_TERMINAL_PROCESS_DIRECTORY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

typedef struct {
  uint64_t seconds;
  uint64_t microseconds;
} HelmProcessIdentity;

typedef struct {
  uint64_t device;
  uint64_t inode;
} HelmDirectoryIdentity;

// Conservative observation, not a prompt/builtin-idleness guarantee.
bool HelmOwnedShellAppearsIdle(pid_t pid, HelmProcessIdentity identity,
                               const char *shell);

typedef struct {
  uint16_t rows, columns, pixelWidth, pixelHeight;
} HelmTerminalSize;
bool HelmReadTerminalSize(int descriptor, HelmTerminalSize *size);

bool HelmOwnedProcessDirectoryInfo(pid_t pid, HelmProcessIdentity identity,
    char *path, size_t capacity, HelmDirectoryIdentity *directory);
bool HelmOwnedProcessIdentity(pid_t pid, HelmProcessIdentity *identity);
bool HelmOwnedProcessDirectory(pid_t pid, HelmProcessIdentity identity,
                               char *path, size_t capacity);
#endif
