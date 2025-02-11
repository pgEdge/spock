import sys, os, psycopg2, json, subprocess, shutil, re, csv, socket
from dotenv import load_dotenv
from psycopg2 import sql


def EXIT_PASS():
    print("pass")
    exit_message("Pass", p_rc=0)

def EXIT_FAIL():
    print("fail")
    exit_message("Fail", p_rc=1)


## Utility Functions
def set_env():
    load_dotenv('t/lib/config.env')

## abruptly terminate with a codified message
def exit_message(p_msg, p_rc=1):
    if p_rc == 0:
       print(f"INFO {p_msg}")
    else:
       print(f"ERROR {p_msg}")
    sys.exit(p_rc)
 

# **************************************************************************************************************
## Enable AutoDDL
# **************************************************************************************************************
# To call this function, pass a connection string:
#     command = util_test.enable_autoddl(host, dbname, port, pw, usr)

## Get a connection - this connection sets autocommit to True and returns authentication error information

def get_autoddl_conn(host,dbname,port,pw,usr):
    try:
        conn = psycopg2.connect(dbname=dbname, user=usr, host=host, port=port, password=pw)
        conn.autocommit = True
        print("Your connection is established, with autocommit = True")
        return conn

    except Exception as e:
        conn = None
        print("The connection attempt failed")
    return(con1)

##############################

def enable_autoddl(host, dbname, port, pw, usr):
    try:   
        # Connect to the PostgreSQL database

        conn = get_autoddl_conn(host,dbname,port,pw,usr)
        cur = conn.cursor()
        # We'll execute the following commands:
        
        cur.execute("ALTER SYSTEM SET spock.enable_ddl_replication = on")
        cur.execute("ALTER SYSTEM SET spock.include_ddl_repset = on")
        cur.execute("ALTER SYSTEM SET spock.allow_ddl_from_functions = on")
	
        # Then, reload the PostgreSQL configuration:
        cur.execute("SELECT pg_reload_conf()")
        print("PostgreSQL configuration reloaded.")

        # Close the cursor and connection
        cur.close()
        conn.close()

    except Exception as e:
        print(f"An error occurred: {e}")







# ************************************************************************************************************** 
## Run a pgEdge command
# **************************************************************************************************************
# This function runs a pgedge command; to run a test, define the command in cmd_node, and then choose a variation:
#   * the n(node_number) directory, : res=util_test.run_cmd("add tables to repset", cmd_node, f"{cluster_dir}/n{n}")
#   * the home directory (where home_dir is nc): res=util_test.run_cmd("Testing schema-diff", cmd_node, f"{home_dir}")

