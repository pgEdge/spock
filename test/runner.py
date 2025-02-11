#!/usr/bin/python

import getopt, sys, re
import subprocess, os
import filecmp , shutil , difflib
from datetime import datetime
import socket

global glDebug
glDebug = False

global glLogger
glLogger = ""

################################################################################
# initialize_pg_config()
#
# Load global configuration variables.
# These variables were previously defined globally but are now moved to this function
# to ensure they are loaded after the environment variables from the passed config file are read. 
################################################################################

def initialize_pg_config():
    global homedir, pgversion, n1dirbin, n1port, n2port, pgdb, pguser, pgpassword, pghost, actualOutDir, psqlPath
    
    homedir = os.getenv("EDGE_CLUSTER_DIR")
    pgversion = os.getenv("EDGE_COMPONENT", "pg16")
    n1dirbin = f"{homedir}/n1/pgedge/{pgversion}/bin/"
    n1port = int(os.getenv("EDGE_START_PORT", 6432))
    n2port = n1port + 1
    pgdb = os.getenv("EDGE_DB")
    pguser = os.getenv("EDGE_USERNAME")
    pgpassword = os.getenv("EDGE_PASSWORD")
    pghost = os.getenv("EDGE_HOST", "localhost")
    actualOutDir = os.getenv("EDGE_ACTUAL_OUT_DIR", "/tmp/auto_ddl/")
    
    # Construct the path to the psql binary, using n1's psql for executing sql files (for both n1/n2)
    # The psql from path below will be passed appropriate switches/input/output files
    # in the build_psql_command function.
    psqlPath = f"{n1dirbin}psql"
    
    #  runners{}
    #
    #  This dictionary maps a file extension (such as .py or .pl) to the name of
    #  an interpeter that can execute the indicated type of script
    global runners
    runners = {
        ".py": "/usr/bin/python",
        ".pl": "/usr/bin/perl",
        ".sh": "bash",
        ".sql": psqlPath  # Newly added support for .sql file, and its runner psql command path for SQL file execution
    }


################################################################################
# expandSchedule()
#
#  Given the name of a schedule file, this function opens the named file, reads
#  each line in that file (ignoring comments) and writes the entries into the
#  result[] array

def expandSchedule(scheduleFileName):
    result = []

    with open(scheduleFileName) as file:
        for line in file:
            line = (line.rstrip()).lstrip()
            line = re.sub('#.*', '', line)
            if line != '':
                result.append(line)
                
    return result

################################################################################
# parseCmdLine()
#
#  Parses the command line and returns an array of test file names. When the
#  caller specifies a schedule name, that file is "expanded" into the tests[]
#  array. When the caller spcifies a test name, that name is added to the tests[]
#  array.  You can intermingle as many schedule names and test names as you like.

def parseCmdLine():

    opts, args = getopt.getopt(sys.argv[1:], "s:t:vdkhc:", ["schedule=", "test=", "version", "debug", "skip_port_check", "config=", "help"])
              
    tests = []
    skip_port_check = False  # Initialize the skip_port_check flag
    config_file = None  # Initialize the config_file variable

    for opt, val in opts:
        if opt in["-s", "--schedule"]:
            tests += expandSchedule(val)
        
        elif opt in ["-t", "--test"]:
            tests.append(val)
        
        elif opt in ["-v", "--version"]:
            print("version=3.14")

        elif opt in ["-d", "--debug"]:
            global glDebug
            glDebug = True

        elif opt in ["-k", "--skip_port_check"]:
            skip_port_check = True  # Set the flag to skip port check
        
        elif opt in ["-c", "--config"]:
            config_file = val  # Set the config_file variable
    
        elif opt in ["-h", "--help"]:
            print("Usage: " + sys.argv[0] + "  [option] ...")
            print("")
            print(" -s scheduleFileName   : execute tests listed in given scheduleFileName")
            print(" -t testFileName       : execute the given test script")
            print(" -k, --skip_port_check : skip checking if required pg ports are free")
            print(" -c configFileName     : specify configuration file to source")
            print(" -v                    : displays version number")
            print(" -h                    : display this usafe information")
            print(" -d                    : print extra information useful for debugging")
            sys.exit(0)

    # If config file is specified, source it. The scope of this would be limited to the current
    # runner.py process and its sub-processes (individual tests).
    if config_file:
        source_config_file(config_file)

    # Initialize PostgreSQL configuration variables after sourcing the config file
    initialize_pg_config()

    # Check for required ports unless skipping is specified
    if not skip_port_check:
        check_pg_ports()

    # Now create a log file - the name of the log file is based on the
    # current date and time
            
    now = datetime.now()

    logFileName = now.strftime("%Y%m%d_%H%M%S.log")

    global glLogger
    glLogger = open(logFileName, "w")

    # And create a symbolic link named lastest.log that points to the
    # the logFileName we just created

    if (os.path.exists("./latest.log")):
        os.remove("./latest.log")
        
    os.symlink(logFileName, "./latest.log")

    print("")
    print("Test output can be found in ./latest.log (or ./" + logFileName + ")")
    print("")
    
    return tests

