## Running pgindent on spock files

1. Generate typedefs.list by running `./gen-typedefs.sh`. This will pull the latest postgres typedefs from postgres buildfarm and add Spock-related typedefs to it by scanning the source code.
2. Install pg_bsd_indent: navigate to src/tools/pg_bsd_indent in your postgres source code and run:
    ```
    make install prefix=/usr/local
    ```
3. Assuming you have pgindent in your path, run this from spock base directory:
    ```
    pgindent --typedefs=pgindent/typedefs.list <filename>
    ```

