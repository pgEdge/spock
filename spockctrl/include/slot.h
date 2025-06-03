#ifndef SLOT_H
#define SLOT_H

// Handle slot command-line subcommands
int handle_slot_command(int argc, char *argv[]);

// Print slot command help
void print_slot_help(void);


int handle_slot_create_command(int argc, char *argv[]);
int handle_slot_drop_command(int argc, char *argv[]);
int handle_slot_enable_command(int argc, char *argv[]);
int handle_slot_disable_command(int argc, char *argv[]);

#endif // SLOT_H
