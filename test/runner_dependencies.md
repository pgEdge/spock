## Using the Test Harness

### Prerequisites on a clean Rocky 9 VM to run the test harness

Disable `firewalld`
    You can use the following command to disable firewalld: 
    `sudo systemctl stop firewalld`

Configure passwordless `sudo`
    To configure passwordless sudo, edit the `/etc/sudoers` file.  Locate the line that contains i`includedir /etc/sudoers.d`; add a line below that line that specifies: `%your_user_name ALL=(ALL) NOPASSWD:ALL`

Configure passwordless `ssh`
    To configure passwordless ssh, execute the following commands:
    ```sh
    ssh-keygen -t rsa
    cd ~/.ssh
    cat id_rsa.pub >> authorized_keys
    chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
    ```

Disable `SELinux`
    To disable SELinux, edit the `/etc/sysconfig/selinux` file, setting `SELINUX=disabled`; then reboot your system.


Ensure that any prerequisites are met:

`sudo yum install curl`
`sudo yum install perl`
`sudo yum install perl-CPAN`
`sudo dnf install perl-File-Which`
`sudo dnf install perl-Try-Tiny`
`sudo dnf install perl-JSON`
`sudo dnf install perl-List-MoreUtils`
`sudo dnf install perl-DBD-Pg`
`sudo dnf install perl-DBD-DBI`
`sudo dnf install python3`
`sudo dnf --enablerepo=devel`
`sudo dnf install python3-psycopg2`
`sudo yum install pip`
`pip install python-dotenv`
`pip install psycopg`

Review the environment variables in the `t/lib/config.env` file and make any adjustments required; then source the environment variables:

`source t/lib/config.env`


Use the following command to invoke a schedule:
`runner.py -s schedule_files/schedule_file_name`

Use the following command to invoke a test script:
`runner.py -t t/script_name`

There is also a help file for the test script:
`runner.py --help`

As each test script executes (individually or through a schedule), it returns a `pass` or `fail` on the command line. The result of each file executed, along with the commands invoked and detailed log are also written to a timestamped logfile (symlinked to `latest.log`) in the `test` directory.

An error code is returned upon exit - 0 means all of the tests passed; any number higher indicates the number of tests that failed.


