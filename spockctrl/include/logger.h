#ifndef LOGGER_H
#define LOGGER_H

#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <stdarg.h>
#include <string.h>
#include "util.h"

#define COLOR_GREEN "\033[0;32m"
#define COLOR_RED "\033[0;31m"
#define COLOR_RESET "\033[0m"
#define COLOR_YELLOW "\033[0;33m"
#define COLOR_BLUE "\033[0;34m"
#define COLOR_DEFAULT "\033[0m"

typedef enum {
    LOG_LEVEL_NONE,
    LOG_LEVEL_WARNING,
    LOG_LEVEL_INFO,
    LOG_LEVEL_ERROR,
    LOG_LEVEL_DEBUG0,
    LOG_LEVEL_DEBUG1
} LogLevel;

void log_message(const char *color, const char *symbol, const char *format, va_list args);
void log_info(const char *format, ...);
void log_msg(const char *fmt, ...);
void log_error(const char *fmt, ...);
void log_warning(const char *fmt, ...);
void log_debug0(const char *fmt, ...);
void log_debug1(const char *fmt, ...);

extern LogLevel current_log_level;

#endif // LOGGER_H
