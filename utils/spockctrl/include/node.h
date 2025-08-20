#ifndef NODE_H
#define NODE_H

void print_node_help(void);
int handle_node_command(int argc, char *argv[]);

int handle_node_create_command(int argc, char *argv[]);
int handle_node_drop_command(int argc, char *argv[]);
int handle_node_add_interface_command(int argc, char *argv[]);
int handle_node_drop_interface_command(int argc, char *argv[]);


#endif /* NODE_H */
