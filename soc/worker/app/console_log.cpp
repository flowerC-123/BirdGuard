#include "log.h"
#include <cstdlib>
int logPrint(int level, const char *format, ...) {
    fprintf(stderr, "VENDOR_LOG level=%d ", level);
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
    fputc('\n', stderr);
    fflush(stderr);
    if (level >= LOG_ERROR) {

        fprintf(stderr, "RESULT status=ERROR source=vendor_log exit_code=20\n");
        std::exit(20);
    }
    return 0;
}
