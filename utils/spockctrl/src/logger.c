/*-------------------------------------------------------------------------
 *
 * logger.c
 *      logging utility functions
 *
 * Copyright (c) 2022-2026, pgEdge, Inc.
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include "logger.h"
#include "util.h"
#include <stdio.h>
#include <stdarg.h>
#include <time.h>

LogLevel current_log_level = LOG_LEVEL_NONE;

void log_message(const char *color, const char *symbol, const char *format, va_list args)
{
    time_t now;
    struct tm *local_time;
    char time_buffer[20];

    now = time(NULL);
    local_time = localtime(&now);
    strftime(time_buffer, sizeof(time_buffer), "%Y-%m-%d %H:%M:%S", local_time);

    fprintf(stderr, "%s[%s] %s", color, time_buffer, symbol);
    vfprintf(stderr, format, args);
    fprintf(stderr, "%s\n", COLOR_RESET);
}

void log_info(const char *format, ...)
{
    va_list args;

    if (current_log_level >= LOG_LEVEL_INFO)
    {
        va_start(args, format);
        log_message(COLOR_GREEN, "[INFO] ", format, args);
        va_end(args);
    }
}
void log_msg(const char *fmt, ...)
{
    va_list args;

    va_start(args, fmt);
    log_message(COLOR_DEFAULT, "", fmt, args);
    va_end(args);
}

void log_error(const char *fmt, ...)
{
    va_list args;

    va_start(args, fmt);
    log_message(COLOR_RED, "[ERROR]: ", fmt, args);
    va_end(args);
}

void log_warning(const char *fmt, ...)
{
    va_list args;

    if (current_log_level >= LOG_LEVEL_WARNING)
    {
        va_start(args, fmt);
        log_message(COLOR_YELLOW, "[WARN] ", fmt, args);
        va_end(args);
    }
}

void log_debug0(const char *fmt, ...)
{
    va_list args;

    if (current_log_level >= LOG_LEVEL_DEBUG0)
    {
        va_start(args, fmt);
        log_message(COLOR_BLUE, "[DEBUG]", fmt, args);
        va_end(args);
    }
}

void log_debug1(const char *fmt, ...)
{
    va_list args;

    if (current_log_level >= LOG_LEVEL_DEBUG1)
    {
        va_start(args, fmt);
        log_message(COLOR_BLUE, "[DEBUG]", fmt, args);
        va_end(args);
    }
}