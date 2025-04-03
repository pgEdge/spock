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

void log_message(const char *color, const char *symbol, const char *format, ...);
void log_info(const char *format, ...);
void log_error(const char *fmt, ...);

#endif // LOGGER_H