################################################################################
# logTestOutput()
#
#  Writes a test summary (test name, pass/fail status, stdout, stderr) to the
#  current logger.

def logTestOutput(testName, completedProcess):
    global glLogger

    if (completedProcess.returncode == 0):
        status = "pass"
    else:
        status = "fail"

    print("**************************************************", file=glLogger)
    print(testName + " (" + status + ")", file=glLogger)
    print("**************************************************", file=glLogger)
    print(completedProcess.stdout, file=glLogger)
    print(completedProcess.stderr, file=glLogger)

################################################################################
# runTest()
#
# Runs the specified test, captures the stdout and stderr output, and writes
# that output to the current log file. If the test completes successfully
# and returns a 0, the test is presumed to have passed, otherwise the test
# is treated as a failure. For .sql files, additional checks are made to 
# ensure output files match expected results, and return codes are set manually.
################################################################################
def runTest(testName):
    extension = testName[testName.rfind('.')::]  # Extract the file extension from the test name
    if extension == '.sql':
        # Execute psql command and Compare expected/actual output files, handle any errors gracefully through try/except block
        try:
            # Build the psql command with appropriate switches/inputs/outputs,
            psql_command, actual_output_file, expected_output_file = build_psql_command(testName)
            # Execute the psql command
            result = subprocess.run(psql_command, shell=True, capture_output=True, text=True)  
            # Compare actual and expected output files, setting shallow=False compares content and not just timestamps/size
            if filecmp.cmp(actual_output_file, expected_output_file, shallow=False):
                result_status = "pass"
                result.stdout = "Expected and Actual output files match"  # Set success message
                result.returncode = 0  # Explicitly set the return code for success
            else:
                result_status = "fail"
                # Identify the diff between actual output and expected output 
                diff_output = generate_diff(actual_output_file, expected_output_file)
                # Set stderr to include the diff output 
                result.stderr = "Expected and Actual output files do not match. Diff as follows:\n" + diff_output
                result.returncode = 1 # Explicitly set the return code for failure
        except Exception as e:
            # Capture the error message
            result_status = "error"
            result.stderr = f"An unexpected error occurred: {str(e)}"
            result.returncode = 1  # Set return code to 1 for error
        # Log result to the log file
        logTestOutput(testName, result) 

        # Display result on console
        printTestResult(testName, result_status)
        # Return the pass/fail/error count, used for displaying the test summary counts
        return {'passCount': 1 if result_status == "pass" else 0, 
                'failCount': 1 if result_status == "fail" else 0, 
                'errorCount': 1 if result_status == "error" else 0}
    else:
        # Existing handling for .pl, .py, and .sh files
        command = runners[extension]
        result = subprocess.run([command, testName], capture_output=True, text=True) 
        # Determine the result status based on the return code
        if result.returncode == 0:
            result_status = "pass"
        else:
            result_status = "fail"
        # Log result
        logTestOutput(testName, result)

        #display result on console
        printTestResult(testName, result_status)

        return {'passCount': 1 if result.returncode == 0 else 0, 
                'failCount': 1 if result.returncode != 0 else 0, 
                'errorCount': 0}


