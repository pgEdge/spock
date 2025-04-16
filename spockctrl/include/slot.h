#ifndef SLOT_H
#define SLOT_H

// Handle slot command-line subcommands
int handle_slot_command(int argc, char *argv[]);

// Print slot command help
void print_slot_help(void);

// The following are internal, but can be declared if needed elsewhere
void create_slot(const char *slot_name);
void drop_slot(const char *slot_name);
void enable_slot(const char *slot_name);
void disable_slot(const char *slot_name);

int handle_slot_create_command(int argc, char *argv[]);
int handle_slot_drop_command(int argc, char *argv[]);
int handle_slot_enable_command(int argc, char *argv[]);
int handle_slot_disable_command(int argc, char *argv[]);

#endif // SLOT_H
