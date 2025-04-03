#include "logger.h"
#include "util.h"
#include <stdio.h>
#include <stdarg.h>


void
log_message_va(const char *color, const char *symbol, const char *format, va_list args)
{
    printf("%s[%s] [%s] ", color, symbol, get_current_timestamp());
    vprintf(format, args);
    printf("%s\n", COLOR_RESET);
    fflush(stdout);
}

void
log_message(const char *color, const char *symbol, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    log_message_va(color, symbol, format, args);
    va_end(args);
}

void
log_info(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    log_message_va(COLOR_GREEN, "✔", format, args);
    va_end(args);
}

void
log_error(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    log_message_va(COLOR_RED, "✘", format, args);
    va_end(args);
}