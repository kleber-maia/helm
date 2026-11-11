#include "TerminalProcessDirectory.h"
#include <libproc.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>
#include <stdlib.h>
#include <limits.h>
#include <sys/ioctl.h>
#include <termios.h>

bool HelmOwnedProcessIdentity(pid_t pid, HelmProcessIdentity *identity) {
  struct proc_bsdinfo info = {0};
  if (pid <= 0 || !identity ||
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
      info.pbi_ppid != getpid()) {
    return false;
  }
  identity->seconds = info.pbi_start_tvsec;
  identity->microseconds = info.pbi_start_tvusec;
  return true;
}

bool HelmOwnedProcessDirectoryInfo(pid_t pid, HelmProcessIdentity expected,
    char *path, size_t capacity, HelmDirectoryIdentity *directory) {
  HelmProcessIdentity before, after;
  struct proc_vnodepathinfo info = {0};
  struct stat actual = {0};
  if (!path || !directory || capacity == 0 || !HelmOwnedProcessIdentity(pid, &before) ||
      before.seconds != expected.seconds || before.microseconds != expected.microseconds ||
      proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info)) != sizeof(info) ||
      !HelmOwnedProcessIdentity(pid, &after) || before.seconds != after.seconds ||
      before.microseconds != after.microseconds ||
      strlcpy(path, info.pvi_cdir.vip_path, capacity) >= capacity || path[0] != '/' ||
      stat(path, &actual) != 0 ||
      actual.st_dev != info.pvi_cdir.vip_vi.vi_stat.vst_dev ||
      actual.st_ino != info.pvi_cdir.vip_vi.vi_stat.vst_ino) {
    return false;
  }
  directory->device = actual.st_dev;
  directory->inode = actual.st_ino;
  return true;
}

bool HelmOwnedProcessDirectory(pid_t pid, HelmProcessIdentity expected,
                               char *path, size_t capacity) {
  HelmDirectoryIdentity directory;
  return HelmOwnedProcessDirectoryInfo(pid, expected, path, capacity, &directory);
}


bool HelmOwnedShellAppearsIdle(pid_t pid, HelmProcessIdentity expected,
                               const char *shell) {
  HelmProcessIdentity before, after;
  struct proc_bsdinfo info = {0};
  char executable[PROC_PIDPATHINFO_MAXSIZE] = {0};
  char expectedPath[PATH_MAX] = {0}, actualPath[PATH_MAX] = {0};
  pid_t children[2] = {0};
  if (!shell || !HelmOwnedProcessIdentity(pid, &before) ||
      before.seconds != expected.seconds || before.microseconds != expected.microseconds ||
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
      info.pbi_pgid == 0 || info.e_tpgid != info.pbi_pgid ||
      proc_pidpath(pid, executable, sizeof(executable)) <= 0 ||
      !realpath(shell, expectedPath) || !realpath(executable, actualPath) ||
      strcmp(expectedPath, actualPath) != 0) {
    return false;
  }
  // proc_listpids returns bytes, including zero for both empty and error;
  // errno distinguishes an error after explicitly clearing it.
  errno = 0;
  int count = proc_listpids(PROC_PPID_ONLY, (uint32_t)pid, children, sizeof(children));
  if (count != 0 || errno != 0 || !HelmOwnedProcessIdentity(pid, &after) ||
      before.seconds != after.seconds || before.microseconds != after.microseconds) {
    return false;
  }
  return true;
}


bool HelmReadTerminalSize(int descriptor, HelmTerminalSize *result) {
  struct winsize size = {0};
  if (descriptor < 0 || !result || ioctl(descriptor, TIOCGWINSZ, &size) != 0) {
    return false;
  }
  result->rows = size.ws_row;
  result->columns = size.ws_col;
  result->pixelWidth = size.ws_xpixel;
  result->pixelHeight = size.ws_ypixel;
  return true;
}