################################################################################
# runTests()
#
#    Given a list of test names (testList), this function runs each test and
#    then prints a summary of the test suite

def runTests(testList):

    passCount  = 0
    failCount  = 0
    errorCount = 0
    
    for test in testList:
        result = runTest(test)

        passCount  = passCount + result.get('passCount')
        failCount  = failCount + result.get('failCount')
        errorCount = errorCount + result.get('errorCount')

    print("pass:   " + str(passCount))
    print("fail:   " + str(failCount))
    print("errors: " + str(errorCount))

# Comment or uncomment the next line to make the GH action return an exit code
# of 1 if any of the test cases fail 
    return failCount + errorCount

################################################################################
# printTestResult()
#
# Prints the formatted test result to the console. This function is called after
# each test run to display the name of the test along with its outcome, formatted
# with dots to align the results neatly.
#
# Args:
# testName : The name of the test.
# result_status : Test outcome ('pass', 'fail', or 'error').
################################################################################
def printTestResult(testName, result_status):
    # Calculate the number of dots for formatting output based on the test name length and status length
    dotCount = 80 - len(testName) - len(result_status)
    print(f"{testName} {'.' * dotCount} {result_status}")


################################################################################
# build_psql_command()
#
# Constructs the full psql command with all the necessary switches, replacing placeholders,
# identifying port, and the paths for the actual and expected output files.
# =============
# Assumptions : 
# =============
# The sql file should have node indicator (n1 or n2) to convey which node the sql file will be
# executed on (primarily to identify the server port). If no node info is specified, n1 is considered default.
# 
# The expected output file must pre-exist, with the same name as sql file but with a .out extension  
# and same directory as sql file. The expected output file must be generated with the following command manually:
#      ./psql -X -a -d lcdb -p <intended port> < input.sql > expected_output.out 2>&1
#
# The filename of actual output file will be same as that of the expected output file.
# The actual output file will be generated at runtime in a directory controlled by actualOutDir variable
# 
# Args:
# sql_file : The path to the SQL file to execute.
#
# Returns:
# Three return values : The full psql command, path to the actual output file, and path to the expected output file.
################################################################################
def build_psql_command(sql_file):
    # Retrieve the psql command path from the runners dictionary for SQL files
    psql_command_path = runners[".sql"]
    
    # Determine the port based on the node identifier included in the SQL file name
    if 'n2' in sql_file:
        port = n2port
    else:
        port = n1port
    
    # Extract the file name from the sql_file path and replace the .sql extension with .out for the output file name
    file_name = os.path.basename(sql_file).replace('.sql', '.out')
    # Construct the full path for the actual output file in the designated output directory
    actual_output_file = os.path.join(actualOutDir, file_name)
    
    # Assume the expected output file is in the same location as the sql_file, but with a .out extension
    expected_output_file = sql_file.replace('.sql', '.out')

    # Construct the full psql command using the database parameters and file paths
    psql_command = f"{psql_command_path} -X -a -d {pgdb} -p {port} -h {pghost} < {sql_file} > {actual_output_file} 2>&1"
    
    if glDebug:
        print("sql_file:   " + str(sql_file))
        print("port:   " + str(port))
        print("actual output file:   " + str(actual_output_file))
        print("expected output file:   " + str(expected_output_file))
        print("psql_command:   " + str(psql_command))
    
    # Return the constructed psql command and the paths for the actual and expected output files
    return psql_command, actual_output_file, expected_output_file


