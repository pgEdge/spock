#ifndef CONF_H
#define CONF_H

typedef struct
{
	char	   *cluster_name;
	char	   *version;
}			RaledConfig;

typedef struct
{
	char	   *log_level;
	char	   *log_destination;
	char	   *log_file;
}			LogConfig;

typedef struct
{
	char	   *postgres_ip;
	int			postgres_port;
	char	   *postgres_user;
	char	   *postgres_password;
	char	   *postgres_db;
}			PostgresConfig;

typedef struct
{
	char	   *node_name;
	PostgresConfig postgres;
}			SpockNodeConfig;

typedef struct
{
	RaledConfig raled;
	LogConfig	log;
	SpockNodeConfig *spock_nodes;
	int			spock_node_count;
}			Config;

/* Function to parse the JSON configuration file */
int			load_config(const char *filename);
void		free_config(void);

/* Functions to get values for each node using node_name */
const char *get_postgres_ip(const char *node_name);
int			get_postgres_port(const char *node_name);
const char *get_postgres_user(const char *node_name);
const char *get_postgres_password(const char *node_name);
const char *get_postgres_db(const char *node_name);

/* Added getter */
const char *get_postgres_coninfo(const char *node_name);

#endif							/* CONF_H */
