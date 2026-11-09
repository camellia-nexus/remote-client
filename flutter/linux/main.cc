#include <dlfcn.h>
#include <string>
#include <cstring>
#include "my_application.h"

#define RUSTDESK_LIB_PATH "camellia_remote.so"
typedef int (*CamelliaRemoteCoreMainStatus)(int* exit_code);
typedef bool (*CamelliaRemoteCoreMain)();
bool gIsConnectionManager = false;

enum class CoreMainResult {
  StartUi = 1,
  HandledExit = 0,
  Fatal = -1,
};

void print_help_install_pkg(const char* so);

int flutter_camellia_remote_core_main(int* exit_code) {
  *exit_code = 1;
  void* camellia_remote = dlopen(RUSTDESK_LIB_PATH, RTLD_LAZY);
  if (!camellia_remote) {
    fprintf(stderr, "Failed to load \"%s\"\n", RUSTDESK_LIB_PATH);
    const char* error = dlerror();
    if (error != nullptr) {
      fprintf(stderr, "%s\n", error);
      std::string err_str(error);
      const std::string needle = ": cannot open shared object file: No such file or directory";
      size_t pos = err_str.find(needle);
      if (pos != std::string::npos) {
        std::string so = err_str.substr(0, pos);
        print_help_install_pkg(so.c_str());
      }
    }
    *exit_code = 127;
    return static_cast<int>(CoreMainResult::Fatal);
  }

  auto core_main_status = (CamelliaRemoteCoreMainStatus)dlsym(camellia_remote, "camellia_remote_core_main_status");
  if (core_main_status != nullptr) {
    int rust_exit_code = 0;
    int status = core_main_status(&rust_exit_code);
    *exit_code = rust_exit_code;
    return status;
  }

  auto core_main = (CamelliaRemoteCoreMain)dlsym(camellia_remote, "camellia_remote_core_main");
  const char* error = dlerror();
  if (error != nullptr || core_main == nullptr) {
    fprintf(stderr, "Program entry \"camellia_remote_core_main\" is not found: %s\n", error != nullptr ? error : "null");
    *exit_code = 126;
    return static_cast<int>(CoreMainResult::Fatal);
  }

  if (core_main()) {
    *exit_code = 0;
    return static_cast<int>(CoreMainResult::StartUi);
  } else {
    *exit_code = 0;
    return static_cast<int>(CoreMainResult::HandledExit);
  }
}

int main(int argc, char** argv) {
  int exit_code = 0;
  int status = flutter_camellia_remote_core_main(&exit_code);
  if (status == static_cast<int>(CoreMainResult::Fatal)) {
    return exit_code != 0 ? exit_code : 1;
  }
  if (status == static_cast<int>(CoreMainResult::HandledExit)) {
    return exit_code;
  }

  for (int i = 0; i < argc; i++) {
    if (strcmp(argv[i], "--cm") == 0) {
      gIsConnectionManager = true;
    }
  }
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}

typedef struct {
  const char* mgr;
  const char* search;
} PkgMgrSearch;

const PkgMgrSearch g_mgrs[] = {
  {
    "apt",
    "apt-file search",
  },
  {
    "dnf",
    "dnf provides",
  },
  {
    "yum",
    "yum provides",
  },
  {
    "zypper",
    "zypper wp",
  },
  {
    "pacman",
    "pacman -Qo",
  },
  {
    NULL,
    NULL,
  },
};

int is_command_exists(const char* command) {
    if (command == nullptr) {
        return 0;
    }
    const char* path = getenv("PATH");
    if (path == nullptr || *path == '\0') {
        return 0;
    }
    char* path_copy = strdup(path);
    if (path_copy == nullptr) {
        return 0;
    }
    char* dir = strtok(path_copy, ":");

    while (dir != NULL) {
        char command_path[512];
        snprintf(command_path, sizeof(command_path), "%s/%s", dir, command);
        if (access(command_path, X_OK) == 0) {
            free(path_copy);
            return 1;
        }
        dir = strtok(NULL, ":");
    }

    free(path_copy);
    return 0;
}

// We do not automatically search pkg
// as the search process can be time consuming and update may be required.
void print_help_install_pkg(const char* so)
{
  if (strcmp(so, "libnsl.so.1") == 0) {
    const char* mgr[] = {"yum", "dnf", NULL};
    const char** m = mgr;
    while (*m != NULL) {
      if (is_command_exists(*m)) {
        fprintf(stderr, "Please run \"%s install libnsl\" to install the required package.\n", *m);
        return;
      }
      m++;
    }
  }

  const PkgMgrSearch *mgr_search = g_mgrs;
  while (mgr_search->mgr != NULL) {
      if (is_command_exists(mgr_search->mgr) == 1) {
        fprintf(stderr, "Please run \"%s %s\" to search and install the pkg.\n", mgr_search->search, so);
        break;
      }
      mgr_search++;
  }
}