################################################################################
# generate_diff()
#
# Generates a diff between two files and returns the diff result as a string.
# The corresponding diff is set in the stderr to go into the log file.
#
# Args: file1 (actual output) and file2 (expected output)
#
# Returns: diff between the two files.
################################################################################
def generate_diff(file1, file2):
    # Read the contents of the files
    with open(file1, 'r') as f1, open(file2, 'r') as f2:
        file1_lines = f1.readlines()
        file2_lines = f2.readlines()

    # Generate unified diff
    diff = difflib.unified_diff(
        file2_lines, file1_lines,
        fromfile='expected',
        tofile='actual',
        lineterm='', 
        n=4  # Number of context lines (adjustable). 
    )

    # Format the differences in a single string
    diff_string = ''.join(diff)
    return diff_string


################################################################################
# prepareOutputDirectory()
#
# The autoddl tests utilise a temporary directory controlled by the actualOutDir variable
# where the actual output files are stored as a result of executing the .sql files.
# This function ensures that the output directory is empty at the start of the regression run.
################################################################################
def prepareOutputDirectory(directory):
    # Check if the directory exists and remove it if it does
    if os.path.exists(directory):
        shutil.rmtree(directory)  # Removes the directory and all its contents
    # Recreate the directory
    os.makedirs(directory)

################################################################################
# check_pg_ports()
#
# Checks if the specified PostgreSQL ports (n1port, n1port + 1, n1port + 2) are free.
# Exits with an error message if any ports are occupied.
# Called by default unless -k or --skip_port_check is specified at command line.
################################################################################
def check_pg_ports():
    ports_to_check = [n1port, n1port + 1, n1port + 2]
    unavailable_ports = []

    for port in ports_to_check:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            result = sock.connect_ex((pghost, port))
            if result == 0:
                unavailable_ports.append(port)
    
    if unavailable_ports:
        print(f"Error: The following ports are not free: {', '.join(map(str, unavailable_ports))}")
        print("Please free up the ports OR use -k switch to ignore ports availability check.")
        exit(1)  # Exit the program with an error code
    else:
        print(f"All required ports ({', '.join(map(str, ports_to_check))}) are free.")

################################################################################
# source_config_file(config_file)
#
# Sources the given configuration file.
# Exits with an error message if the file does not exist or sourcing fails.
# Sets environment variables in the current process.
################################################################################
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
                # Ignore empty lines and comments
               if line.strip() and not line.startswith('#'):
                    # Remove leading and trailing whitespace
                    line = line.strip()
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
        # print the list of all environment variables starting with EDGE in debug mode
        if glDebug:
            print("Environment Variables:")
            for key, value in os.environ.items():
                if key.startswith("EDGE"):
                    print(f"{key} = {value}")
    except Exception as e:
        print(f"Error: Failed to source the configuration file '{config_file}'.")
        print(f"Exception: {e}")
        exit(1)  # Exit the program with an error code
    
################################################################################
# main()
#
#  This function is the entry point for runner.py.  We start by parsing the
#  commnd-line arguments, then run each test (found in the testList) and finish
#  up by printing a summary of the test run (pass count, fail count, error count)

def maillog():

    # Import smtplib for the actual sending function
    import smtplib

# Import the email modules we'll need
    from email.mime.text import MIMEText

# Open a plain text file for reading.  For this example, assume that
# the text file contains only ASCII characters 
    with open("./latest.log", 'rb') as fp:
        # Create a text/plain message
        msg = MIMEText(fp.read())

# me == the sender's email address
# you == the recipient's email address
    msg['Subject'] = 'The contents of %s' % latest.log
    msg['From'] = "susan@pgedge.com"
    msg['To'] = "susan@pgedge.com"

# Send the message via our own SMTP server, but don't include the
# envelope header.
    s = smtplib.SMTP('localhost')
    s.sendmail(me, [you], msg.as_string())
    s.quit()



def main():

    testList = parseCmdLine()

    # Prepare the output directory (for autoddl tests) to ensure it's empty and ready for new outputs
    prepareOutputDirectory(actualOutDir)
    
    global glDebug
    
    if glDebug:
        for test in testList:
            print(test)

    scheduleResult = runTests(testList)
         
    print("complete")

    global glLogger
    glLogger.close()

    sys.exit(scheduleResult)

#    maillog()

if __name__ == "__main__":
    main()