def run_cmd(msg, cmd, node_path):
    print(cmd)
    result = subprocess.run(f"{node_path}/pgedge/pgedge {cmd}", shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return result

# ************************************************************************************************************** 
## Run a pgEdge command from home
# **************************************************************************************************************
# This function runs a pgedge command; to run a test, define the command in cmd_node, and then choose a variation:
#   * the n(node_number) directory, : res=util_test.run_cmd("add tables to repset", cmd_node, f"{cluster_dir}/n{n}")
#   * the home directory (where home_dir is nc): res=util_test.run_cmd("Testing schema-diff", cmd_node, f"{home_dir}")

def run_nc_cmd(msg, cmd, node_path):
    print(cmd)
    result = subprocess.run(f"{node_path}/pgedge {cmd}", shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return result

# **************************************************************************************************************
# This function removes the directory specified in the path variable; specify the complete path and directory name
# Note that this will remove a directory with contents - to remove a single file, use the remove_file command!
# **************************************************************************************************************

def remove_directory(path):
    print(path)
    shutil.rmtree(f"{path}")


# **************************************************************************************************************
# This function removes the file specified in the file variable; file is the complete path to the file and 
# the file name
# **************************************************************************************************************

def remove_file(file):
    print(file)
    try:
        os.remove(f"{file}")
    except OSError:
        pass


# **************************************************************************************************************
# PSQL Functions
# **************************************************************************************************************
## Use the source_pg_env function to source the pg_ver.env file before invoking PSQL
# **************************************************************************************************************
# You can call this in each script that needs to connect to the database with psql.
# This function sources the pg{pgv}.env file; to use it, pass in the node path, pg version, and node_number
# For example:
# res=util_test.source_pg_env(cluster_dir, pgv, node_num);

def source_pg_env(node_path, version, node_num):
    print(f"{node_path}/{node_num}/pgedge/pg{version}/pg{version}.env")
    config_file_name = format(f"{node_path}/{node_num}/pgedge/pg{version}/pg{version}.env")

# Pass information from the script to the sourcing logic from the .runner.py program (modified a bit)

    return source_config_file(config_file_name)

# source_config_file(config_file)

def source_config_file(config_file):
    # Check if the config file exists
    if not os.path.isfile(config_file):
        print(f"Error: The configuration file '{config_file}' does not exist.")
        exit(1)  # Exit the program with an error code

    # Read, format and set environment variables from the config file that are in a bash supported format
    # So stripping various things from it to get us the key, value pairs to load in os.environ[key] = value
    try:
        with open(config_file, 'r') as file:
            for line in file:
               # Ignore empty lines and comments and remove \n's
               if line.strip() and not line.startswith('#'):
                    # Remove leading and trailing whitespace
                    line = line.replace("\\n", "")
                    line = line.strip()
                    print(locals())
                    # Remove 'export ' from the line
                    line = line.replace('export ', '')
                    # Split the line into key and value at the first '='
                    key, value = line.split('=', 1)
                    # Remove double quotes if present, e.g. remove quotes around demo in export EDGE_CLUSTER="demo"
                    value = value.strip('"')
                    # Resolve any embedded environment variables e.g. resolve $NC_DIR embedded in EDGE_HOME_DIR="$NC_DIR/pgedge"
                    value = os.path.expandvars(value)
                    # Set the environment variable
                    os.environ[key] = value
        print(f"Configuration file '{config_file}' sourced successfully.")
    except Exception as e:
        print(f"Error: Failed to source the configuration file '{config_file}'.")
        print(f"Exception: {e}")
        exit(1)  # Exit the program with an error code

# **************************************************************************************************************
# PSQL Functions
# **************************************************************************************************************
## Use the source_pg_env function to source the pg_ver.env file before invoking PSQL
# **************************************************************************************************************
# You can call this in each script that needs to connect to the database with psql.
# This function sources the pg{pgv}.env file; to use it, pass in the node path, pg version, and node_number
# For example:
# res=util_test.source_pg_env(cluster_dir, pgv, node_num);

def source_pg_env(node_path, version, node_num):
    print(f"{node_path}/{node_num}/pgedge/pg{version}/pg{version}.env")
    config_file_name = format(f"{node_path}/{node_num}/pgedge/pg{version}/pg{version}.env")

# Pass information from the script to the sourcing logic from the .runner.py program (modified a bit)

    return source_config_file(config_file_name)

# source_config_file(config_file)

def source_config_file(config_file):
    # Check if the config file exists
    if not os.path.isfile(config_file):
        print(f"Error: The configuration file '{config_file}' does not exist.")
        exit(1)  # Exit the program with an error code

    # Read, format and set environment variables from the config file that are in a bash supported format
    # So stripping various things from it to get us the key, value pairs to load in os.environ[key] = value
    try:
        with open(config_file, 'r') as file:
            for line in file:
               # Ignore empty lines and comments and remove \n's
               if line.strip() and not line.startswith('#'):
                    # Remove leading and trailing whitespace
                    line = line.replace("\\n", "")
                    line = line.strip()
                    print(locals())
                    # Remove 'export ' from the line
                    line = line.replace('export ', '')
                    # Split the line into key and value at the first '='
                    key, value = line.split('=', 1)
                    # Remove double quotes if present, e.g. remove quotes around demo in export EDGE_CLUSTER="demo"
                    value = value.strip('"')
                    # Resolve any embedded environment variables e.g. resolve $NC_DIR embedded in EDGE_HOME_DIR="$NC_DIR/pgedge"
                    value = os.path.expandvars(value)
                    # Set the environment variable
                    os.environ[key] = value
        print(f"Configuration file '{config_file}' sourced successfully.")
    except Exception as e:
        print(f"Error: Failed to source the configuration file '{config_file}'.")
        print(f"Exception: {e}")
        exit(1)  # Exit the program with an error code

# **************************************************************************************************************
# PSQL Functions
# **************************************************************************************************************

## Get psql connection
def get_pg_con(host,dbname,port,pw,usr):
  try:
    con1 = psycopg2.connect(dbname=dbname, user=usr, host=host, port=port, password=pw)
  except Exception as e:
    exit_message(e)
  return(con1)

## Get psql connection - this is a no fail connection that returns authentication error information
def get_nofail_pg_con(host,dbname,port,pw,usr):
  try:
    con1 = psycopg2.connect(dbname=dbname, user=usr, host=host, port=port, password=pw)
  except Exception as e:
    con1 = None
    print("The connection attempt failed")
  return(con1)


## Run psql on both nodes
def run_psql(cmd1,con1):
    try:
        cur1 = con1.cursor()
        cur1.execute(cmd1)
        print(json.dumps(cur1.fetchall()))
        ret1 = 0
        cur1.close()
    except Exception as e:
        exit_message(e)
    
    try:
        con1.close()
    except Exception as e:
        pass
    return ret1

    
## Write psql
def write_psql(cmd,host,dbname,port,pw,usr):
    ret = 1
    con = get_pg_con(host,dbname,port,pw,usr)
    try:
        cur = con.cursor()
        cur.execute(cmd)
        print(cur.statusmessage)
        ret = 0
        con.commit()
        cur.close()
    except Exception as e:
        exit_message(e)
    try:
        con.close()
    except Exception as e:
        pass
    return ret


## Write psql without throwing an error on each failed command:
def write_nofail_psql(cmd,host,dbname,port,pw,usr):
    ret = 1
    con = get_nofail_pg_con(host,dbname,port,pw,usr)
    print(f"get_nofail_pg_con returned: {con}")
    try:
        cur = con.cursor()
        cur.execute(cmd)
        print(cur.statusmessage)
        ret = 0
        con.commit()
        cur.close()
    except Exception as e:
        print(f"This command failed: {cmd}")
    try:
        con.close()
    except Exception as e:
        pass
    return ret

## Read psql
def read_psql(cmd,host,dbname,port,pw,usr,indent=None):
    con = get_pg_con(host,dbname,port,pw,usr)
    try:
        cur = con.cursor()
        cur.execute(cmd)
        print(cmd)
        ret = json.dumps(cur.fetchall(), indent=indent, default=str)
        cur.close()
    except Exception as e:
        exit_message(e)

    try:
        con.close()
    except Exception as e:
        pass
    return ret


def cleanup_sub(db):
    cmd = "SELECT sub_name FROM spock.subscription"
    ret_n1, ret_n2 = run_psql(cmd)
    if "sub_n1n2" in str(ret_n1):
        cmd1 = f"spock sub-drop sub_n1n2 {db}"
        cmd2 = None
        if "sub_n2n1" in str(ret_n2):
            cmd2 = f"spock sub-drop sub_n2n1 {db}"
        run_cmd("Drop Subs",cmd1,cmd2)
        

# *****************************************************************************
## Query the SQLite Database
## The file is here: nc/pgedge/cluster/demo/n1/pgedge/data/conf
## and its name is db_local.db
# *****************************************************************************

## Create a connection to our SQLite database:

def get_sqlite_connection(db_file):
    conn = None
    try:
        conn = sqlite3.connect(db_file)
        print(f"{conn}")
    except Error as e:
        print(e)
    return conn

## Execute a query on the SQLite database:

def execute_sqlite_query(conn):
    cur = conn.cursor()
    cur.execute(f"{query}")
    rows = cur.fetchall()
    for row in rows:
        print(row)


# *****************************************************************************
## Verify a result set
# *****************************************************************************

def contains(haystack, needle):
    print(f'haystack = ({haystack})')
    print(f'needle = ({needle})')
    
    if haystack is None and needle is None or len(haystack) == 0 and len(needle) == 0:
        return 0

    if haystack.find(needle) != -1:
        print('Haystack and needle both have content, and our value is found - this case correctly returns true')
        return 0
    else:
        print('Haystack and needle both have content, but our value is not found - returning 1 as it should')
        exit_message("Fail", p_rc=1)


    
def needle_in_haystack(haystack, needle):
    if needle in str(haystack):
      print("pass")
      exit_message("Pass", p_rc=0)
    else:
      exit_message("Fail", p_rc=1)


# *****************************************************************************
## Function to grab diff file and data from stdout (might be inconsistant with csvs)
# *****************************************************************************

def get_diff_data(stdout: str, type = "json") -> tuple[str, dict]:
    if type not in ["json", "csv"]:
        raise Exception(f"Type should be json or csv, not {type}")

    # current pattern expects `diffs/YYYY-MM-DD/diffs_TIMESTAMP.json`
    if type == "json":
        file_pattern = r'diffs/\d{4}-\d{2}-\d{2}/diffs_\d+.json'
    if type == "csv":
        file_pattern = r'diffs/\d{4}-\d{2}-\d{2}/n1_n2_\d+.diff'
    match = re.search(file_pattern, stdout)

    if match:
        diff_file_local = match.group(0)
        diff_file_path = os.path.join(os.getenv("EDGE_HOME_DIR"), diff_file_local)
    else:
        raise Exception("Couldn't find diff file")

    if type == "json":
        with open(diff_file_path, "r") as diff_file:
            diff_data = json.load(diff_file)

    if type == "csv":
        diff_data = list()
        for line in open(diff_file_path, "r"):
            if line[0] == '+' or line[0] == '-':
                items = line[1:].strip().split(',')
                if items: diff_data.append(items)

    return diff_file_local, diff_data


# *****************************************************************************
## Compares data in dicts, allows lists to be out of order
# *****************************************************************************

def compare_structures(struct1, struct2, verbose = False) -> bool:
    if isinstance(struct1, dict) and isinstance(struct2, dict):
        if set(struct1.keys()) != set(struct2.keys()):
            return False
        return all(compare_structures(struct1[key], struct2[key]) for key in struct1)

    elif isinstance(struct1, list) and isinstance(struct2, list):
        if len(struct1) != len(struct2):
            return False
        # Sort both lists before comparison to ignore order
        sorted_struct1 = sorted(struct1, key=str)
        sorted_struct2 = sorted(struct2, key=str)
        return all(compare_structures(item1, item2) for item1, item2 in zip(sorted_struct1, sorted_struct2))

    else:
        struct1, struct2 = str(struct1), str(struct2)
        if struct1 == struct2: return True
        else:
            if verbose: print(f"Difference found in structure: {struct1} != {struct2}")
            return False

# *****************************************************************************
## Prints the result from a command run in a nicer format since its driving me crazy
# *****************************************************************************

def printres(res: subprocess.CompletedProcess[str]) -> None:
    print(f"Command `{res.args}` ran with return code {res.returncode}")
    output = res.stdout.strip()
    error = res.stderr.strip()
    
    if output:
        print("stdout:")
        for line in output.splitlines():
            print(f"\t{line}")
    
    if error:
        print("stderr:")
        for line in error.splitlines():
            print(f"\t{line}")

###################################################################
## Find an available port
###################################################################
def get_avail_ports(p_def_port):
    def_port = int(p_def_port)

    # iterate to first non-busy port
    while is_socket_busy(def_port):
        def_port = def_port + 1
        continue

    err_msg = "Port must be between 1000 and 9999, try again."

    while True:
        s_port = str(def_port)

        if s_port.isdigit() == False:
            print(err_msg)
            continue

        i_port = int(s_port)

        if (i_port < 1000) or (i_port > 9999):
            print(err_msg)
            continue

        if is_socket_busy(i_port):
            if not isJSON:
                print("Port " + str(i_port) + " is in use.")
            def_port = str(i_port + 1)
            continue

        break

    return i_port

## Required for get_available_port    

def is_socket_busy(p_port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    result = s.connect_ex(("127.0.0.1",p_port))
    s.close()
    print(result)
    if result == 0:
        return True
    else:
        return False
    
######################################################################
# Find the pg_versions available to um
######################################################################

def find_pg_versions(home_dir):
    components = []
    ## We need to pass in the value of {home_dir}; it should return a list of components with the pg removed from the front.
    ## Use um to find all of the available versions of Postgres.
    res=run_nc_cmd("Getting list of available versions of Postgres", "um list --json", f"{home_dir}")
    print(f"{res}")

    ## Break the returned json string into a list:
    res = json.loads(res.stdout)
    ## Go through the json and find the available PG versions and append it to the components variable:
    for i in res:
        comp=(i.get("component"))
        print(comp)
        ## Append the component name to the components variable:
        components.append(comp)
        print(components)
        ## Remove the first two letters from in front of the component name (pgXX) to make it just the version (XX):
        versions = [item[2:] for item in components]
        print(versions)
    return versions, components

######################################################################
